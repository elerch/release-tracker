const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const zeit = @import("zeit");

const Release = @import("main.zig").Release;
const markdown = @import("markdown.zig");

fn escapeXml(writer: anytype, input: []const u8) !void {
    var i: usize = 0;
    var open_spans: u8 = 0; // Track number of open spans

    while (i < input.len) {
        const char = input[i];

        // Handle ANSI escape sequences
        if (char == 0x1B and i + 1 < input.len and input[i + 1] == '[') {
            // Found ANSI escape sequence, convert to HTML
            i += 2; // Skip ESC and [
            const code_start = i;

            // Find the end of the ANSI sequence
            while (i < input.len) {
                const c = input[i];
                i += 1;
                // ANSI sequences end with a letter (A-Z, a-z)
                if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
                    // Extract the numeric codes
                    const codes = input[code_start .. i - 1];
                    try convertAnsiToHtml(writer, codes, c, &open_spans);
                    break;
                }
            }
            continue;
        }

        switch (char) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&apos;"),
            // Valid XML characters: #x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD] | [#x10000-#x10FFFF]
            0x09, 0x0A, 0x0D => try writer.writeByte(char), // Tab, LF, CR
            else => {
                if (char >= 0x20 and char <= 0x7F) {
                    // Printable ASCII (excluding already handled special chars)
                    try writer.writeByte(char);
                } else if (char >= 0x80) {
                    // Extended ASCII (will be handled as UTF-8)
                    try writer.writeByte(char);
                } else if (char < 0x20) {
                    // Other control characters - replace with space to preserve spacing
                    try writer.writeByte(' ');
                } else {
                    // else skip completely invalid characters
                    const start = if (i < 10) 0 else i - 10;
                    std.log.warn("invalid character 0x{x} encountered, skipping. Previous {} chars: {s}", .{ char, i - start, input[start..i] });
                }
            },
        }
        i += 1;
    }

    // Close any remaining open spans
    while (open_spans > 0) {
        try writer.writeAll("</span>");
        open_spans -= 1;
    }
}

fn convertAnsiToHtml(writer: anytype, codes: []const u8, end_char: u8, open_spans: *u8) !void {
    // Only handle SGR (Select Graphic Rendition) sequences that end with 'm'
    if (end_char != 'm') {
        return; // Skip non-color sequences
    }

    // Parse semicolon-separated codes
    var code_iter = std.mem.splitScalar(u8, codes, ';');
    var has_styles = false;

    // Use a fixed buffer for styles to avoid allocation
    var styles_buf: [256]u8 = undefined;
    var styles_len: usize = 0;

    while (code_iter.next()) |code_str| {
        const code = std.fmt.parseInt(u8, std.mem.trim(u8, code_str, " "), 10) catch continue;

        switch (code) {
            0 => {
                // Reset - close all open spans
                while (open_spans.* > 0) {
                    try writer.writeAll("</span>");
                    open_spans.* -= 1;
                }
                return;
            },
            1 => {
                // Bold
                const style = if (has_styles) ";font-weight:bold" else "font-weight:bold";
                if (styles_len + style.len < styles_buf.len) {
                    @memcpy(styles_buf[styles_len .. styles_len + style.len], style);
                    styles_len += style.len;
                    has_styles = true;
                }
            },
            22 => {
                // Normal intensity (turn off bold) - close current span and open new one without bold
                if (open_spans.* > 0) {
                    try writer.writeAll("</span>");
                    open_spans.* -= 1;
                }
                // Don't add font-weight:normal as a new style, just close the bold span
                return;
            },
            30 => try appendColorToBuffer(&styles_buf, &styles_len, &has_styles, "color:#000000"), // Black
            31 => try appendColorToBuffer(&styles_buf, &styles_len, &has_styles, "color:#800000"), // Red
            32 => try appendColorToBuffer(&styles_buf, &styles_len, &has_styles, "color:#008000"), // Green
            33 => try appendColorToBuffer(&styles_buf, &styles_len, &has_styles, "color:#808000"), // Yellow
            34 => try appendColorToBuffer(&styles_buf, &styles_len, &has_styles, "color:#000080"), // Blue
            35 => try appendColorToBuffer(&styles_buf, &styles_len, &has_styles, "color:#800080"), // Magenta
            36 => try appendColorToBuffer(&styles_buf, &styles_len, &has_styles, "color:#008080"), // Cyan
            37 => try appendColorToBuffer(&styles_buf, &styles_len, &has_styles, "color:#c0c0c0"), // White
            39 => try appendColorToBuffer(&styles_buf, &styles_len, &has_styles, "color:inherit"), // Default foreground
            90 => try appendColorToBuffer(&styles_buf, &styles_len, &has_styles, "color:#808080"), // Bright Black (Gray)
            91 => try appendColorToBuffer(&styles_buf, &styles_len, &has_styles, "color:#ff0000"), // Bright Red
            92 => try appendColorToBuffer(&styles_buf, &styles_len, &has_styles, "color:#00ff00"), // Bright Green
            93 => try appendColorToBuffer(&styles_buf, &styles_len, &has_styles, "color:#ffff00"), // Bright Yellow
            94 => try appendColorToBuffer(&styles_buf, &styles_len, &has_styles, "color:#0000ff"), // Bright Blue
            95 => try appendColorToBuffer(&styles_buf, &styles_len, &has_styles, "color:#ff00ff"), // Bright Magenta
            96 => try appendColorToBuffer(&styles_buf, &styles_len, &has_styles, "color:#00ffff"), // Bright Cyan
            97 => try appendColorToBuffer(&styles_buf, &styles_len, &has_styles, "color:#ffffff"), // Bright White
            else => {}, // Ignore unknown codes
        }
    }

    if (has_styles) {
        try writer.writeAll("<span style=\"");
        try writer.writeAll(styles_buf[0..styles_len]);
        try writer.writeAll("\">");
        open_spans.* += 1;
    }
}

fn appendColorToBuffer(styles_buf: *[256]u8, styles_len: *usize, has_styles: *bool, color: []const u8) !void {
    const prefix = if (has_styles.*) ";" else "";
    const total_len = prefix.len + color.len;

    if (styles_len.* + total_len < styles_buf.len) {
        if (prefix.len > 0) {
            @memcpy(styles_buf[styles_len.* .. styles_len.* + prefix.len], prefix);
            styles_len.* += prefix.len;
        }
        @memcpy(styles_buf[styles_len.* .. styles_len.* + color.len], color);
        styles_len.* += color.len;
        has_styles.* = true;
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
        \\<link href="https://releases.lerch.org" rel="alternate"/>
        \\<link href="https://releases.lerch.org/atom.xml" rel="self"/>
        \\<id>https://releases.lerch.org</id>
        \\
    );

    // Add current timestamp in proper ISO 8601 format using zeit
    const now = zeit.instant(.{}) catch zeit.instant(.{ .source = .now }) catch @panic("Failed to get current time");
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
        if (release.is_tag) {
            try writer.writeAll(":tag");
        }
        try writer.writeAll("</title>\n");

        try writer.writeAll("  <link href=\"");
        try escapeXml(writer, release.html_url);
        try writer.writeAll("\"/>\n");

        try writer.writeAll("  <id>");
        try escapeXml(writer, release.html_url);
        try writer.writeAll("</id>\n");

        try writer.writeAll("  <updated>");
        const published = zeit.Instant{
            .timestamp = release.published_at * std.time.ns_per_s,
            .timezone = &zeit.utc,
        };
        try published.time().strftime(writer, "%Y-%m-%dT%H:%M:%SZ");
        try writer.writeAll("</updated>\n");

        try writer.writeAll("  <author><name>");
        try escapeXml(writer, release.provider);
        try writer.writeAll("</name></author>\n");

        // Convert markdown to HTML
        const conversion_result = try markdown.convertMarkdownToHtml(allocator, release.description);
        defer conversion_result.deinit(allocator);

        // Add content with proper type attribute and XML-escaped HTML
        try writer.writeAll("  <content type=\"html\">");
        try escapeXml(writer, conversion_result.html);
        try writer.writeAll("</content>\n");

        // Add fallback metadata if markdown conversion used fallback
        if (conversion_result.has_fallback) {
            try writer.writeAll("  <category term=\"markdown-fallback\" label=\"Contains unprocessed markdown\"/>\n");
        }

        try writer.writeAll("  <category term=\"");
        try escapeXml(writer, release.provider);
        try writer.writeAll("\"/>\n");

        try writer.writeAll("</entry>\n");
    }

    try writer.writeAll("</feed>\n");

    return buffer.toOwnedSlice();
}

test "XML escaping with ANSI sequences" {
    const allocator = std.testing.allocator;

    var buffer = ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Test input with ANSI color codes like those found in terminal output
    const input = "Test \x1B[36mcolored\x1B[0m text and \x1B[1mbold\x1B[22m formatting";
    try escapeXml(buffer.writer(), input);

    const result = try buffer.toOwnedSlice();
    defer allocator.free(result);

    // ANSI sequences should be converted to HTML spans
    try std.testing.expect(std.mem.indexOf(u8, result, "<span style=\"color:#008080\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "colored") != null);
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

test "Atom feed generation with markdown" {
    const allocator = std.testing.allocator;

    const releases = [_]Release{
        Release{
            .repo_name = "test/repo",
            .tag_name = "v1.0.0",
            .published_at = @intCast(@divTrunc(
                (try zeit.instant(.{ .source = .{ .iso8601 = "2024-01-01T00:00:00Z" } })).timestamp,
                std.time.ns_per_s,
            )),
            .html_url = "https://github.com/test/repo/releases/tag/v1.0.0",
            .description = "## What's Changed\n* Fixed bug\n* Added feature",
            .provider = "github",
            .is_tag = false,
        },
    };

    const atom_content = try generateFeed(allocator, &releases);
    defer allocator.free(atom_content);

    try std.testing.expect(std.mem.indexOf(u8, atom_content, "test/repo") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "v1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<feed xmlns=\"http://www.w3.org/2005/Atom\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<content type=\"html\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "&lt;h2&gt;What&amp;apos;s Changed&lt;/h2&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "&lt;ul&gt;") != null);
}

test "Atom feed with fenced code blocks" {
    const allocator = std.testing.allocator;

    const releases = [_]Release{
        Release{
            .repo_name = "test/repo",
            .tag_name = "v1.0.0",
            .published_at = @intCast(@divTrunc(
                (try zeit.instant(.{ .source = .{ .iso8601 = "2024-01-01T00:00:00Z" } })).timestamp,
                std.time.ns_per_s,
            )),
            .html_url = "https://github.com/test/repo/releases/tag/v1.0.0",
            .description = "Here's some code:\n```javascript\nconst greeting = 'Hello World';\nconsole.log(greeting);\n```\nEnd of example.",
            .provider = "github",
            .is_tag = false,
        },
    };

    const atom_content = try generateFeed(allocator, &releases);
    defer allocator.free(atom_content);

    // Should NOT contain fallback metadata since fenced code blocks are now supported
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "markdown-fallback") == null);

    // Should contain proper HTML code block structure
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "&lt;pre&gt;&lt;code class=&quot;language-javascript&quot;&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "&lt;/code&gt;&lt;/pre&gt;") != null);

    // Should contain the escaped code content
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "const greeting = &amp;apos;Hello World&amp;apos;;") != null);
}

test "Atom feed with fallback markdown" {
    const allocator = std.testing.allocator;

    const releases = [_]Release{
        Release{
            .repo_name = "test/repo",
            .tag_name = "v1.0.0",
            .published_at = @intCast(@divTrunc(
                (try zeit.instant(.{ .source = .{ .iso8601 = "2024-01-01T00:00:00Z" } })).timestamp,
                std.time.ns_per_s,
            )),
            .html_url = "https://github.com/test/repo/releases/tag/v1.0.0",
            .description = "| Column 1 | Column 2 |\n|----------|----------|\n| Value 1  | Value 2  |",
            .provider = "github",
            .is_tag = false,
        },
    };

    const atom_content = try generateFeed(allocator, &releases);
    defer allocator.free(atom_content);

    // Should contain fallback metadata
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "markdown-fallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "&lt;pre&gt;") != null);
}

test "Atom feed with special characters" {
    const allocator = std.testing.allocator;

    const releases = [_]Release{
        Release{
            .repo_name = "test/repo<script>",
            .tag_name = "v1.0.0 & more",
            .published_at = @intCast(@divTrunc(
                (try zeit.instant(.{ .source = .{ .iso8601 = "2024-01-01T00:00:00Z" } })).timestamp,
                std.time.ns_per_s,
            )),
            .html_url = "https://github.com/test/repo/releases/tag/v1.0.0",
            .description = "Test \"release\" with <special> chars & symbols",
            .provider = "github",
            .is_tag = false,
        },
    };

    const atom_content = try generateFeed(allocator, &releases);
    defer allocator.free(atom_content);

    // Verify special characters are properly escaped in title
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "&amp; more") != null);

    // Verify raw special characters are not present
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<script>") == null);
}
