const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Release = @import("main.zig").Release;

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

    // Add current timestamp in ISO 8601 format
    const timestamp = std.time.timestamp();
    try writer.print("<updated>{d}-01-01T00:00:00Z</updated>\n", .{1970 + @divTrunc(timestamp, 31536000)});

    // Add entries
    for (releases) |release| {
        try writer.writeAll("<entry>\n");
        try writer.print("  <title>{s} - {s}</title>\n", .{ release.repo_name, release.tag_name });
        try writer.print("  <link href=\"{s}\"/>\n", .{release.html_url});
        try writer.print("  <id>{s}</id>\n", .{release.html_url});
        try writer.print("  <updated>{s}</updated>\n", .{release.published_at});
        try writer.print("  <author><name>{s}</name></author>\n", .{release.provider});
        try writer.print("  <summary>{s}</summary>\n", .{release.description});
        try writer.print("  <category term=\"{s}\"/>\n", .{release.provider});
        try writer.writeAll("</entry>\n");
    }

    try writer.writeAll("</feed>\n");

    return buffer.toOwnedSlice();
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
