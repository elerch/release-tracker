const std = @import("std");
const zeit = @import("zeit");
const main = @import("main.zig");
const utils = @import("utils.zig");
const config = @import("config.zig");

const Release = main.Release;

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
        const result = utils.parseReleaseTimestamp(test_case.input) catch 0;
        if (test_case.expected_valid) {
            try std.testing.expect(result > 0);
        } else {
            try std.testing.expectEqual(@as(i64, 0), result);
        }
    }

    // Test the special case of "0" timestamp - this should return 0
    const zero_result = utils.parseReleaseTimestamp("0") catch 0;
    try std.testing.expectEqual(@as(i64, 0), zero_result);

    // Test specific known values
    const known_timestamp = utils.parseReleaseTimestamp("1704067200") catch 0;
    try std.testing.expectEqual(@as(i64, 1704067200), known_timestamp);

    // Test that date-only format works
    const date_only_result = utils.parseReleaseTimestamp("2024-01-01") catch 0;
    try std.testing.expectEqual(@as(i64, 1704067200), date_only_result);
}

test "compareReleasesByDate with various timestamp formats" {
    const release_iso_early = Release{
        .repo_name = "test/iso-early",
        .tag_name = "v1.0.0",
        .published_at = @intCast(@divTrunc(
            (try zeit.instant(.{ .source = .{ .iso8601 = "2024-01-01T00:00:00Z" } })).timestamp,
            std.time.ns_per_s,
        )),
        .html_url = "https://github.com/test/iso-early/releases/tag/v1.0.0",
        .description = "Early ISO format",
        .provider = "github",
        .is_tag = false,
    };

    const release_iso_late = Release{
        .repo_name = "test/iso-late",
        .tag_name = "v2.0.0",
        .published_at = @intCast(@divTrunc(
            (try zeit.instant(.{ .source = .{ .iso8601 = "2024-12-01T00:00:00Z" } })).timestamp,
            std.time.ns_per_s,
        )),
        .html_url = "https://github.com/test/iso-late/releases/tag/v2.0.0",
        .description = "Late ISO format",
        .provider = "github",
        .is_tag = false,
    };

    const release_invalid = Release{
        .repo_name = "test/invalid",
        .tag_name = "v3.0.0",
        .published_at = 0,
        .html_url = "https://github.com/test/invalid/releases/tag/v3.0.0",
        .description = "Invalid format",
        .provider = "github",
        .is_tag = false,
    };

    // Later date should come before earlier date (more recent first)
    try std.testing.expect(utils.compareReleasesByDate({}, release_iso_late, release_iso_early));
    try std.testing.expect(!utils.compareReleasesByDate({}, release_iso_early, release_iso_late));

    // Invalid timestamps should be treated as 0 and come last
    try std.testing.expect(utils.compareReleasesByDate({}, release_iso_early, release_invalid));
    try std.testing.expect(utils.compareReleasesByDate({}, release_iso_late, release_invalid));
}
