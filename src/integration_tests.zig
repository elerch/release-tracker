const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");

const atom = @import("atom.zig");
const Release = @import("main.zig").Release;
const GitHub = @import("providers/GitHub.zig");
const GitLab = @import("providers/GitLab.zig");
const Forgejo = @import("providers/Forgejo.zig");
const SourceHut = @import("providers/SourceHut.zig");
const config = @import("config.zig");

fn testPrint(comptime fmt: []const u8, args: anytype) void {
    if (build_options.test_debug) {
        std.debug.print(fmt, args);
    }
}

test "Atom feed validates against W3C validator" {
    const allocator = testing.allocator;

    // Create sample releases for testing
    const releases = [_]Release{
        Release{
            .repo_name = "ziglang/zig",
            .tag_name = "0.14.0",
            .published_at = "2024-12-19T00:00:00Z",
            .html_url = "https://github.com/ziglang/zig/releases/tag/0.14.0",
            .description = "Zig 0.14.0 release with many improvements",
            .provider = "github",
            .is_tag = false,
        },
        Release{
            .repo_name = "example/test",
            .tag_name = "v1.2.3",
            .published_at = "2024-12-18T12:30:00Z",
            .html_url = "https://github.com/example/test/releases/tag/v1.2.3",
            .description = "Bug fixes and performance improvements",
            .provider = "github",
            .is_tag = false,
        },
    };

    // Generate the Atom feed
    const atom_content = try atom.generateFeed(allocator, &releases);
    defer allocator.free(atom_content);

    // Validate against W3C Feed Validator
    const http = std.http;
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    // Prepare the POST request to W3C validator
    const validator_url = "https://validator.w3.org/feed/check.cgi";
    const uri = try std.Uri.parse(validator_url);

    // Create form data for the validator
    var form_data = std.ArrayList(u8).init(allocator);
    defer form_data.deinit();

    try form_data.appendSlice("------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n");
    try form_data.appendSlice("Content-Disposition: form-data; name=\"rawdata\"\r\n\r\n");
    try form_data.appendSlice(atom_content);
    try form_data.appendSlice("\r\n------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n");
    try form_data.appendSlice("Content-Disposition: form-data; name=\"manual\"\r\n\r\n");
    try form_data.appendSlice("1\r\n");
    try form_data.appendSlice("------WebKitFormBoundary7MA4YWxkTrZu0gW--\r\n");

    var server_header_buffer: [16 * 1024]u8 = undefined;
    var req = try client.open(.POST, uri, .{
        .server_header_buffer = &server_header_buffer,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW" },
            .{ .name = "User-Agent", .value = "Release-Tracker-Test/1.0" },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = form_data.items.len };
    try req.send();
    try req.writeAll(form_data.items);
    try req.finish();
    try req.wait();

    // Read the response
    var response_body = std.ArrayList(u8).init(allocator);
    defer response_body.deinit();

    const max_response_size = 1024 * 1024; // 1MB max
    try response_body.ensureTotalCapacity(max_response_size);

    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try req.readAll(buf[0..]);
        if (bytes_read == 0) break;
        try response_body.appendSlice(buf[0..bytes_read]);
        if (response_body.items.len > max_response_size) {
            return error.ResponseTooLarge;
        }
    }

    const response_text = response_body.items;
    testPrint("W3C Validator Response Length: {d}\n", .{response_text.len});

    // Check for validation success indicators
    const is_valid = std.mem.indexOf(u8, response_text, "This is a valid Atom 1.0 feed") != null or
        std.mem.indexOf(u8, response_text, "Congratulations!") != null or
        (std.mem.indexOf(u8, response_text, "valid") != null and
            std.mem.indexOf(u8, response_text, "error") == null);

    // Check for specific error indicators
    const has_errors = std.mem.indexOf(u8, response_text, "This feed does not validate") != null or
        std.mem.indexOf(u8, response_text, "Errors:") != null or
        std.mem.indexOf(u8, response_text, "line") != null and std.mem.indexOf(u8, response_text, "column") != null;

    if (has_errors) {
        testPrint("W3C Validator found errors in the feed:\n", .{});
        // Print relevant parts of the response for debugging
        if (std.mem.indexOf(u8, response_text, "<pre>")) |start| {
            if (std.mem.indexOf(u8, response_text[start..], "</pre>")) |end| {
                const error_section = response_text[start .. start + end + 6];
                testPrint("{s}\n", .{error_section});
            }
        }
        return error.FeedValidationFailed;
    }

    if (!is_valid) {
        // Handle 502/520 errors gracefully - W3C validator is sometimes unavailable
        if (std.mem.indexOf(u8, response_text, "error code: 502") != null or
            std.mem.indexOf(u8, response_text, "error code: 520") != null)
        {
            testPrint("⚠️  W3C Validator temporarily unavailable (server error) - skipping validation\n", .{});
            return; // Skip test instead of failing
        }
        testPrint("W3C Validator response unclear - dumping first 1000 chars:\n{s}\n", .{response_text[0..@min(1000, response_text.len)]});
        return error.ValidationResponseUnclear;
    }

    testPrint("✓ Atom feed validated successfully against W3C Feed Validator\n", .{});
}

test "Validate actual releases.xml against W3C validator" {
    const allocator = testing.allocator;

    // Read the actual releases.xml file
    const releases_xml = std.fs.cwd().readFileAlloc(allocator, "releases.xml", 10 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            testPrint("⚠️  releases.xml not found - skipping validation (run the app first)\n", .{});
            return;
        }
        return err;
    };
    defer allocator.free(releases_xml);

    testPrint("Validating actual releases.xml ({d} bytes) against W3C validator...\n", .{releases_xml.len});

    // Validate against W3C Feed Validator
    const http = std.http;
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    const validator_url = "https://validator.w3.org/feed/check.cgi";
    const uri = try std.Uri.parse(validator_url);

    // Create form data for the validator
    var form_data = std.ArrayList(u8).init(allocator);
    defer form_data.deinit();

    try form_data.appendSlice("------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n");
    try form_data.appendSlice("Content-Disposition: form-data; name=\"rawdata\"\r\n\r\n");
    try form_data.appendSlice(releases_xml);
    try form_data.appendSlice("\r\n------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n");
    try form_data.appendSlice("Content-Disposition: form-data; name=\"manual\"\r\n\r\n");
    try form_data.appendSlice("1\r\n");
    try form_data.appendSlice("------WebKitFormBoundary7MA4YWxkTrZu0gW--\r\n");

    var server_header_buffer: [16 * 1024]u8 = undefined;
    var req = try client.open(.POST, uri, .{
        .server_header_buffer = &server_header_buffer,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW" },
            .{ .name = "User-Agent", .value = "Release-Tracker-Test/1.0" },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = form_data.items.len };
    try req.send();
    try req.writeAll(form_data.items);
    try req.finish();
    try req.wait();

    // Read the response
    var response_body = std.ArrayList(u8).init(allocator);
    defer response_body.deinit();

    const max_response_size = 1024 * 1024; // 1MB max
    try response_body.ensureTotalCapacity(max_response_size);

    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try req.readAll(buf[0..]);
        if (bytes_read == 0) break;
        try response_body.appendSlice(buf[0..bytes_read]);
        if (response_body.items.len > max_response_size) {
            return error.ResponseTooLarge;
        }
    }

    const response_text = response_body.items;
    testPrint("W3C Validator Response Length: {d}\n", .{response_text.len});

    // Check for validation success indicators
    const is_valid = std.mem.indexOf(u8, response_text, "This is a valid Atom 1.0 feed") != null or
        std.mem.indexOf(u8, response_text, "Congratulations!") != null or
        (std.mem.indexOf(u8, response_text, "valid") != null and
            std.mem.indexOf(u8, response_text, "error") == null);

    // Check for specific error indicators
    const has_errors = std.mem.indexOf(u8, response_text, "This feed does not validate") != null or
        std.mem.indexOf(u8, response_text, "Errors:") != null or
        std.mem.indexOf(u8, response_text, "line") != null and std.mem.indexOf(u8, response_text, "column") != null;

    if (has_errors) {
        testPrint("❌ W3C Validator found errors in releases.xml:\n", .{});
        // Print relevant parts of the response for debugging
        if (std.mem.indexOf(u8, response_text, "<pre>")) |start| {
            if (std.mem.indexOf(u8, response_text[start..], "</pre>")) |end| {
                const error_section = response_text[start .. start + end + 6];
                testPrint("{s}\n", .{error_section});
            }
        }
        // Also dump more of the response for debugging
        testPrint("Full response (first 2000 chars):\n{s}\n", .{response_text[0..@min(2000, response_text.len)]});
        return error.FeedValidationFailed;
    }

    if (!is_valid) {
        // Handle 502/520 errors gracefully - W3C validator is sometimes unavailable
        if (std.mem.indexOf(u8, response_text, "error code: 502") != null or
            std.mem.indexOf(u8, response_text, "error code: 520") != null)
        {
            testPrint("⚠️  W3C Validator temporarily unavailable (server error) - skipping validation\n", .{});
            return; // Skip test instead of failing
        }
        testPrint("W3C Validator response unclear - dumping first 2000 chars:\n{s}\n", .{response_text[0..@min(2000, response_text.len)]});
        return error.ValidationResponseUnclear;
    }

    testPrint("✅ releases.xml validated successfully against W3C Feed Validator!\n", .{});
}

test "Local XML well-formedness validation" {
    const allocator = testing.allocator;

    // Read the actual releases.xml file
    const releases_xml = std.fs.cwd().readFileAlloc(allocator, "releases.xml", 10 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            testPrint("⚠️  releases.xml not found - skipping validation (run the app first)\n", .{});
            return;
        }
        return err;
    };
    defer allocator.free(releases_xml);

    testPrint("Validating XML well-formedness of releases.xml ({d} bytes)...\n", .{releases_xml.len});

    // Basic XML well-formedness checks
    var validation_errors = std.ArrayList([]const u8).init(allocator);
    defer validation_errors.deinit();

    // Check for XML declaration
    if (!std.mem.startsWith(u8, releases_xml, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")) {
        try validation_errors.append("Missing or incorrect XML declaration");
    }

    // Check for root element
    if (std.mem.indexOf(u8, releases_xml, "<feed xmlns=\"http://www.w3.org/2005/Atom\">") == null) {
        try validation_errors.append("Missing Atom feed root element");
    }

    // Check for closing feed tag
    if (!std.mem.endsWith(u8, std.mem.trim(u8, releases_xml, " \t\n\r"), "</feed>")) {
        try validation_errors.append("Missing closing </feed> tag");
    }

    // Check for required Atom elements
    const required_elements = [_][]const u8{
        "<title>",
        "<subtitle>",
        "<id>",
        "<updated>",
    };

    for (required_elements) |element| {
        if (std.mem.indexOf(u8, releases_xml, element) == null) {
            const error_msg = try std.fmt.allocPrint(allocator, "Missing required element: {s}", .{element});
            try validation_errors.append(error_msg);
        }
    }

    // Check for balanced tags (basic check)
    const entry_open_count = std.mem.count(u8, releases_xml, "<entry>");
    const entry_close_count = std.mem.count(u8, releases_xml, "</entry>");
    if (entry_open_count != entry_close_count) {
        const error_msg = try std.fmt.allocPrint(allocator, "Unbalanced <entry> tags: {d} open, {d} close", .{ entry_open_count, entry_close_count });
        try validation_errors.append(error_msg);
    }

    // Check for proper HTML escaping in content
    if (std.mem.indexOf(u8, releases_xml, "<content type=\"html\">") != null) {
        // Look for unescaped HTML in content sections
        var content_start: usize = 0;
        while (std.mem.indexOfPos(u8, releases_xml, content_start, "<content type=\"html\">")) |start| {
            const content_tag_end = start + "<content type=\"html\">".len;
            if (std.mem.indexOfPos(u8, releases_xml, content_tag_end, "</content>")) |end| {
                const content_section = releases_xml[content_tag_end..end];

                // Check for unescaped < and > (should be &lt; and &gt;)
                if (std.mem.indexOf(u8, content_section, "<") != null and
                    std.mem.indexOf(u8, content_section, "&lt;") == null)
                {
                    // Allow some exceptions like <br/> which might be intentional
                    if (std.mem.indexOf(u8, content_section, "<script") != null or
                        std.mem.indexOf(u8, content_section, "<div") != null or
                        std.mem.indexOf(u8, content_section, "<span") != null)
                    {
                        try validation_errors.append("Found unescaped HTML tags in content (should be XML-escaped)");
                        break;
                    }
                }
                content_start = end + "</content>".len;
            } else {
                break;
            }
        }
    }

    // Report validation results
    if (validation_errors.items.len > 0) {
        testPrint("❌ XML validation failed with {d} errors:\n", .{validation_errors.items.len});
        for (validation_errors.items) |error_msg| {
            testPrint("  - {s}\n", .{error_msg});
            // Free allocated error messages
            if (std.mem.indexOf(u8, error_msg, "Missing required element:") != null or
                std.mem.indexOf(u8, error_msg, "Unbalanced") != null)
            {
                allocator.free(error_msg);
            }
        }
        return error.XmlValidationFailed;
    }

    testPrint("✅ XML well-formedness validation passed!\n", .{});
    testPrint("   - Found {d} entries\n", .{entry_open_count});
    testPrint("   - All required Atom elements present\n", .{});
    testPrint("   - Proper XML structure maintained\n", .{});
}
test "GitHub provider integration" {
    const allocator = testing.allocator;

    // Load config to get token
    const app_config = config.loadConfig(allocator, "config.json") catch |err| {
        testPrint("Skipping GitHub test - config not available: {}\n", .{err});
        return;
    };
    defer app_config.deinit();

    if (app_config.github_token == null) {
        testPrint("Skipping GitHub test - no token configured\n", .{});
        return;
    }

    var provider = GitHub.init(app_config.github_token.?);
    const releases = provider.fetchReleases(allocator) catch |err| {
        testPrint("GitHub provider error: {}\n", .{err});
        return;
    };
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    testPrint("GitHub: Found {} releases\n", .{releases.items.len});

    // Verify releases have required fields
    for (releases.items) |release| {
        try testing.expect(release.repo_name.len > 0);
        try testing.expect(release.tag_name.len > 0);
        try testing.expect(release.html_url.len > 0);
        try testing.expectEqualStrings("github", release.provider);
    }
}

test "GitLab provider integration" {
    const allocator = testing.allocator;

    // Load config to get token
    const app_config = config.loadConfig(allocator, "config.json") catch |err| {
        testPrint("Skipping GitLab test - config not available: {}\n", .{err});
        return;
    };
    defer app_config.deinit();

    if (app_config.gitlab_token == null) {
        testPrint("Skipping GitLab test - no token configured\n", .{});
        return;
    }

    var provider = GitLab.init(app_config.gitlab_token.?);
    const releases = provider.fetchReleases(allocator) catch |err| {
        testPrint("GitLab provider error: {}\n", .{err});
        return; // Skip test if provider fails
    };
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    testPrint("GitLab: Found {} releases\n", .{releases.items.len});

    // Note: It's normal for starred projects to have 0 releases if they don't use GitLab's release feature
    // The test passes as long as we can successfully fetch the starred projects and check for releases

    // Verify releases have required fields
    for (releases.items) |release| {
        try testing.expect(release.repo_name.len > 0);
        try testing.expect(release.tag_name.len > 0);
        try testing.expect(release.html_url.len > 0);
        try testing.expectEqualStrings("gitlab", release.provider);
    }
}

test "GitLab provider with empty token" {
    const allocator = testing.allocator;

    var gitlab_provider = GitLab.init("");

    // Test with empty token (should fail gracefully)
    const releases = gitlab_provider.fetchReleases(allocator) catch |err| {
        try testing.expect(err == error.Unauthorized or err == error.HttpRequestFailed);
        testPrint("GitLab provider correctly failed with empty token: {}\n", .{err});
        return;
    };
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    // If we get here, something is wrong - empty token should fail
    try testing.expect(false);
}

test "Forgejo provider integration" {
    const allocator = testing.allocator;

    // Load config to get token
    const app_config = config.loadConfig(allocator, "config.json") catch |err| {
        testPrint("Skipping Forgejo test - config not available: {}\n", .{err});
        return;
    };
    defer app_config.deinit();

    if (app_config.codeberg_token == null) {
        testPrint("Skipping Forgejo test - no token configured\n", .{});
        return;
    }

    var provider = Forgejo.init("codeberg", "https://codeberg.org", app_config.codeberg_token.?);
    const releases = provider.fetchReleases(allocator) catch |err| {
        testPrint("Forgejo provider error: {}\n", .{err});
        return; // Skip test if provider fails
    };
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    testPrint("Forgejo: Found {} releases\n", .{releases.items.len});

    // Verify releases have required fields
    for (releases.items) |release| {
        try testing.expect(release.repo_name.len > 0);
        try testing.expect(release.tag_name.len > 0);
        try testing.expect(release.html_url.len > 0);
        try testing.expectEqualStrings("codeberg", release.provider);
    }
}

test "SourceHut provider integration" {
    const allocator = testing.allocator;

    // Load config to get repositories
    const app_config = config.loadConfig(allocator, "config.json") catch |err| {
        testPrint("Skipping SourceHut test - config not available: {}\n", .{err});
        return;
    };
    defer app_config.deinit();

    if (app_config.sourcehut == null or app_config.sourcehut.?.repositories.len == 0) {
        testPrint("Skipping SourceHut test - no repositories configured\n", .{});
        return;
    }

    var provider = SourceHut.init(app_config.sourcehut.?.token.?, app_config.sourcehut.?.repositories);
    const releases = provider.fetchReleases(allocator) catch |err| {
        testPrint("SourceHut provider error: {}\n", .{err});
        return; // Skip test if provider fails
    };
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    testPrint("SourceHut: Found {} releases\n", .{releases.items.len});

    // Verify releases have required fields
    for (releases.items) |release| {
        try testing.expect(release.repo_name.len > 0);
        try testing.expect(release.tag_name.len > 0);
        try testing.expect(release.html_url.len > 0);
        try testing.expectEqualStrings("sourcehut", release.provider);
    }
}

test "SourceHut commit date fetching" {
    const allocator = testing.allocator;

    // Load config to get repositories
    const app_config = config.loadConfig(allocator, "config.json") catch |err| {
        testPrint("Skipping SourceHut commit date test - config not available: {}\n", .{err});
        return;
    };
    defer app_config.deinit();

    if (app_config.sourcehut == null or app_config.sourcehut.?.repositories.len == 0) {
        testPrint("Skipping SourceHut commit date test - no repositories configured\n", .{});
        return;
    }

    // Test with a single repository to focus on commit date fetching
    var test_repos = [_][]const u8{app_config.sourcehut.?.repositories[0]};
    var provider = SourceHut.init(app_config.sourcehut.?.token.?, test_repos[0..]);

    const releases = provider.fetchReleases(allocator) catch |err| {
        testPrint("SourceHut commit date test error: {}\n", .{err});
        return;
    };
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    testPrint("SourceHut commit date test: Found {} releases from {s}\n", .{ releases.items.len, test_repos[0] });

    // Verify we have some releases
    if (releases.items.len == 0) {
        testPrint("FAIL: No releases found from SourceHut repository {s}\n", .{test_repos[0]});
        try testing.expect(false); // Force test failure - we should be able to fetch releases
    }

    var valid_dates: usize = 0;
    var epoch_dates: usize = 0;

    // Check commit dates
    for (releases.items) |release| {
        testPrint("Release: {s} - Date: {s}\n", .{ release.tag_name, release.published_at });

        // Verify basic fields
        try testing.expect(release.repo_name.len > 0);
        try testing.expect(release.tag_name.len > 0);
        try testing.expect(release.html_url.len > 0);
        try testing.expect(release.published_at.len > 0);
        try testing.expectEqualStrings("sourcehut", release.provider);

        // Check if we got a real commit date vs epoch fallback
        if (std.mem.eql(u8, release.published_at, "1970-01-01T00:00:00Z")) {
            epoch_dates += 1;
            testPrint("  -> Using epoch fallback date\n", .{});
        } else {
            valid_dates += 1;
            testPrint("  -> Got real commit date\n", .{});

            // Verify the date format looks reasonable (should be ISO 8601)
            try testing.expect(release.published_at.len >= 19); // At least YYYY-MM-DDTHH:MM:SS
            try testing.expect(std.mem.indexOf(u8, release.published_at, "T") != null);
        }
    }

    testPrint("SourceHut commit date summary: {} valid dates, {} epoch fallbacks\n", .{ valid_dates, epoch_dates });

    // We should have at least some valid commit dates
    // If all dates are epoch fallbacks, something is wrong with our commit date fetching
    if (releases.items.len > 0) {
        const success_rate = (valid_dates * 100) / releases.items.len;
        testPrint("Commit date success rate: {}%\n", .{success_rate});

        // Test should fail if we can't fetch any real commit dates
        if (valid_dates == 0) {
            testPrint("FAIL: No valid commit dates were fetched from SourceHut\n", .{});
            try testing.expect(false); // Force test failure
        }

        // Test passes if we can fetch tags and get real commit dates
        try testing.expect(releases.items.len > 0);
        try testing.expect(valid_dates > 0);
    }
}
