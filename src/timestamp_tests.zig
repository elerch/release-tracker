const std = @import("std");
const main = @import("main.zig");
const config = @import("config.zig");
const xml_parser = @import("xml_parser.zig");

const Release = main.Release;
const Config = config.Config;
const SourceHutConfig = config.SourceHutConfig;

test "Config loading without last_check field" {
    const allocator = std.testing.allocator;

    // Create a test config JSON content without last_check
    const test_config_content =
        \\{
        \\  "github_token": "test_token",
        \\  "gitlab_token": null,
        \\  "codeberg_token": null,
        \\  "sourcehut": {
        \\    "repositories": ["~test/repo"]
        \\  }
        \\}
    ;

    // Parse config directly from JSON content
    const loaded_config = try config.parseConfigFromJson(allocator, test_config_content);
    defer loaded_config.deinit();

    // Verify config was loaded correctly
    try std.testing.expectEqualStrings("test_token", loaded_config.github_token.?);
    try std.testing.expect(loaded_config.gitlab_token == null);
}

test "parseReleaseTimestamp handles edge cases" {
    // Test various timestamp formats
    const test_cases = [_]struct {
        input: []const u8,
        expected_valid: bool,
    }{
        .{ .input = "2024-01-01T00:00:00Z", .expected_valid = true },
        .{ .input = "2024-12-31T23:59:59Z", .expected_valid = true },
        .{ .input = "1704067200", .expected_valid = true }, // This is a valid timestamp
        .{ .input = "2024-01-01", .expected_valid = true }, // Zeit can parse date-only format
        .{ .input = "", .expected_valid = false },
        .{ .input = "invalid", .expected_valid = false },
        .{ .input = "not-a-date", .expected_valid = false },
        .{ .input = "definitely-not-a-date", .expected_valid = false },
    };

    for (test_cases) |test_case| {
        const result = main.parseReleaseTimestamp(test_case.input) catch 0;
        if (test_case.expected_valid) {
            try std.testing.expect(result > 0);
        } else {
            try std.testing.expectEqual(@as(i64, 0), result);
        }
    }

    // Test the special case of "0" timestamp - this should return 0
    const zero_result = main.parseReleaseTimestamp("0") catch 0;
    try std.testing.expectEqual(@as(i64, 0), zero_result);

    // Test specific known values
    const known_timestamp = main.parseReleaseTimestamp("1704067200") catch 0;
    try std.testing.expectEqual(@as(i64, 1704067200), known_timestamp);

    // Test that date-only format works
    const date_only_result = main.parseReleaseTimestamp("2024-01-01") catch 0;
    try std.testing.expectEqual(@as(i64, 1704067200), date_only_result);
}

test "filterNewReleases with various timestamp scenarios" {
    const allocator = std.testing.allocator;

    const releases = [_]Release{
        Release{
            .repo_name = "test/very-old",
            .tag_name = "v0.1.0",
            .published_at = "2023-01-01T00:00:00Z",
            .html_url = "https://github.com/test/very-old/releases/tag/v0.1.0",
            .description = "Very old release",
            .provider = "github",
        },
        Release{
            .repo_name = "test/old",
            .tag_name = "v1.0.0",
            .published_at = "2024-01-01T00:00:00Z",
            .html_url = "https://github.com/test/old/releases/tag/v1.0.0",
            .description = "Old release",
            .provider = "github",
        },
        Release{
            .repo_name = "test/recent",
            .tag_name = "v2.0.0",
            .published_at = "2024-06-01T00:00:00Z",
            .html_url = "https://github.com/test/recent/releases/tag/v2.0.0",
            .description = "Recent release",
            .provider = "github",
        },
        Release{
            .repo_name = "test/newest",
            .tag_name = "v3.0.0",
            .published_at = "2024-12-01T00:00:00Z",
            .html_url = "https://github.com/test/newest/releases/tag/v3.0.0",
            .description = "Newest release",
            .provider = "github",
        },
    };

    // Test filtering from beginning of time (should get all)
    {
        var filtered = try main.filterNewReleases(allocator, &releases, 0);
        defer {
            for (filtered.items) |release| {
                release.deinit(allocator);
            }
            filtered.deinit();
        }
        try std.testing.expectEqual(@as(usize, 4), filtered.items.len);
    }

    // Test filtering from middle of 2024 (should get recent and newest)
    {
        const march_2024 = main.parseReleaseTimestamp("2024-03-01T00:00:00Z") catch 0;
        var filtered = try main.filterNewReleases(allocator, &releases, march_2024);
        defer {
            for (filtered.items) |release| {
                release.deinit(allocator);
            }
            filtered.deinit();
        }
        try std.testing.expectEqual(@as(usize, 2), filtered.items.len);

        // Should contain recent and newest
        var found_recent = false;
        var found_newest = false;
        for (filtered.items) |release| {
            if (std.mem.eql(u8, release.repo_name, "test/recent")) {
                found_recent = true;
            }
            if (std.mem.eql(u8, release.repo_name, "test/newest")) {
                found_newest = true;
            }
        }
        try std.testing.expect(found_recent);
        try std.testing.expect(found_newest);
    }

    // Test filtering from future (should get none)
    {
        const future = main.parseReleaseTimestamp("2025-01-01T00:00:00Z") catch 0;
        var filtered = try main.filterNewReleases(allocator, &releases, future);
        defer {
            for (filtered.items) |release| {
                release.deinit(allocator);
            }
            filtered.deinit();
        }
        try std.testing.expectEqual(@as(usize, 0), filtered.items.len);
    }
}

test "XML parsing preserves timestamp precision" {
    const allocator = std.testing.allocator;

    const precise_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<title>Repository Releases</title>
        \\<entry>
        \\  <title>precise/repo - v1.0.0</title>
        \\  <link href="https://github.com/precise/repo/releases/tag/v1.0.0"/>
        \\  <updated>2024-06-15T14:30:45Z</updated>
        \\  <summary>Precise timestamp test</summary>
        \\  <category term="github"/>
        \\</entry>
        \\</feed>
    ;

    var releases = try xml_parser.parseAtomFeed(allocator, precise_xml);
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), releases.items.len);
    try std.testing.expectEqualStrings("2024-06-15T14:30:45Z", releases.items[0].published_at);

    // Verify the timestamp can be parsed correctly
    const parsed_timestamp = main.parseReleaseTimestamp(releases.items[0].published_at) catch 0;
    try std.testing.expect(parsed_timestamp > 0);
}

test "compareReleasesByDate with various timestamp formats" {
    const release_iso_early = Release{
        .repo_name = "test/iso-early",
        .tag_name = "v1.0.0",
        .published_at = "2024-01-01T00:00:00Z",
        .html_url = "https://github.com/test/iso-early/releases/tag/v1.0.0",
        .description = "Early ISO format",
        .provider = "github",
    };

    const release_iso_late = Release{
        .repo_name = "test/iso-late",
        .tag_name = "v2.0.0",
        .published_at = "2024-12-01T00:00:00Z",
        .html_url = "https://github.com/test/iso-late/releases/tag/v2.0.0",
        .description = "Late ISO format",
        .provider = "github",
    };

    const release_invalid = Release{
        .repo_name = "test/invalid",
        .tag_name = "v3.0.0",
        .published_at = "invalid-date",
        .html_url = "https://github.com/test/invalid/releases/tag/v3.0.0",
        .description = "Invalid format",
        .provider = "github",
    };

    // Later date should come before earlier date (more recent first)
    try std.testing.expect(main.compareReleasesByDate({}, release_iso_late, release_iso_early));
    try std.testing.expect(!main.compareReleasesByDate({}, release_iso_early, release_iso_late));

    // Invalid timestamps should be treated as 0 and come last
    try std.testing.expect(main.compareReleasesByDate({}, release_iso_early, release_invalid));
    try std.testing.expect(main.compareReleasesByDate({}, release_iso_late, release_invalid));
}
