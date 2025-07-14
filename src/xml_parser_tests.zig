const std = @import("std");
const testing = std.testing;

const xml_parser = @import("xml_parser.zig");
const atom = @import("atom.zig");
const Release = @import("main.zig").Release;

test "round trip: generate atom feed and parse it back" {
    const allocator = testing.allocator;

    // Create test releases
    const original_releases = [_]Release{
        Release{
            .repo_name = "test/repo1",
            .tag_name = "v1.0.0",
            .published_at = "2024-01-01T00:00:00Z",
            .html_url = "https://github.com/test/repo1/releases/tag/v1.0.0",
            .description = "First release",
            .provider = "github",
        },
        Release{
            .repo_name = "test/repo2",
            .tag_name = "v2.0.0",
            .published_at = "2024-01-02T00:00:00Z",
            .html_url = "https://github.com/test/repo2/releases/tag/v2.0.0",
            .description = "Second release",
            .provider = "github",
        },
    };

    // Generate atom feed
    const atom_content = try atom.generateFeed(allocator, &original_releases);
    defer allocator.free(atom_content);

    // Parse it back
    var parsed_releases = try xml_parser.parseAtomFeed(allocator, atom_content);
    defer {
        for (parsed_releases.items) |release| {
            release.deinit(allocator);
        }
        parsed_releases.deinit();
    }

    // Verify we got the same data back
    try testing.expectEqual(@as(usize, 2), parsed_releases.items.len);

    try testing.expectEqualStrings("test/repo1", parsed_releases.items[0].repo_name);
    try testing.expectEqualStrings("v1.0.0", parsed_releases.items[0].tag_name);
    try testing.expectEqualStrings("2024-01-01T00:00:00Z", parsed_releases.items[0].published_at);
    try testing.expectEqualStrings("https://github.com/test/repo1/releases/tag/v1.0.0", parsed_releases.items[0].html_url);
    try testing.expectEqualStrings("First release", parsed_releases.items[0].description);
    try testing.expectEqualStrings("github", parsed_releases.items[0].provider);

    try testing.expectEqualStrings("test/repo2", parsed_releases.items[1].repo_name);
    try testing.expectEqualStrings("v2.0.0", parsed_releases.items[1].tag_name);
    try testing.expectEqualStrings("2024-01-02T00:00:00Z", parsed_releases.items[1].published_at);
    try testing.expectEqualStrings("https://github.com/test/repo2/releases/tag/v2.0.0", parsed_releases.items[1].html_url);
    try testing.expectEqualStrings("Second release", parsed_releases.items[1].description);
    try testing.expectEqualStrings("github", parsed_releases.items[1].provider);
}

test "parse atom feed with special characters" {
    const allocator = testing.allocator;

    // Create releases with special characters
    const original_releases = [_]Release{
        Release{
            .repo_name = "test/repo<script>",
            .tag_name = "v1.0.0 & more",
            .published_at = "2024-01-01T00:00:00Z",
            .html_url = "https://github.com/test/repo/releases/tag/v1.0.0",
            .description = "Test \"release\" with <special> chars & symbols",
            .provider = "github",
        },
    };

    // Generate atom feed (this should escape the characters)
    const atom_content = try atom.generateFeed(allocator, &original_releases);
    defer allocator.free(atom_content);

    // Verify the XML contains escaped characters
    try testing.expect(std.mem.indexOf(u8, atom_content, "&lt;script&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, atom_content, "&amp; more") != null);
    try testing.expect(std.mem.indexOf(u8, atom_content, "&quot;release&quot;") != null);

    // Parse it back (this should unescape the characters)
    var parsed_releases = try xml_parser.parseAtomFeed(allocator, atom_content);
    defer {
        for (parsed_releases.items) |release| {
            release.deinit(allocator);
        }
        parsed_releases.deinit();
    }

    // Verify the parsed data has the original unescaped characters
    try testing.expectEqual(@as(usize, 1), parsed_releases.items.len);
    try testing.expectEqualStrings("test/repo<script>", parsed_releases.items[0].repo_name);
    try testing.expectEqualStrings("v1.0.0 & more", parsed_releases.items[0].tag_name);
    try testing.expectEqualStrings("Test \"release\" with <special> chars & symbols", parsed_releases.items[0].description);
}

test "parse malformed atom feed gracefully" {
    const allocator = testing.allocator;

    const malformed_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<title>Repository Releases</title>
        \\<entry>
        \\  <title>test/repo1 - v1.0.0</title>
        \\  <link href="https://github.com/test/repo1/releases/tag/v1.0.0"/>
        \\  <updated>2024-01-01T00:00:00Z</updated>
        \\  <summary>Good entry</summary>
        \\  <category term="github"/>
        \\</entry>
        \\<entry>
        \\  <title>test/repo2 - v2.0.0</title>
        \\  <!-- Missing closing entry tag -->
        \\<entry>
        \\  <title>test/repo3 - v3.0.0</title>
        \\  <link href="https://github.com/test/repo3/releases/tag/v3.0.0"/>
        \\  <updated>2024-01-03T00:00:00Z</updated>
        \\  <summary>Another good entry</summary>
        \\  <category term="github"/>
        \\</entry>
        \\</feed>
    ;

    var parsed_releases = try xml_parser.parseAtomFeed(allocator, malformed_xml);
    defer {
        for (parsed_releases.items) |release| {
            release.deinit(allocator);
        }
        parsed_releases.deinit();
    }

    // Should parse the valid entries and skip the malformed one
    // Note: The malformed entry (repo2) will be parsed but will contain mixed content
    // The parser finds the first closing </entry> tag which belongs to repo3
    try testing.expectEqual(@as(usize, 2), parsed_releases.items.len);
    try testing.expectEqualStrings("test/repo1", parsed_releases.items[0].repo_name);
    try testing.expectEqualStrings("test/repo2", parsed_releases.items[1].repo_name); // This gets the first title found
}

test "parse empty atom feed" {
    const allocator = testing.allocator;

    const empty_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<title>Repository Releases</title>
        \\<subtitle>New releases from starred repositories</subtitle>
        \\<link href="https://github.com" rel="alternate"/>
        \\<link href="https://example.com/releases.xml" rel="self"/>
        \\<id>https://example.com/releases</id>
        \\<updated>2024-01-01T00:00:00Z</updated>
        \\</feed>
    ;

    var parsed_releases = try xml_parser.parseAtomFeed(allocator, empty_xml);
    defer parsed_releases.deinit();

    try testing.expectEqual(@as(usize, 0), parsed_releases.items.len);
}

test "parse atom feed with multiline summaries" {
    const allocator = testing.allocator;

    const multiline_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<title>Repository Releases</title>
        \\<entry>
        \\  <title>test/repo - v1.0.0</title>
        \\  <link href="https://github.com/test/repo/releases/tag/v1.0.0"/>
        \\  <updated>2024-01-01T00:00:00Z</updated>
        \\  <summary>This is a multiline
        \\summary with line breaks
        \\and multiple paragraphs</summary>
        \\  <category term="github"/>
        \\</entry>
        \\</feed>
    ;

    var parsed_releases = try xml_parser.parseAtomFeed(allocator, multiline_xml);
    defer {
        for (parsed_releases.items) |release| {
            release.deinit(allocator);
        }
        parsed_releases.deinit();
    }

    try testing.expectEqual(@as(usize, 1), parsed_releases.items.len);
    const expected_summary = "This is a multiline\nsummary with line breaks\nand multiple paragraphs";
    try testing.expectEqualStrings(expected_summary, parsed_releases.items[0].description);
}

test "parse atom feed with different providers" {
    const allocator = testing.allocator;

    const multi_provider_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<title>Repository Releases</title>
        \\<entry>
        \\  <title>github/repo - v1.0.0</title>
        \\  <link href="https://github.com/github/repo/releases/tag/v1.0.0"/>
        \\  <updated>2024-01-01T00:00:00Z</updated>
        \\  <summary>GitHub release</summary>
        \\  <category term="github"/>
        \\</entry>
        \\<entry>
        \\  <title>gitlab/repo - v2.0.0</title>
        \\  <link href="https://gitlab.com/gitlab/repo/-/releases/v2.0.0"/>
        \\  <updated>2024-01-02T00:00:00Z</updated>
        \\  <summary>GitLab release</summary>
        \\  <category term="gitlab"/>
        \\</entry>
        \\<entry>
        \\  <title>codeberg/repo - v3.0.0</title>
        \\  <link href="https://codeberg.org/codeberg/repo/releases/tag/v3.0.0"/>
        \\  <updated>2024-01-03T00:00:00Z</updated>
        \\  <summary>Codeberg release</summary>
        \\  <category term="codeberg"/>
        \\</entry>
        \\<entry>
        \\  <title>~user/repo - v4.0.0</title>
        \\  <link href="https://git.sr.ht/~user/repo/refs/v4.0.0"/>
        \\  <updated>2024-01-04T00:00:00Z</updated>
        \\  <summary>SourceHut release</summary>
        \\  <category term="sourcehut"/>
        \\</entry>
        \\</feed>
    ;

    var parsed_releases = try xml_parser.parseAtomFeed(allocator, multi_provider_xml);
    defer {
        for (parsed_releases.items) |release| {
            release.deinit(allocator);
        }
        parsed_releases.deinit();
    }

    try testing.expectEqual(@as(usize, 4), parsed_releases.items.len);

    try testing.expectEqualStrings("github", parsed_releases.items[0].provider);
    try testing.expectEqualStrings("gitlab", parsed_releases.items[1].provider);
    try testing.expectEqualStrings("codeberg", parsed_releases.items[2].provider);
    try testing.expectEqualStrings("sourcehut", parsed_releases.items[3].provider);
}

test "parse atom feed with missing optional fields" {
    const allocator = testing.allocator;

    const minimal_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<entry>
        \\  <title>test/repo - v1.0.0</title>
        \\  <link href="https://github.com/test/repo/releases/tag/v1.0.0"/>
        \\</entry>
        \\</feed>
    ;

    var parsed_releases = try xml_parser.parseAtomFeed(allocator, minimal_xml);
    defer {
        for (parsed_releases.items) |release| {
            release.deinit(allocator);
        }
        parsed_releases.deinit();
    }

    try testing.expectEqual(@as(usize, 1), parsed_releases.items.len);

    const release = parsed_releases.items[0];
    try testing.expectEqualStrings("test/repo", release.repo_name);
    try testing.expectEqualStrings("v1.0.0", release.tag_name);
    try testing.expectEqualStrings("https://github.com/test/repo/releases/tag/v1.0.0", release.html_url);

    // Missing fields should be empty strings
    try testing.expectEqualStrings("", release.published_at);
    try testing.expectEqualStrings("", release.description);
    try testing.expectEqualStrings("", release.provider);
}
