const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Release = @import("main.zig").Release;

pub const ParseError = error{
    InvalidXml,
    MalformedEntry,
    OutOfMemory,
};

pub fn parseAtomFeed(allocator: Allocator, xml_content: []const u8) !ArrayList(Release) {
    var releases = ArrayList(Release).init(allocator);
    errdefer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    var entry_start: ?usize = null;
    var pos: usize = 0;

    while (pos < xml_content.len) {
        // Find next entry
        if (std.mem.indexOf(u8, xml_content[pos..], "<entry>")) |entry_offset| {
            entry_start = pos + entry_offset;
            pos = entry_start.? + 7; // Move past "<entry>"

            // Find the end of this entry
            if (std.mem.indexOf(u8, xml_content[pos..], "</entry>")) |end_offset| {
                const entry_end = pos + end_offset;
                const entry_content = xml_content[entry_start.? .. entry_end + 8]; // Include "</entry>"

                if (parseEntry(allocator, entry_content)) |release| {
                    try releases.append(release);
                } else |err| {
                    std.debug.print("Warning: Failed to parse entry: {}\n", .{err});
                }

                pos = entry_end + 8; // Move past "</entry>"
            } else {
                break; // No closing tag found
            }
        } else {
            break; // No more entries
        }
    }

    return releases;
}

fn parseEntry(allocator: Allocator, entry_xml: []const u8) !Release {
    var release = Release{
        .repo_name = try allocator.dupe(u8, ""),
        .tag_name = try allocator.dupe(u8, ""),
        .published_at = try allocator.dupe(u8, ""),
        .html_url = try allocator.dupe(u8, ""),
        .description = try allocator.dupe(u8, ""),
        .provider = try allocator.dupe(u8, ""),
    };
    errdefer release.deinit(allocator);

    // Parse title to extract repo_name and tag_name
    if (extractTagContent(entry_xml, "title", allocator)) |title| {
        defer allocator.free(title);
        if (std.mem.lastIndexOf(u8, title, " - ")) |dash_pos| {
            allocator.free(release.repo_name);
            allocator.free(release.tag_name);
            release.repo_name = try allocator.dupe(u8, title[0..dash_pos]);
            release.tag_name = try allocator.dupe(u8, title[dash_pos + 3 ..]);
        }
    }

    // Parse link href attribute
    if (extractLinkHref(entry_xml, allocator)) |url| {
        allocator.free(release.html_url);
        release.html_url = url;
    }

    // Parse updated timestamp
    if (extractTagContent(entry_xml, "updated", allocator)) |updated| {
        allocator.free(release.published_at);
        release.published_at = updated;
    }

    // Parse summary (description)
    if (extractTagContent(entry_xml, "summary", allocator)) |summary| {
        allocator.free(release.description);
        release.description = summary;
    }

    // Parse category term attribute (provider)
    if (extractCategoryTerm(entry_xml, allocator)) |provider| {
        allocator.free(release.provider);
        release.provider = provider;
    }

    return release;
}

fn extractTagContent(xml: []const u8, tag_name: []const u8, allocator: Allocator) ?[]u8 {
    const open_tag = std.fmt.allocPrint(allocator, "<{s}>", .{tag_name}) catch return null;
    defer allocator.free(open_tag);
    const close_tag = std.fmt.allocPrint(allocator, "</{s}>", .{tag_name}) catch return null;
    defer allocator.free(close_tag);

    if (std.mem.indexOf(u8, xml, open_tag)) |start_pos| {
        const content_start = start_pos + open_tag.len;
        if (std.mem.indexOf(u8, xml[content_start..], close_tag)) |end_offset| {
            const content_end = content_start + end_offset;
            const content = xml[content_start..content_end];
            return unescapeXml(allocator, content) catch null;
        }
    }
    return null;
}

fn extractLinkHref(xml: []const u8, allocator: Allocator) ?[]u8 {
    const pattern = "<link href=\"";
    if (std.mem.indexOf(u8, xml, pattern)) |start_pos| {
        const content_start = start_pos + pattern.len;
        if (std.mem.indexOf(u8, xml[content_start..], "\"")) |end_offset| {
            const content_end = content_start + end_offset;
            const href = xml[content_start..content_end];
            return allocator.dupe(u8, href) catch null;
        }
    }
    return null;
}

fn extractCategoryTerm(xml: []const u8, allocator: Allocator) ?[]u8 {
    const pattern = "<category term=\"";
    if (std.mem.indexOf(u8, xml, pattern)) |start_pos| {
        const content_start = start_pos + pattern.len;
        if (std.mem.indexOf(u8, xml[content_start..], "\"")) |end_offset| {
            const content_end = content_start + end_offset;
            const term = xml[content_start..content_end];
            return allocator.dupe(u8, term) catch null;
        }
    }
    return null;
}

fn unescapeXml(allocator: Allocator, input: []const u8) ![]u8 {
    var result = ArrayList(u8).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '&') {
            if (std.mem.startsWith(u8, input[i..], "&lt;")) {
                try result.append('<');
                i += 4;
            } else if (std.mem.startsWith(u8, input[i..], "&gt;")) {
                try result.append('>');
                i += 4;
            } else if (std.mem.startsWith(u8, input[i..], "&amp;")) {
                try result.append('&');
                i += 5;
            } else if (std.mem.startsWith(u8, input[i..], "&quot;")) {
                try result.append('"');
                i += 6;
            } else if (std.mem.startsWith(u8, input[i..], "&apos;")) {
                try result.append('\'');
                i += 6;
            } else {
                try result.append(input[i]);
                i += 1;
            }
        } else {
            try result.append(input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

// Tests
test "parse simple atom entry" {
    const allocator = std.testing.allocator;

    const entry_xml =
        \\<entry>
        \\  <title>test/repo - v1.0.0</title>
        \\  <link href="https://github.com/test/repo/releases/tag/v1.0.0"/>
        \\  <id>https://github.com/test/repo/releases/tag/v1.0.0</id>
        \\  <updated>2024-01-01T00:00:00Z</updated>
        \\  <author><n>github</n></author>
        \\  <summary>Test release</summary>
        \\  <category term="github"/>
        \\</entry>
    ;

    const release = try parseEntry(allocator, entry_xml);
    defer release.deinit(allocator);

    try std.testing.expectEqualStrings("test/repo", release.repo_name);
    try std.testing.expectEqualStrings("v1.0.0", release.tag_name);
    try std.testing.expectEqualStrings("https://github.com/test/repo/releases/tag/v1.0.0", release.html_url);
    try std.testing.expectEqualStrings("2024-01-01T00:00:00Z", release.published_at);
    try std.testing.expectEqualStrings("Test release", release.description);
    try std.testing.expectEqualStrings("github", release.provider);
}

test "parse atom entry with escaped characters" {
    const allocator = std.testing.allocator;

    const entry_xml =
        \\<entry>
        \\  <title>test/repo&lt;script&gt; - v1.0.0 &amp; more</title>
        \\  <link href="https://github.com/test/repo/releases/tag/v1.0.0"/>
        \\  <id>https://github.com/test/repo/releases/tag/v1.0.0</id>
        \\  <updated>2024-01-01T00:00:00Z</updated>
        \\  <author><n>github</n></author>
        \\  <summary>Test &quot;release&quot; with &lt;special&gt; chars &amp; symbols</summary>
        \\  <category term="github"/>
        \\</entry>
    ;

    const release = try parseEntry(allocator, entry_xml);
    defer release.deinit(allocator);

    try std.testing.expectEqualStrings("test/repo<script>", release.repo_name);
    try std.testing.expectEqualStrings("v1.0.0 & more", release.tag_name);
    try std.testing.expectEqualStrings("Test \"release\" with <special> chars & symbols", release.description);
}

test "parse full atom feed" {
    const allocator = std.testing.allocator;

    const atom_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<title>Repository Releases</title>
        \\<subtitle>New releases from starred repositories</subtitle>
        \\<link href="https://github.com" rel="alternate"/>
        \\<link href="https://example.com/releases.xml" rel="self"/>
        \\<id>https://example.com/releases</id>
        \\<updated>2024-01-01T00:00:00Z</updated>
        \\<entry>
        \\  <title>test/repo1 - v1.0.0</title>
        \\  <link href="https://github.com/test/repo1/releases/tag/v1.0.0"/>
        \\  <id>https://github.com/test/repo1/releases/tag/v1.0.0</id>
        \\  <updated>2024-01-01T00:00:00Z</updated>
        \\  <author><n>github</n></author>
        \\  <summary>First release</summary>
        \\  <category term="github"/>
        \\</entry>
        \\<entry>
        \\  <title>test/repo2 - v2.0.0</title>
        \\  <link href="https://github.com/test/repo2/releases/tag/v2.0.0"/>
        \\  <id>https://github.com/test/repo2/releases/tag/v2.0.0</id>
        \\  <updated>2024-01-02T00:00:00Z</updated>
        \\  <author><n>github</n></author>
        \\  <summary>Second release</summary>
        \\  <category term="github"/>
        \\</entry>
        \\</feed>
    ;

    var releases = try parseAtomFeed(allocator, atom_xml);
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    try std.testing.expectEqual(@as(usize, 2), releases.items.len);

    try std.testing.expectEqualStrings("test/repo1", releases.items[0].repo_name);
    try std.testing.expectEqualStrings("v1.0.0", releases.items[0].tag_name);
    try std.testing.expectEqualStrings("First release", releases.items[0].description);

    try std.testing.expectEqualStrings("test/repo2", releases.items[1].repo_name);
    try std.testing.expectEqualStrings("v2.0.0", releases.items[1].tag_name);
    try std.testing.expectEqualStrings("Second release", releases.items[1].description);
}

test "XML unescaping" {
    const allocator = std.testing.allocator;

    const input = "Test &lt;tag&gt; &amp; &quot;quotes&quot; &amp; &apos;apostrophes&apos;";
    const result = try unescapeXml(allocator, input);
    defer allocator.free(result);

    const expected = "Test <tag> & \"quotes\" & 'apostrophes'";
    try std.testing.expectEqualStrings(expected, result);
}

test "parse entry with missing fields" {
    const allocator = std.testing.allocator;

    const entry_xml =
        \\<entry>
        \\  <title>test/repo - v1.0.0</title>
        \\  <link href="https://github.com/test/repo/releases/tag/v1.0.0"/>
        \\</entry>
    ;

    const release = try parseEntry(allocator, entry_xml);
    defer release.deinit(allocator);

    try std.testing.expectEqualStrings("test/repo", release.repo_name);
    try std.testing.expectEqualStrings("v1.0.0", release.tag_name);
    try std.testing.expectEqualStrings("https://github.com/test/repo/releases/tag/v1.0.0", release.html_url);
    // Missing fields should be empty strings
    try std.testing.expectEqualStrings("", release.published_at);
    try std.testing.expectEqualStrings("", release.description);
    try std.testing.expectEqualStrings("", release.provider);
}
