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
const zeit = @import("zeit");
const utils = @import("utils.zig");

const Provider = @import("Provider.zig");

// Configuration: Only include releases from the last n days
const RELEASE_AGE_LIMIT_SECONDS: i64 = 90 * std.time.s_per_day;

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
/// Check if file size exceeds 10MB threshold and warn user if so.
/// Returns true if warning was triggered, false otherwise.
/// Only prints to stderr in production (not during tests).
fn checkFileSizeAndWarn(file_size: usize) bool {
    const ten_mb = 10 * 1024 * 1024; // 10MB in bytes
    if (file_size > ten_mb) {
        // Only print warning if not in test mode
        if (!builtin.is_test) {
            const size_mb = @as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0);
            printError("⚠️  WARNING: Feed file is {d:.1} MB, which exceeds 10MB\n", .{size_mb});
            printError("   Large feeds may cause issues with some feed readers\n", .{});
            printError("   Consider reducing the RELEASE_AGE_LIMIT_SECONDS to show fewer releases\n", .{});
        }
        return true; // File size exceeded threshold
    }
    return false; // File size is within acceptable limits
}

fn printError(comptime fmt: []const u8, args: anytype) void {
    const stderr = std.io.getStdErr().writer();
    stderr.print(fmt, args) catch {};
}

fn printInfo(comptime fmt: []const u8, args: anytype) void {
    const stderr = std.io.getStdErr().writer();
    if (!builtin.is_test)
        stderr.print(fmt, args) catch {};
}

pub const Release = struct {
    repo_name: []const u8,
    tag_name: []const u8,
    published_at: i64,
    html_url: []const u8,
    description: []const u8,
    provider: []const u8,
    is_tag: bool = false,

    pub fn deinit(self: Release, allocator: Allocator) void {
        allocator.free(self.repo_name);
        allocator.free(self.tag_name);
        allocator.free(self.html_url);
        allocator.free(self.description);
        allocator.free(self.provider);
    }
};

const ProviderResult = struct {
    provider_name: []const u8,
    releases: ArrayList(Release),
    error_msg: ?[]const u8 = null,
    duration_ms: u64 = 0,
};

const ThreadContext = struct {
    provider: Provider,
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
    var tsa = std.heap.ThreadSafeAllocator{ .child_allocator = gpa };
    const allocator = tsa.allocator();

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

    var all_releases = ArrayList(Release).init(allocator);
    defer all_releases.deinit();

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
    const provider_results = try fetchReleasesFromAllProviders(allocator, providers.items);
    defer {
        for (provider_results) |*result| {
            // Free error messages if they exist
            if (result.error_msg) |error_msg|
                allocator.free(error_msg);
            for (result.releases.items) |release|
                release.deinit(allocator);
            result.releases.deinit();
        }
        allocator.free(provider_results);
    }

    const now = std.time.timestamp();
    const cutoff_time = now - RELEASE_AGE_LIMIT_SECONDS;

    var has_errors = false;
    for (provider_results) |result| {
        if (result.error_msg) |error_msg| {
            printError("✗ {s}: {s} (in {d}ms)\n", .{ result.provider_name, error_msg, result.duration_ms });
            has_errors = true;
        }
    }

    // If any provider failed, exit with error code
    if (has_errors) {
        printError("One or more providers failed to fetch releases\n", .{});
        return 1;
    }

    var original_count: usize = 0;
    // Combine all releases from threaded providers
    for (provider_results) |result| {
        original_count += result.releases.items.len;
        // Results should be sorted already...we will find the oldest applicable release,
        // then copy into all_releases

        var last_index: usize = 0;
        for (result.releases.items) |release| {
            if (release.published_at >= cutoff_time) {
                last_index += 1;
            } else break;
        }
        try all_releases.appendSlice(result.releases.items[0..last_index]);
    }

    // Sort all releases by published date (most recent first)
    std.mem.sort(Release, all_releases.items, {}, utils.compareReleasesByDate);

    // Generate Atom feed from filtered releases
    const atom_content = try atom.generateFeed(allocator, all_releases.items);
    defer allocator.free(atom_content);

    // Write to output file
    const file = try std.fs.cwd().createFile(output_file, .{});
    defer file.close();
    try file.writeAll(atom_content);

    // Check file size and warn if over 10MB
    _ = checkFileSizeAndWarn(atom_content.len);

    // Log to stderr for user feedback
    printInfo("Total releases in feed: {} of {} total in last {} days\n", .{ all_releases.items.len, original_count, @divTrunc(RELEASE_AGE_LIMIT_SECONDS, std.time.s_per_day) });
    printInfo("Updated feed written to: {s}\n", .{output_file});

    return 0;
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
        contexts[i] = ThreadContext{
            .provider = provider,
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
    const result = context.result;
    const allocator = context.allocator;

    printInfo("Fetching releases from {s}...\n", .{provider.getName()});

    // Start timing
    const start_time = std.time.milliTimestamp();

    const releases_or_err = provider.fetchReleases(allocator);
    const end_time = std.time.milliTimestamp();
    const duration_ms: u64 = @intCast(end_time - start_time);
    result.duration_ms = duration_ms;

    if (releases_or_err) |all_releases| {
        result.releases = all_releases;
        printInfo("✓ {s}: Found {} releases in {d}ms\n", .{ provider.getName(), result.releases.items.len, duration_ms });
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

test "file size warning for large feeds" {
    // Test that files under 10MB don't trigger warning
    const result1 = checkFileSizeAndWarn(5 * 1024 * 1024); // 5MB - should not warn
    try std.testing.expect(result1 == false);

    // Test that files over 10MB do trigger warning
    const result2 = checkFileSizeAndWarn(15 * 1024 * 1024); // 15MB - should warn
    try std.testing.expect(result2 == true);

    // Test edge case - exactly 10MB should not warn
    const result3 = checkFileSizeAndWarn(10 * 1024 * 1024); // 10MB exactly - should not warn
    try std.testing.expect(result3 == false);

    // Test just over 10MB should warn
    const result4 = checkFileSizeAndWarn(10 * 1024 * 1024 + 1); // 10MB + 1 byte - should warn
    try std.testing.expect(result4 == true);

    // Test various sizes around the threshold
    try std.testing.expect(!checkFileSizeAndWarn(9 * 1024 * 1024)); // 9MB
    try std.testing.expect(checkFileSizeAndWarn(11 * 1024 * 1024)); // 11MB
    try std.testing.expect(!checkFileSizeAndWarn(1 * 1024 * 1024)); // 1MB
    try std.testing.expect(checkFileSizeAndWarn(50 * 1024 * 1024)); // 50MB
}

test "atom feed generation" {
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
            .description = "Test release",
            .provider = "github",
            .is_tag = false,
        },
    };

    const atom_content = try atom.generateFeed(allocator, &releases);
    defer allocator.free(atom_content);

    // Check for required Atom elements
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<feed xmlns=\"http://www.w3.org/2005/Atom\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<title>Repository Releases</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<subtitle>New releases from starred repositories</subtitle>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<link href=\"https://releases.lerch.org\" rel=\"alternate\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<link href=\"https://releases.lerch.org/atom.xml\" rel=\"self\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<id>https://releases.lerch.org</id>") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<content type=\"html\">&lt;p&gt;Test release&lt;/p&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<category term=\"github\"/>") != null);
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

test "Age-based release filtering" {
    const allocator = std.testing.allocator;

    const now = std.time.timestamp();
    const one_year_ago = now - RELEASE_AGE_LIMIT_SECONDS;
    const two_years_ago = now - (2 * RELEASE_AGE_LIMIT_SECONDS);

    // Create releases with different ages
    const recent_release = Release{
        .repo_name = "test/recent",
        .tag_name = "v1.0.0",
        .published_at = now - std.time.s_per_day, // 1 day ago
        .html_url = "https://github.com/test/recent/releases/tag/v1.0.0",
        .description = "Recent release",
        .provider = "github",
        .is_tag = false,
    };

    const old_release = Release{
        .repo_name = "test/old",
        .tag_name = "v0.1.0",
        .published_at = two_years_ago,
        .html_url = "https://github.com/test/old/releases/tag/v0.1.0",
        .description = "Old release",
        .provider = "github",
        .is_tag = false,
    };

    const borderline_release = Release{
        .repo_name = "test/borderline",
        .tag_name = "v0.5.0",
        .published_at = one_year_ago + std.time.s_per_hour, // 1 hour within limit
        .html_url = "https://github.com/test/borderline/releases/tag/v0.5.0",
        .description = "Borderline release",
        .provider = "github",
        .is_tag = false,
    };

    const releases = [_]Release{ recent_release, old_release, borderline_release };

    // Test filtering logic
    var filtered = ArrayList(Release).init(allocator);
    defer filtered.deinit();

    const cutoff_time = now - RELEASE_AGE_LIMIT_SECONDS;

    for (releases) |release| {
        const release_time = release.published_at;
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

// Import others
test {
    std.testing.refAllDecls(@import("timestamp_tests.zig"));
    std.testing.refAllDecls(@import("atom.zig"));
    std.testing.refAllDecls(@import("utils.zig"));
    std.testing.refAllDecls(@import("providers/GitHub.zig"));
    std.testing.refAllDecls(@import("providers/GitLab.zig"));
    std.testing.refAllDecls(@import("providers/SourceHut.zig"));
    std.testing.refAllDecls(@import("providers/Codeberg.zig"));
}
