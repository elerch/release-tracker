const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const testing = std.testing;

pub const ConversionResult = struct {
    html: []u8,
    has_fallback: bool,

    pub fn deinit(self: ConversionResult, allocator: Allocator) void {
        allocator.free(self.html);
    }
};

/// Convert markdown text to HTML with fallback to <pre> blocks for unhandled content
pub fn convertMarkdownToHtml(allocator: Allocator, markdown: []const u8) !ConversionResult {
    var result = ArrayList(u8).init(allocator);
    defer result.deinit();

    var has_fallback = false;
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    var in_list = false;
    var list_type: ?u8 = null; // '*' or '-'

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len == 0) {
            try result.appendSlice("<br/>\n");
            continue;
        }

        // Handle headers
        if (std.mem.startsWith(u8, trimmed, "## ")) {
            if (in_list) {
                try result.appendSlice("</ul>\n");
                in_list = false;
                list_type = null;
            }
            const header_text = trimmed[3..];
            try result.appendSlice("<h2>");
            try appendEscapedHtml(&result, header_text);
            try result.appendSlice("</h2>\n");
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "### ")) {
            if (in_list) {
                try result.appendSlice("</ul>\n");
                in_list = false;
                list_type = null;
            }
            const header_text = trimmed[4..];
            try result.appendSlice("<h3>");
            try appendEscapedHtml(&result, header_text);
            try result.appendSlice("</h3>\n");
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "#### ")) {
            if (in_list) {
                try result.appendSlice("</ul>\n");
                in_list = false;
                list_type = null;
            }
            const header_text = trimmed[5..];
            try result.appendSlice("<h4>");
            try appendEscapedHtml(&result, header_text);
            try result.appendSlice("</h4>\n");
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "##### ")) {
            if (in_list) {
                try result.appendSlice("</ul>\n");
                in_list = false;
                list_type = null;
            }
            const header_text = trimmed[6..];
            try result.appendSlice("<h5>");
            try appendEscapedHtml(&result, header_text);
            try result.appendSlice("</h5>\n");
            continue;
        }

        // Handle list items
        if (std.mem.startsWith(u8, trimmed, "* ") or std.mem.startsWith(u8, trimmed, "- ")) {
            const current_marker = trimmed[0];
            const item_text = trimmed[2..];

            if (!in_list or list_type != current_marker) {
                if (in_list) {
                    try result.appendSlice("</ul>\n");
                }
                try result.appendSlice("<ul>\n");
                in_list = true;
                list_type = current_marker;
            }

            try result.appendSlice("<li>");
            try appendProcessedText(&result, item_text);
            try result.appendSlice("</li>\n");
            continue;
        }

        // Close list if we're in one and this isn't a list item
        if (in_list) {
            try result.appendSlice("</ul>\n");
            in_list = false;
            list_type = null;
        }

        // Check for complex markdown patterns that we don't handle
        if (hasComplexMarkdown(trimmed)) {
            has_fallback = true;
            try result.appendSlice("<pre>");
            try appendEscapedHtml(&result, trimmed);
            try result.appendSlice("</pre>\n");
            continue;
        }

        // Regular paragraph
        try result.appendSlice("<p>");
        try appendProcessedText(&result, trimmed);
        try result.appendSlice("</p>\n");
    }

    // Close any remaining list
    if (in_list) {
        try result.appendSlice("</ul>\n");
    }

    return ConversionResult{
        .html = try result.toOwnedSlice(),
        .has_fallback = has_fallback,
    };
}

/// Process text for inline formatting (links, bold, italic)
fn appendProcessedText(result: *ArrayList(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        // Handle markdown links [text](url)
        if (text[i] == '[') {
            if (findMarkdownLink(text[i..])) |link_info| {
                try result.appendSlice("<a href=\"");
                try appendEscapedHtml(result, link_info.url);
                try result.appendSlice("\">");
                try appendEscapedHtml(result, link_info.text);
                try result.appendSlice("</a>");
                i += link_info.total_len;
                continue;
            }
        }

        // Handle bold **text**
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (findBoldText(text[i..])) |bold_info| {
                try result.appendSlice("<strong>");
                try appendEscapedHtml(result, bold_info.text);
                try result.appendSlice("</strong>");
                i += bold_info.total_len;
                continue;
            }
        }

        // Handle italic *text* (but not if it's part of **)
        if (text[i] == '*' and (i == 0 or text[i - 1] != '*') and (i + 1 >= text.len or text[i + 1] != '*')) {
            if (findItalicText(text[i..])) |italic_info| {
                try result.appendSlice("<em>");
                try appendEscapedHtml(result, italic_info.text);
                try result.appendSlice("</em>");
                i += italic_info.total_len;
                continue;
            }
        }

        // Handle inline code `text`
        if (text[i] == '`') {
            if (findInlineCode(text[i..])) |code_info| {
                try result.appendSlice("<code>");
                try appendEscapedHtml(result, code_info.text);
                try result.appendSlice("</code>");
                i += code_info.total_len;
                continue;
            }
        }

        // Regular character - escape for HTML
        switch (text[i]) {
            '<' => try result.appendSlice("&lt;"),
            '>' => try result.appendSlice("&gt;"),
            '&' => try result.appendSlice("&amp;"),
            '"' => try result.appendSlice("&quot;"),
            '\'' => try result.appendSlice("&apos;"),
            else => try result.append(text[i]),
        }
        i += 1;
    }
}

/// Append HTML-escaped text
fn appendEscapedHtml(result: *ArrayList(u8), text: []const u8) !void {
    for (text) |char| {
        switch (char) {
            '<' => try result.appendSlice("&lt;"),
            '>' => try result.appendSlice("&gt;"),
            '&' => try result.appendSlice("&amp;"),
            '"' => try result.appendSlice("&quot;"),
            '\'' => try result.appendSlice("&apos;"),
            else => try result.append(char),
        }
    }
}

const LinkInfo = struct {
    text: []const u8,
    url: []const u8,
    total_len: usize,
};

/// Find markdown link pattern [text](url)
fn findMarkdownLink(text: []const u8) ?LinkInfo {
    if (text.len < 4 or text[0] != '[') return null;

    // Find closing ]
    var bracket_end: ?usize = null;
    for (text[1..], 1..) |char, i| {
        if (char == ']') {
            bracket_end = i;
            break;
        }
    }

    const bracket_pos = bracket_end orelse return null;
    if (bracket_pos + 1 >= text.len or text[bracket_pos + 1] != '(') return null;

    // Find closing )
    var paren_end: ?usize = null;
    for (text[bracket_pos + 2 ..], bracket_pos + 2..) |char, i| {
        if (char == ')') {
            paren_end = i;
            break;
        }
    }

    const paren_pos = paren_end orelse return null;

    return LinkInfo{
        .text = text[1..bracket_pos],
        .url = text[bracket_pos + 2 .. paren_pos],
        .total_len = paren_pos + 1,
    };
}

const TextInfo = struct {
    text: []const u8,
    total_len: usize,
};

/// Find bold text **text**
fn findBoldText(text: []const u8) ?TextInfo {
    if (text.len < 4 or !std.mem.startsWith(u8, text, "**")) return null;

    // Find closing **
    var i: usize = 2;
    while (i + 1 < text.len) {
        if (text[i] == '*' and text[i + 1] == '*') {
            return TextInfo{
                .text = text[2..i],
                .total_len = i + 2,
            };
        }
        i += 1;
    }

    return null;
}

/// Find italic text *text*
fn findItalicText(text: []const u8) ?TextInfo {
    if (text.len < 3 or text[0] != '*') return null;

    // Find closing *
    for (text[1..], 1..) |char, i| {
        if (char == '*') {
            return TextInfo{
                .text = text[1..i],
                .total_len = i + 1,
            };
        }
    }

    return null;
}

/// Find inline code `text`
fn findInlineCode(text: []const u8) ?TextInfo {
    if (text.len < 3 or text[0] != '`') return null;

    // Find closing `
    for (text[1..], 1..) |char, i| {
        if (char == '`') {
            return TextInfo{
                .text = text[1..i],
                .total_len = i + 1,
            };
        }
    }

    return null;
}

/// Check if text contains complex markdown patterns we don't handle
fn hasComplexMarkdown(text: []const u8) bool {
    // Code blocks
    if (std.mem.indexOf(u8, text, "```") != null) return true;

    // Tables
    if (std.mem.indexOf(u8, text, "|") != null) return true;

    // Images
    if (std.mem.indexOf(u8, text, "![") != null) return true;

    // Block quotes
    if (std.mem.startsWith(u8, text, "> ")) return true;

    // Horizontal rules
    if (std.mem.eql(u8, text, "---") or std.mem.eql(u8, text, "***")) return true;

    // HTML tags (already HTML, might be complex)
    if (std.mem.indexOf(u8, text, "<") != null and std.mem.indexOf(u8, text, ">") != null) return true;

    return false;
}

// Tests
test "convert headers" {
    const allocator = testing.allocator;

    const markdown = "## What's Changed\n### Bug Fixes\n#### Details\n##### Notes";
    const result = try convertMarkdownToHtml(allocator, markdown);
    defer result.deinit(allocator);

    const expected = "<h2>What&apos;s Changed</h2>\n<h3>Bug Fixes</h3>\n<h4>Details</h4>\n<h5>Notes</h5>\n";
    try testing.expectEqualStrings(expected, result.html);
    try testing.expect(!result.has_fallback);

    if (std.process.hasEnvVar(allocator, "test-debug") catch false) {
        std.debug.print("Headers test - Input: {s}\nOutput: {s}\n", .{ markdown, result.html });
    }
}

test "convert lists" {
    const allocator = testing.allocator;

    const markdown = "* First item\n* Second item\n- Different marker\n- Another item";
    const result = try convertMarkdownToHtml(allocator, markdown);
    defer result.deinit(allocator);

    const expected = "<ul>\n<li>First item</li>\n<li>Second item</li>\n</ul>\n<ul>\n<li>Different marker</li>\n<li>Another item</li>\n</ul>\n";
    try testing.expectEqualStrings(expected, result.html);
    try testing.expect(!result.has_fallback);

    if (std.process.hasEnvVar(allocator, "test-debug") catch false) {
        std.debug.print("Lists test - Input: {s}\nOutput: {s}\n", .{ markdown, result.html });
    }
}

test "convert links" {
    const allocator = testing.allocator;

    const markdown = "Check out [GitHub](https://github.com) for more info.";
    const result = try convertMarkdownToHtml(allocator, markdown);
    defer result.deinit(allocator);

    const expected = "<p>Check out <a href=\"https://github.com\">GitHub</a> for more info.</p>\n";
    try testing.expectEqualStrings(expected, result.html);
    try testing.expect(!result.has_fallback);

    if (std.process.hasEnvVar(allocator, "test-debug") catch false) {
        std.debug.print("Links test - Input: {s}\nOutput: {s}\n", .{ markdown, result.html });
    }
}

test "convert bold and italic" {
    const allocator = testing.allocator;

    const markdown = "This is **bold** and this is *italic* text.";
    const result = try convertMarkdownToHtml(allocator, markdown);
    defer result.deinit(allocator);

    const expected = "<p>This is <strong>bold</strong> and this is <em>italic</em> text.</p>\n";
    try testing.expectEqualStrings(expected, result.html);
    try testing.expect(!result.has_fallback);

    if (std.process.hasEnvVar(allocator, "test-debug") catch false) {
        std.debug.print("Bold/Italic test - Input: {s}\nOutput: {s}\n", .{ markdown, result.html });
    }
}

test "convert inline code" {
    const allocator = testing.allocator;

    const markdown = "Use the `git commit` command to save changes.";
    const result = try convertMarkdownToHtml(allocator, markdown);
    defer result.deinit(allocator);

    const expected = "<p>Use the <code>git commit</code> command to save changes.</p>\n";
    try testing.expectEqualStrings(expected, result.html);
    try testing.expect(!result.has_fallback);

    if (std.process.hasEnvVar(allocator, "test-debug") catch false) {
        std.debug.print("Inline code test - Input: {s}\nOutput: {s}\n", .{ markdown, result.html });
    }
}

test "fallback for complex markdown" {
    const allocator = testing.allocator;

    const markdown = "```javascript\nconst x = 1;\n```\n\n| Column 1 | Column 2 |\n|----------|----------|\n| Data     | More     |";
    const result = try convertMarkdownToHtml(allocator, markdown);
    defer result.deinit(allocator);

    try testing.expect(result.has_fallback);
    try testing.expect(std.mem.indexOf(u8, result.html, "<pre>") != null);

    if (std.process.hasEnvVar(allocator, "test-debug") catch false) {
        std.debug.print("Fallback test - Input: {s}\nOutput: {s}\nHas fallback: {}\n", .{ markdown, result.html, result.has_fallback });
    }
}

test "real release note example" {
    const allocator = testing.allocator;

    // Example from actual release notes in the feed
    const markdown =
        \\## What's Changed
        \\
        \\* Not generating undo records for insertions into tables created by the same transaction (performance)
        \\* Fastpath intra-page navigation in B-tree (performance)
        \\* OrioleDB database cluster rewind (experimental feature)
        \\* Support of tablespaces
        \\* Support of more than 32 columns for Oriole table
        \\* Fallback to simple reindex instead of concurrent (sql syntax compatibility)
        \\
        \\**Full Changelog**: https://github.com/orioledb/orioledb/compare/beta11...beta12
    ;

    const result = try convertMarkdownToHtml(allocator, markdown);
    defer result.deinit(allocator);

    // Should contain proper HTML structure
    try testing.expect(std.mem.indexOf(u8, result.html, "<h2>What&apos;s Changed</h2>") != null);
    try testing.expect(std.mem.indexOf(u8, result.html, "<ul>") != null);
    try testing.expect(std.mem.indexOf(u8, result.html, "<li>Not generating undo records") != null);
    try testing.expect(std.mem.indexOf(u8, result.html, "<strong>Full Changelog</strong>") != null);
    try testing.expect(!result.has_fallback);

    if (std.process.hasEnvVar(allocator, "test-debug") catch false) {
        std.debug.print("Real example test - Input: {s}\nOutput: {s}\n", .{ markdown, result.html });
    }
}

test "mixed content with headers and lists" {
    const allocator = testing.allocator;

    // Another real example pattern
    const markdown =
        \\## KraftKit v0.11.6-212-g74599361 (2025-07-13T12:45:17Z)
        \\
        \\This is the pre-release version of KraftKit.
        \\
        \\## Changelog
        \\### 🤖 Bumps
        \\* 41a6a089d3ca955711a5f5291b0ef82aa14d5792: gomod(deps): Bump github.com/charmbracelet/bubbletea from 1.3.5 to 1.3.6 (@dependabot[bot])
        \\* ef77627f58e50f5ad027ff06c8d365db57feb020: gomod(deps): Bump golang.org/x/term from 0.32.0 to 0.33.0 (@dependabot[bot])
    ;

    const result = try convertMarkdownToHtml(allocator, markdown);
    defer result.deinit(allocator);

    // Should contain proper HTML structure
    try testing.expect(std.mem.indexOf(u8, result.html, "<h2>KraftKit v0.11.6-212-g74599361") != null);
    try testing.expect(std.mem.indexOf(u8, result.html, "<h2>Changelog</h2>") != null);
    try testing.expect(std.mem.indexOf(u8, result.html, "<h3>🤖 Bumps</h3>") != null);
    try testing.expect(std.mem.indexOf(u8, result.html, "<ul>") != null);
    try testing.expect(std.mem.indexOf(u8, result.html, "<li>41a6a089d3ca955711a5f5291b0ef82aa14d5792") != null);
    try testing.expect(!result.has_fallback);

    if (std.process.hasEnvVar(allocator, "test-debug") catch false) {
        std.debug.print("Mixed content test - Input: {s}\nOutput: {s}\n", .{ markdown, result.html });
    }
}

test "html escaping" {
    const allocator = testing.allocator;

    const markdown = "## Test <script>alert('xss')</script> & \"quotes\"";
    const result = try convertMarkdownToHtml(allocator, markdown);
    defer result.deinit(allocator);

    const expected = "<h2>Test &lt;script&gt;alert(&apos;xss&apos;)&lt;/script&gt; &amp; &quot;quotes&quot;</h2>\n";
    try testing.expectEqualStrings(expected, result.html);
    try testing.expect(!result.has_fallback);

    if (std.process.hasEnvVar(allocator, "test-debug") catch false) {
        std.debug.print("HTML escaping test - Input: {s}\nOutput: {s}\n", .{ markdown, result.html });
    }
}
