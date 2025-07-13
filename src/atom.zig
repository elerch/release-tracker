const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const zeit = @import("zeit");

const Release = @import("main.zig").Release;

fn escapeXml(writer: anytype, input: []const u8) !void {
    for (input) |char| {
        switch (char) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&apos;"),
            else => try writer.writeByte(char),
        }
    }
}

pub fn generateFeed(allocator: Allocator, releases: []const Release) ![]u8 {
    var buffer = ArrayList(u8).init(allocator);
    defer buffer.deinit();

    const writer = buffer.writer();

    // Atom header
    try writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<title>Repository Releases</title>
        \\<subtitle>New releases from starred repositories</subtitle>
        \\<link href="https://github.com" rel="alternate"/>
        \\<link href="https://example.com/releases.xml" rel="self"/>
        \\<id>https://example.com/releases</id>
        \\
    );

    // Add current timestamp in proper ISO 8601 format using zeit
    const now = zeit.instant(.{}) catch zeit.instant(.{ .source = .now }) catch unreachable;
    const time = now.time();
    var buf: [64]u8 = undefined;
    const updated_str = try time.bufPrint(&buf, .rfc3339);
    try writer.print("<updated>{s}</updated>\n", .{updated_str});

    // Add entries
    for (releases) |release| {
        try writer.writeAll("<entry>\n");

        try writer.writeAll("  <title>");
        try escapeXml(writer, release.repo_name);
        try writer.writeAll(" - ");
        try escapeXml(writer, release.tag_name);
        try writer.writeAll("</title>\n");

        try writer.writeAll("  <link href=\"");
        try escapeXml(writer, release.html_url);
        try writer.writeAll("\"/>\n");

        try writer.writeAll("  <id>");
        try escapeXml(writer, release.html_url);
        try writer.writeAll("</id>\n");

        try writer.writeAll("  <updated>");
        try escapeXml(writer, release.published_at);
        try writer.writeAll("</updated>\n");

        try writer.writeAll("  <author><name>");
        try escapeXml(writer, release.provider);
        try writer.writeAll("</name></author>\n");

        try writer.writeAll("  <summary>");
        try escapeXml(writer, release.description);
        try writer.writeAll("</summary>\n");

        try writer.writeAll("  <category term=\"");
        try escapeXml(writer, release.provider);
        try writer.writeAll("\"/>\n");

        try writer.writeAll("</entry>\n");
    }

    try writer.writeAll("</feed>\n");

    return buffer.toOwnedSlice();
}

test "XML escaping" {
    const allocator = std.testing.allocator;

    var buffer = ArrayList(u8).init(allocator);
    defer buffer.deinit();

    const input = "Test <tag> & \"quotes\" & 'apostrophes'";
    try escapeXml(buffer.writer(), input);

    const result = try buffer.toOwnedSlice();
    defer allocator.free(result);

    const expected = "Test &lt;tag&gt; &amp; &quot;quotes&quot; &amp; &apos;apostrophes&apos;";
    try std.testing.expectEqualStrings(expected, result);
}

test "Atom feed generation" {
    const allocator = std.testing.allocator;

    const releases = [_]Release{
        Release{
            .repo_name = "test/repo",
            .tag_name = "v1.0.0",
            .published_at = "2024-01-01T00:00:00Z",
            .html_url = "https://github.com/test/repo/releases/tag/v1.0.0",
            .description = "Test release",
            .provider = "github",
        },
    };

    const atom_content = try generateFeed(allocator, &releases);
    defer allocator.free(atom_content);

    try std.testing.expect(std.mem.indexOf(u8, atom_content, "test/repo") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "v1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<feed xmlns=\"http://www.w3.org/2005/Atom\">") != null);
}

test "Atom feed with special characters" {
    const allocator = std.testing.allocator;

    const releases = [_]Release{
        Release{
            .repo_name = "test/repo<script>",
            .tag_name = "v1.0.0 & more",
            .published_at = "2024-01-01T00:00:00Z",
            .html_url = "https://github.com/test/repo/releases/tag/v1.0.0",
            .description = "Test \"release\" with <special> chars & symbols",
            .provider = "github",
        },
    };

    const atom_content = try generateFeed(allocator, &releases);
    defer allocator.free(atom_content);

    // Verify special characters are properly escaped
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "&amp; more") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "&quot;release&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "&lt;special&gt;") != null);

    // Verify raw special characters are not present
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "\"release\"") == null);
}
