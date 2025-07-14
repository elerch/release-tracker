const std = @import("std");
const builtin = @import("builtin");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;

const GitHub = @import("providers/GitHub.zig");
const GitLab = @import("providers/GitLab.zig");
const Codeberg = @import("providers/Codeberg.zig");
const SourceHut = @import("providers/SourceHut.zig");
const atom = @import("atom.zig");
const config = @import("config.zig");
const Config = config.Config;
const SourceHutConfig = config.SourceHutConfig;
const xml_parser = @import("xml_parser.zig");
const zeit = @import("zeit");

const Provider = @import("Provider.zig");

fn print(comptime fmt: []const u8, args: anytype) void {
    if (comptime @import("builtin").is_test) {
        const build_options = @import("build_options");
        if (build_options.test_debug) {
            std.debug.print(fmt, args);
        }
    } else {
        std.debug.print(fmt, args);
    }
}

// Error output functions that work in release mode
fn printError(comptime fmt: []const u8, args: anytype) void {
    const stderr = std.io.getStdErr().writer();
    stderr.print(fmt, args) catch {};
}

fn printInfo(comptime fmt: []const u8, args: anytype) void {
    const stderr = std.io.getStdErr().writer();
    stderr.print(fmt, args) catch {};
}

// Configuration: Only include releases from the last year in the output
const RELEASE_AGE_LIMIT_SECONDS: i64 = 365 * 24 * 60 * 60; // 1 year in seconds

pub const Release = struct {
    repo_name: []const u8,
    tag_name: []const u8,
    published_at: []const u8,
    html_url: []const u8,
    description: []const u8,
    provider: []const u8,

    pub fn deinit(self: Release, allocator: Allocator) void {
        allocator.free(self.repo_name);
        allocator.free(self.tag_name);
        allocator.free(self.published_at);
        allocator.free(self.html_url);
        allocator.free(self.description);
        allocator.free(self.provider);
    }
};

const ProviderResult = struct {
    provider_name: []const u8,
    releases: ArrayList(Release),
    error_msg: ?[]const u8 = null,
};

const ThreadContext = struct {
    provider: Provider,
    latest_release_date: i64,
    result: *ProviderResult,
    allocator: Allocator,
};

pub fn main() !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

    const gpa, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };
    const allocator = gpa;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Usage: {s} <config-file> [atom-feed-file]\n", .{args[0]});
        return 0;
    }

    const config_path = args[1];
    const output_file = if (args.len >= 3) args[2] else "releases.xml";
    var app_config = config.loadConfig(allocator, config_path) catch |err| {
        printError("Error loading config: {}\n", .{err});
        return 1;
    };
    defer app_config.deinit();

    // Load existing releases to determine last check time per provider
    var existing_releases = loadExistingReleases(allocator, output_file) catch ArrayList(Release).init(allocator);
    defer {
        for (existing_releases.items) |release| {
            release.deinit(allocator);
        }
        existing_releases.deinit();
    }

    var new_releases = ArrayList(Release).init(allocator);
    defer {
        for (new_releases.items) |release| {
            release.deinit(allocator);
        }
        new_releases.deinit();
    }

    printInfo("Fetching releases from all providers concurrently...\n", .{});

    // Create providers list
    var providers = std.ArrayList(Provider).init(allocator);
    defer providers.deinit();

    // Initialize providers with their tokens (need to persist for the lifetime of the program)
    var github_provider: ?GitHub = null;
    var gitlab_provider: ?GitLab = null;
    var codeberg_provider: ?Codeberg = null;
    var sourcehut_provider: ?SourceHut = null;

    if (app_config.github_token) |token| {
        github_provider = GitHub.init(token);
        try providers.append(github_provider.?.provider());
    }
    if (app_config.gitlab_token) |token| {
        gitlab_provider = GitLab.init(token);
        try providers.append(gitlab_provider.?.provider());
    }
    if (app_config.codeberg_token) |token| {
        codeberg_provider = Codeberg.init(token);
        try providers.append(codeberg_provider.?.provider());
    }
    if (app_config.sourcehut) |sh_config| if (sh_config.repositories.len > 0 and sh_config.token != null) {
        sourcehut_provider = SourceHut.init(sh_config.token.?, sh_config.repositories);
        try providers.append(sourcehut_provider.?.provider());
    };

    // Fetch releases from all providers concurrently using thread pool
    const provider_results = try fetchReleasesFromAllProviders(allocator, providers.items, existing_releases.items);
    defer {
        for (provider_results) |*result| {
            // Don't free the releases here - they're transferred to new_releases
            result.releases.deinit();
            // Free error messages if they exist
            if (result.error_msg) |error_msg| {
                allocator.free(error_msg);
            }
        }
        allocator.free(provider_results);
    }

    // Check for provider errors and report them
    var has_errors = false;
    for (provider_results) |result| {
        if (result.error_msg) |error_msg| {
            printError("✗ {s}: {s}\n", .{ result.provider_name, error_msg });
            has_errors = true;
        }
    }

    // If any provider failed, exit with error code
    if (has_errors) {
        printError("One or more providers failed to fetch releases\n", .{});
        return 1;
    }

    // Combine all new releases from threaded providers
    for (provider_results) |result| {
        try new_releases.appendSlice(result.releases.items);
        printInfo("Found {} new releases from {s}\n", .{ result.releases.items.len, result.provider_name });
    }

    // Combine all releases (existing and new)
    var all_releases = ArrayList(Release).init(allocator);
    defer all_releases.deinit();

    // Add new releases
    try all_releases.appendSlice(new_releases.items);

    // Add all existing releases
    try all_releases.appendSlice(existing_releases.items);

    // Sort all releases by published date (most recent first)
    std.mem.sort(Release, all_releases.items, {}, compareReleasesByDate);

    // Filter releases by age in-place - zero extra allocations
    const now = std.time.timestamp();
    const cutoff_time = now - RELEASE_AGE_LIMIT_SECONDS;

    var write_index: usize = 0;
    const original_count = all_releases.items.len;

    for (all_releases.items) |release| {
        const release_time = parseReleaseTimestamp(release.published_at) catch 0;
        if (release_time >= cutoff_time) {
            all_releases.items[write_index] = release;
            write_index += 1;
        }
    }

    // Shrink the array to only include filtered items
    all_releases.shrinkRetainingCapacity(write_index);

    // Generate Atom feed from filtered releases
    const atom_content = try atom.generateFeed(allocator, all_releases.items);
    defer allocator.free(atom_content);

    // Write to output file
    const file = try std.fs.cwd().createFile(output_file, .{});
    defer file.close();
    try file.writeAll(atom_content);

    // Log to stderr for user feedback
    printInfo("Found {} new releases\n", .{new_releases.items.len});
    printInfo("Total releases in feed: {} (filtered from {} total, showing last {} days)\n", .{ all_releases.items.len, original_count, @divTrunc(RELEASE_AGE_LIMIT_SECONDS, 24 * 60 * 60) });
    printInfo("Updated feed written to: {s}\n", .{output_file});

    return 0;
}

fn loadExistingReleases(allocator: Allocator, filename: []const u8) !ArrayList(Release) {
    const file = std.fs.cwd().openFile(filename, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            printInfo("No existing releases file found, starting fresh\n", .{});
            return ArrayList(Release).init(allocator);
        },
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    printInfo("Loading existing releases from {s}...\n", .{filename});
    const releases = try parseReleasesFromXml(allocator, content);
    printInfo("Loaded {} existing releases\n", .{releases.items.len});
    return releases;
}

fn parseReleasesFromXml(allocator: Allocator, xml_content: []const u8) !ArrayList(Release) {
    const releases = xml_parser.parseAtomFeed(allocator, xml_content) catch |err| {
        printError("Warning: Failed to parse XML content: {}\n", .{err});
        printInfo("Starting fresh with no existing releases\n", .{});
        return ArrayList(Release).init(allocator);
    };

    return releases;
}

pub fn filterNewReleases(allocator: Allocator, all_releases: []const Release, since_timestamp: i64) !ArrayList(Release) {
    var new_releases = ArrayList(Release).init(allocator);

    for (all_releases) |release| {
        // Parse the published_at timestamp
        const release_time = parseReleaseTimestamp(release.published_at) catch continue;

        if (release_time > since_timestamp) {
            // This is a new release, duplicate it for our list
            const new_release = Release{
                .repo_name = try allocator.dupe(u8, release.repo_name),
                .tag_name = try allocator.dupe(u8, release.tag_name),
                .published_at = try allocator.dupe(u8, release.published_at),
                .html_url = try allocator.dupe(u8, release.html_url),
                .description = try allocator.dupe(u8, release.description),
                .provider = try allocator.dupe(u8, release.provider),
            };
            try new_releases.append(new_release);
        }
    }

    return new_releases;
}

pub fn parseReleaseTimestamp(date_str: []const u8) !i64 {
    // Try parsing as direct timestamp first
    if (std.fmt.parseInt(i64, date_str, 10)) |timestamp| {
        return timestamp;
    } else |_| {
        // Try parsing as ISO 8601 format using Zeit
        const instant = zeit.instant(.{
            .source = .{ .iso8601 = date_str },
        }) catch return 0;
        // Zeit returns nanoseconds, convert to seconds
        const seconds = @divTrunc(instant.timestamp, 1_000_000_000);
        return @intCast(seconds);
    }
}

pub fn compareReleasesByDate(context: void, a: Release, b: Release) bool {
    _ = context;
    const timestamp_a = parseReleaseTimestamp(a.published_at) catch 0;
    const timestamp_b = parseReleaseTimestamp(b.published_at) catch 0;
    return timestamp_a > timestamp_b; // Most recent first
}

fn formatTimestampForDisplay(allocator: Allocator, timestamp: i64) ![]const u8 {
    if (timestamp == 0) {
        return try allocator.dupe(u8, "beginning of time");
    }

    // Use zeit to format the timestamp properly
    const instant = zeit.instant(.{ .source = .{ .unix_timestamp = timestamp } }) catch {
        // Fallback to simple approximation if zeit fails
        const days_since_epoch = @divTrunc(timestamp, 24 * 60 * 60);
        const years_since_1970 = @divTrunc(days_since_epoch, 365);
        const remaining_days = @mod(days_since_epoch, 365);
        const months = @divTrunc(remaining_days, 30);
        const days = @mod(remaining_days, 30);

        const year = 1970 + years_since_1970;
        const month = 1 + months;
        const day = 1 + days;

        return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T00:00:00Z", .{ year, month, day });
    };

    const time = instant.time();
    var buf: [64]u8 = undefined;
    const formatted = try time.bufPrint(&buf, .rfc3339);
    return try allocator.dupe(u8, formatted);
}

fn fetchReleasesFromAllProviders(
    allocator: Allocator,
    providers: []const Provider,
    existing_releases: []const Release,
) ![]ProviderResult {
    var results = try allocator.alloc(ProviderResult, providers.len);

    // Initialize results
    for (results, 0..) |*result, i| {
        result.* = ProviderResult{
            .provider_name = providers[i].getName(),
            .releases = ArrayList(Release).init(allocator),
            .error_msg = null,
        };
    }

    // Create thread pool context

    var threads = try allocator.alloc(Thread, providers.len);
    defer allocator.free(threads);

    var contexts = try allocator.alloc(ThreadContext, providers.len);
    defer allocator.free(contexts);

    // Calculate the latest release date for each provider from existing releases
    for (providers, 0..) |provider, i| {
        // Find the latest release date for this provider
        var latest_date: i64 = 0;
        for (existing_releases) |release| {
            if (std.mem.eql(u8, release.provider, provider.getName())) {
                const release_time = parseReleaseTimestamp(release.published_at) catch 0;
                if (release_time > latest_date) {
                    latest_date = release_time;
                }
            }
        }

        contexts[i] = ThreadContext{
            .provider = provider,
            .latest_release_date = latest_date,
            .result = &results[i],
            .allocator = allocator,
        };

        threads[i] = try Thread.spawn(.{}, fetchProviderReleases, .{&contexts[i]});
    }

    // Wait for all threads to complete
    for (providers, 0..) |_, i| {
        threads[i].join();
    }

    return results;
}

fn fetchProviderReleases(context: *const ThreadContext) void {
    const provider = context.provider;
    const latest_release_date = context.latest_release_date;
    const result = context.result;
    const allocator = context.allocator;

    const since_str = formatTimestampForDisplay(allocator, latest_release_date) catch "unknown";
    defer if (!std.mem.eql(u8, since_str, "unknown")) allocator.free(since_str);
    printInfo("Fetching releases from {s} (since: {s})...\n", .{ provider.getName(), since_str });

    if (provider.fetchReleases(allocator)) |all_releases| {
        defer {
            for (all_releases.items) |release| {
                release.deinit(allocator);
            }
            all_releases.deinit();
        }

        // Filter releases newer than latest known release
        const filtered = filterNewReleases(allocator, all_releases.items, latest_release_date) catch |err| {
            const error_msg = std.fmt.allocPrint(allocator, "Error filtering releases: {}", .{err}) catch "Unknown filter error";
            result.error_msg = error_msg;
            return;
        };

        result.releases = filtered;
        printInfo("✓ {s}: Found {} new releases\n", .{ provider.getName(), filtered.items.len });
    } else |err| {
        const error_msg = std.fmt.allocPrint(allocator, "Error fetching releases: {}", .{err}) catch "Unknown fetch error";
        result.error_msg = error_msg;
        // Don't print error here - it will be handled in main function
    }
}

test "main functionality" {
    // Basic test to ensure compilation
    const allocator = std.testing.allocator;
    var releases = ArrayList(Release).init(allocator);
    defer releases.deinit();

    try std.testing.expect(releases.items.len == 0);
}

test "Atom feed has correct structure" {
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

    const atom_content = try atom.generateFeed(allocator, &releases);
    defer allocator.free(atom_content);

    // Check for required Atom elements
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<feed xmlns=\"http://www.w3.org/2005/Atom\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<title>Repository Releases</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<subtitle>New releases from starred repositories</subtitle>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<link href=\"https://github.com\" rel=\"alternate\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<link href=\"https://example.com/releases.xml\" rel=\"self\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<id>https://example.com/releases</id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<updated>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<entry>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "</feed>") != null);

    // Check entry structure
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<title>test/repo - v1.0.0</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<link href=\"https://github.com/test/repo/releases/tag/v1.0.0\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<id>https://github.com/test/repo/releases/tag/v1.0.0</id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<updated>2024-01-01T00:00:00Z</updated>") != null);

    // Check for author - be flexible about exact format
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<author>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "github") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "</author>") != null);

    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<summary>Test release</summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<category term=\"github\"/>") != null);
}

test "loadExistingReleases with valid XML" {
    const allocator = std.testing.allocator;

    // Test XML content
    const test_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<title>Repository Releases</title>
        \\<entry>
        \\  <title>test/repo - v1.0.0</title>
        \\  <link href="https://github.com/test/repo/releases/tag/v1.0.0"/>
        \\  <updated>2024-01-01T00:00:00Z</updated>
        \\  <summary>Test release</summary>
        \\  <category term="github"/>
        \\</entry>
        \\</feed>
    ;

    // Parse releases directly from XML content
    var releases = try parseReleasesFromXml(allocator, test_xml);
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), releases.items.len);
    try std.testing.expectEqualStrings("test/repo", releases.items[0].repo_name);
    try std.testing.expectEqualStrings("v1.0.0", releases.items[0].tag_name);
}

test "loadExistingReleases with nonexistent file" {
    const allocator = std.testing.allocator;

    var releases = try loadExistingReleases(allocator, "nonexistent_file.xml");
    defer releases.deinit();

    try std.testing.expectEqual(@as(usize, 0), releases.items.len);
}

test "loadExistingReleases with malformed XML" {
    const allocator = std.testing.allocator;

    const malformed_xml = "This is not valid XML at all!";

    // Should handle gracefully and return empty list
    var releases = try parseReleasesFromXml(allocator, malformed_xml);
    defer releases.deinit();

    try std.testing.expectEqual(@as(usize, 0), releases.items.len);
}

test "parseReleaseTimestamp with various formats" {
    // Test ISO 8601 format
    const timestamp1 = try parseReleaseTimestamp("2024-01-01T00:00:00Z");
    try std.testing.expect(timestamp1 > 0);

    // Test direct timestamp
    const timestamp2 = try parseReleaseTimestamp("1704067200");
    try std.testing.expectEqual(@as(i64, 1704067200), timestamp2);

    // Test invalid format (should return 0)
    const timestamp3 = parseReleaseTimestamp("invalid") catch 0;
    try std.testing.expectEqual(@as(i64, 0), timestamp3);

    // Test empty string
    const timestamp4 = parseReleaseTimestamp("") catch 0;
    try std.testing.expectEqual(@as(i64, 0), timestamp4);

    // Test different ISO formats
    const timestamp5 = try parseReleaseTimestamp("2024-12-25T15:30:45Z");
    try std.testing.expect(timestamp5 > timestamp1);
}

test "filterNewReleases correctly filters by timestamp" {
    const allocator = std.testing.allocator;

    const old_release = Release{
        .repo_name = "test/old",
        .tag_name = "v1.0.0",
        .published_at = "2024-01-01T00:00:00Z",
        .html_url = "https://github.com/test/old/releases/tag/v1.0.0",
        .description = "Old release",
        .provider = "github",
    };

    const new_release = Release{
        .repo_name = "test/new",
        .tag_name = "v2.0.0",
        .published_at = "2024-06-01T00:00:00Z",
        .html_url = "https://github.com/test/new/releases/tag/v2.0.0",
        .description = "New release",
        .provider = "github",
    };

    const all_releases = [_]Release{ old_release, new_release };

    // Filter with timestamp between the two releases
    const march_timestamp = try parseReleaseTimestamp("2024-03-01T00:00:00Z");
    var filtered = try filterNewReleases(allocator, &all_releases, march_timestamp);
    defer {
        for (filtered.items) |release| {
            release.deinit(allocator);
        }
        filtered.deinit();
    }

    // Should only contain the new release
    try std.testing.expectEqual(@as(usize, 1), filtered.items.len);
    try std.testing.expectEqualStrings("test/new", filtered.items[0].repo_name);
}

test "loadExistingReleases handles various XML structures" {
    const allocator = std.testing.allocator;

    // Test with minimal valid XML
    const minimal_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<title>Repository Releases</title>
        \\<entry>
        \\  <title>minimal/repo - v1.0.0</title>
        \\  <link href="https://github.com/minimal/repo/releases/tag/v1.0.0"/>
        \\  <updated>2024-01-01T00:00:00Z</updated>
        \\</entry>
        \\</feed>
    ;

    // Parse releases directly from XML content
    var releases = try parseReleasesFromXml(allocator, minimal_xml);
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), releases.items.len);
    try std.testing.expectEqualStrings("minimal/repo", releases.items[0].repo_name);
    try std.testing.expectEqualStrings("v1.0.0", releases.items[0].tag_name);
    try std.testing.expectEqualStrings("2024-01-01T00:00:00Z", releases.items[0].published_at);
}

test "loadExistingReleases with complex XML content" {
    const allocator = std.testing.allocator;

    // Test with complex XML including escaped characters and multiple entries
    const complex_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<title>Repository Releases</title>
        \\<subtitle>New releases from starred repositories</subtitle>
        \\<link href="https://github.com" rel="alternate"/>
        \\<link href="https://example.com/releases.xml" rel="self"/>
        \\<id>https://example.com/releases</id>
        \\<updated>2024-01-01T00:00:00Z</updated>
        \\<entry>
        \\  <title>complex/repo &amp; more - v1.0.0 &lt;beta&gt;</title>
        \\  <link href="https://github.com/complex/repo/releases/tag/v1.0.0"/>
        \\  <id>https://github.com/complex/repo/releases/tag/v1.0.0</id>
        \\  <updated>2024-01-01T00:00:00Z</updated>
        \\  <author><n>github</n></author>
        \\  <summary>Release with &quot;special&quot; characters &amp; symbols</summary>
        \\  <category term="github"/>
        \\</entry>
        \\<entry>
        \\  <title>another/repo - v2.0.0</title>
        \\  <link href="https://gitlab.com/another/repo/-/releases/v2.0.0"/>
        \\  <id>https://gitlab.com/another/repo/-/releases/v2.0.0</id>
        \\  <updated>2024-01-02T12:30:45Z</updated>
        \\  <author><n>gitlab</n></author>
        \\  <summary>Another release</summary>
        \\  <category term="gitlab"/>
        \\</entry>
        \\</feed>
    ;

    // Parse releases directly from XML content
    var releases = try parseReleasesFromXml(allocator, complex_xml);
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    try std.testing.expectEqual(@as(usize, 2), releases.items.len);

    // Check first release with escaped characters
    try std.testing.expectEqualStrings("complex/repo & more", releases.items[0].repo_name);
    try std.testing.expectEqualStrings("v1.0.0 <beta>", releases.items[0].tag_name);
    try std.testing.expectEqualStrings("Release with \"special\" characters & symbols", releases.items[0].description);
    try std.testing.expectEqualStrings("github", releases.items[0].provider);

    // Check second release
    try std.testing.expectEqualStrings("another/repo", releases.items[1].repo_name);
    try std.testing.expectEqualStrings("v2.0.0", releases.items[1].tag_name);
    try std.testing.expectEqualStrings("gitlab", releases.items[1].provider);
}

test "formatTimestampForDisplay produces valid ISO dates" {
    const allocator = std.testing.allocator;

    // Test with zero timestamp
    const zero_result = try formatTimestampForDisplay(allocator, 0);
    defer allocator.free(zero_result);
    try std.testing.expectEqualStrings("beginning of time", zero_result);

    // Test with known timestamp (2024-01-01T00:00:00Z = 1704067200)
    const known_result = try formatTimestampForDisplay(allocator, 1704067200);
    defer allocator.free(known_result);
    try std.testing.expect(std.mem.startsWith(u8, known_result, "20"));
    try std.testing.expect(std.mem.endsWith(u8, known_result, "Z"));
    try std.testing.expect(std.mem.indexOf(u8, known_result, "T") != null);
}

test "XML parsing handles malformed entries gracefully" {
    const allocator = std.testing.allocator;

    // Test with partially malformed XML (missing closing tags, etc.)
    const malformed_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<title>Repository Releases</title>
        \\<entry>
        \\  <title>good/repo - v1.0.0</title>
        \\  <link href="https://github.com/good/repo/releases/tag/v1.0.0"/>
        \\  <updated>2024-01-01T00:00:00Z</updated>
        \\</entry>
        \\<entry>
        \\  <title>broken/repo - v2.0.0
        \\  <link href="https://github.com/broken/repo/releases/tag/v2.0.0"/>
        \\  <updated>2024-01-02T00:00:00Z</updated>
        \\</entry>
        \\<entry>
        \\  <title>another/good - v3.0.0</title>
        \\  <link href="https://github.com/another/good/releases/tag/v3.0.0"/>
        \\  <updated>2024-01-03T00:00:00Z</updated>
        \\</entry>
        \\</feed>
    ;

    var releases = try xml_parser.parseAtomFeed(allocator, malformed_xml);
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    // Should parse the good entries and skip/handle the malformed one gracefully
    try std.testing.expect(releases.items.len >= 2);

    // Check that we got the good entries
    var found_good = false;
    var found_another_good = false;
    for (releases.items) |release| {
        if (std.mem.eql(u8, release.repo_name, "good/repo")) {
            found_good = true;
        }
        if (std.mem.eql(u8, release.repo_name, "another/good")) {
            found_another_good = true;
        }
    }
    try std.testing.expect(found_good);
    try std.testing.expect(found_another_good);
}

test "compareReleasesByDate" {
    const release1 = Release{
        .repo_name = "test/repo1",
        .tag_name = "v1.0.0",
        .published_at = "2024-01-01T00:00:00Z",
        .html_url = "https://github.com/test/repo1/releases/tag/v1.0.0",
        .description = "First release",
        .provider = "github",
    };

    const release2 = Release{
        .repo_name = "test/repo2",
        .tag_name = "v2.0.0",
        .published_at = "2024-01-02T00:00:00Z",
        .html_url = "https://github.com/test/repo2/releases/tag/v2.0.0",
        .description = "Second release",
        .provider = "github",
    };

    // release2 should come before release1 (more recent first)
    try std.testing.expect(compareReleasesByDate({}, release2, release1));
    try std.testing.expect(!compareReleasesByDate({}, release1, release2));
}

// Import XML parser tests
test {
    std.testing.refAllDecls(@import("xml_parser_tests.zig"));
}

test "Age-based release filtering" {
    const allocator = std.testing.allocator;

    const now = std.time.timestamp();
    const one_year_ago = now - RELEASE_AGE_LIMIT_SECONDS;
    const two_years_ago = now - (2 * RELEASE_AGE_LIMIT_SECONDS);

    // Create releases with different ages
    const recent_release = Release{
        .repo_name = "test/recent",
        .tag_name = "v1.0.0",
        .published_at = try std.fmt.allocPrint(allocator, "{}", .{now - 86400}), // 1 day ago
        .html_url = "https://github.com/test/recent/releases/tag/v1.0.0",
        .description = "Recent release",
        .provider = "github",
    };
    defer allocator.free(recent_release.published_at);

    const old_release = Release{
        .repo_name = "test/old",
        .tag_name = "v0.1.0",
        .published_at = try std.fmt.allocPrint(allocator, "{}", .{two_years_ago}),
        .html_url = "https://github.com/test/old/releases/tag/v0.1.0",
        .description = "Old release",
        .provider = "github",
    };
    defer allocator.free(old_release.published_at);

    const borderline_release = Release{
        .repo_name = "test/borderline",
        .tag_name = "v0.5.0",
        .published_at = try std.fmt.allocPrint(allocator, "{}", .{one_year_ago + 3600}), // 1 hour within limit
        .html_url = "https://github.com/test/borderline/releases/tag/v0.5.0",
        .description = "Borderline release",
        .provider = "github",
    };
    defer allocator.free(borderline_release.published_at);

    const releases = [_]Release{ recent_release, old_release, borderline_release };

    // Test filtering logic
    var filtered = ArrayList(Release).init(allocator);
    defer filtered.deinit();

    const cutoff_time = now - RELEASE_AGE_LIMIT_SECONDS;

    for (releases) |release| {
        const release_time = parseReleaseTimestamp(release.published_at) catch 0;
        if (release_time >= cutoff_time) {
            try filtered.append(release);
        }
    }

    // Should include recent and borderline, but not old
    try std.testing.expectEqual(@as(usize, 2), filtered.items.len);

    // Verify the correct releases were included
    var found_recent = false;
    var found_borderline = false;
    var found_old = false;

    for (filtered.items) |release| {
        if (std.mem.eql(u8, release.repo_name, "test/recent")) {
            found_recent = true;
        } else if (std.mem.eql(u8, release.repo_name, "test/borderline")) {
            found_borderline = true;
        } else if (std.mem.eql(u8, release.repo_name, "test/old")) {
            found_old = true;
        }
    }

    try std.testing.expect(found_recent);
    try std.testing.expect(found_borderline);
    try std.testing.expect(!found_old);
}

test "RELEASE_AGE_LIMIT_SECONDS constant verification" {
    // Verify the constant is set to 1 year in seconds
    const expected_year_in_seconds = 365 * 24 * 60 * 60;
    try std.testing.expectEqual(expected_year_in_seconds, RELEASE_AGE_LIMIT_SECONDS);

    // Verify it's approximately 31.5 million seconds (1 year)
    try std.testing.expect(RELEASE_AGE_LIMIT_SECONDS > 31_000_000);
    try std.testing.expect(RELEASE_AGE_LIMIT_SECONDS < 32_000_000);
}

// Import timestamp tests
test {
    std.testing.refAllDecls(@import("timestamp_tests.zig"));
}
