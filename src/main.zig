const std = @import("std");
const builtin = @import("builtin");
const print = std.debug.print;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;

const github = @import("providers/github.zig");
const gitlab = @import("providers/gitlab.zig");
const codeberg = @import("providers/codeberg.zig");
const sourcehut = @import("providers/sourcehut.zig");
const atom = @import("atom.zig");
const config = @import("config.zig");
const zeit = @import("zeit");

const Provider = @import("Provider.zig");

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

pub fn main() !void {
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
        print("Usage: {s} <config-file>\n", .{args[0]});
        return;
    }

    const config_path = args[1];
    var app_config = config.loadConfig(allocator, config_path) catch |err| {
        print("Error loading config: {}\n", .{err});
        return;
    };
    defer app_config.deinit();

    // Load existing Atom feed to get current releases
    var existing_releases = loadExistingReleases(allocator) catch ArrayList(Release).init(allocator);
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

    print("Fetching releases from all providers concurrently...\n", .{});

    // Create providers list
    var providers = std.ArrayList(Provider).init(allocator);
    defer providers.deinit();

    // Initialize providers with their tokens (need to persist for the lifetime of the program)
    var github_provider: ?github.GitHubProvider = null;
    var gitlab_provider: ?gitlab.GitLabProvider = null;
    var codeberg_provider: ?codeberg.CodebergProvider = null;
    var sourcehut_provider: ?sourcehut.SourceHutProvider = null;

    if (app_config.github_token) |token| {
        github_provider = github.GitHubProvider.init(token);
        try providers.append(Provider.init(&github_provider.?));
    }

    if (app_config.gitlab_token) |token| {
        gitlab_provider = gitlab.GitLabProvider.init(token);
        try providers.append(Provider.init(&gitlab_provider.?));
    }

    if (app_config.codeberg_token) |token| {
        codeberg_provider = codeberg.CodebergProvider.init(token);
        try providers.append(Provider.init(&codeberg_provider.?));
    }

    // Configure SourceHut provider with repositories if available
    if (app_config.sourcehut) |sh_config| {
        if (sh_config.repositories.len > 0 and sh_config.token != null) {
            sourcehut_provider = sourcehut.SourceHutProvider.init(sh_config.token.?, sh_config.repositories);
            try providers.append(Provider.init(&sourcehut_provider.?));
        }
    }

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

    // Combine all new releases from threaded providers
    for (provider_results) |result| {
        try new_releases.appendSlice(result.releases.items);
        print("Found {} new releases from {s}\n", .{ result.releases.items.len, result.provider_name });
    }

    // Combine existing and new releases
    var all_releases = ArrayList(Release).init(allocator);
    defer all_releases.deinit();

    // Add new releases first (they'll appear at the top of the Atom feed)
    try all_releases.appendSlice(new_releases.items);

    // Add existing releases (up to a reasonable limit to prevent Atom feed from growing indefinitely)
    const max_total_releases = 100;
    const remaining_slots = if (new_releases.items.len < max_total_releases)
        max_total_releases - new_releases.items.len
    else
        0;

    const existing_to_add = @min(existing_releases.items.len, remaining_slots);
    try all_releases.appendSlice(existing_releases.items[0..existing_to_add]);

    // Sort all releases by published date (most recent first)
    std.mem.sort(Release, all_releases.items, {}, compareReleasesByDate);

    // Generate Atom feed
    const atom_content = try atom.generateFeed(allocator, all_releases.items);
    defer allocator.free(atom_content);

    // Write Atom feed to file
    const atom_file = std.fs.cwd().createFile("releases.xml", .{}) catch |err| {
        print("Error creating Atom feed file: {}\n", .{err});
        return;
    };
    defer atom_file.close();

    // Log to stderr for user feedback
    std.debug.print("Found {} new releases\n", .{new_releases.items.len});
    std.debug.print("Total releases in feed: {}\n", .{all_releases.items.len});
    std.debug.print("Updated feed written to: {s}\n", .{output_file});

    print("Atom feed generated: releases.xml\n", .{});
    print("Found {} new releases\n", .{new_releases.items.len});
    print("Total releases in feed: {}\n", .{all_releases.items.len});
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
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<author><name>github</name></author>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<summary>Test release</summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, atom_content, "<category term=\"github\"/>") != null);
}
fn loadExistingReleases(allocator: Allocator) !ArrayList(Release) {
    var releases = ArrayList(Release).init(allocator);

    const file = std.fs.cwd().openFile("releases.xml", .{}) catch |err| switch (err) {
        error.FileNotFound => return releases, // No existing file, return empty list
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    // Simple XML parsing to extract existing releases from Atom feed
    // Look for <entry> blocks and extract the data
    var lines = std.mem.splitScalar(u8, content, '\n');
    var current_release: ?Release = null;
    var in_entry = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");

        if (std.mem.startsWith(u8, trimmed, "<entry>")) {
            in_entry = true;
            current_release = Release{
                .repo_name = try allocator.dupe(u8, ""),
                .tag_name = try allocator.dupe(u8, ""),
                .published_at = try allocator.dupe(u8, ""),
                .html_url = try allocator.dupe(u8, ""),
                .description = try allocator.dupe(u8, ""),
                .provider = try allocator.dupe(u8, ""),
            };
        } else if (std.mem.startsWith(u8, trimmed, "</entry>")) {
            if (current_release) |release| {
                try releases.append(release);
            }
            in_entry = false;
            current_release = null;
        } else if (in_entry and current_release != null) {
            if (std.mem.startsWith(u8, trimmed, "<title>") and std.mem.endsWith(u8, trimmed, "</title>")) {
                const title_content = trimmed[7 .. trimmed.len - 8];
                if (std.mem.indexOf(u8, title_content, " - ")) |dash_pos| {
                    allocator.free(current_release.?.repo_name);
                    allocator.free(current_release.?.tag_name);
                    current_release.?.repo_name = try allocator.dupe(u8, title_content[0..dash_pos]);
                    current_release.?.tag_name = try allocator.dupe(u8, title_content[dash_pos + 3 ..]);
                }
            } else if (std.mem.startsWith(u8, trimmed, "<link href=\"") and std.mem.endsWith(u8, trimmed, "\"/>")) {
                const url_start = 12; // length of "<link href=\""
                const url_end = trimmed.len - 3; // remove "\"/>"
                allocator.free(current_release.?.html_url);
                current_release.?.html_url = try allocator.dupe(u8, trimmed[url_start..url_end]);
            } else if (std.mem.startsWith(u8, trimmed, "<updated>") and std.mem.endsWith(u8, trimmed, "</updated>")) {
                allocator.free(current_release.?.published_at);
                current_release.?.published_at = try allocator.dupe(u8, trimmed[9 .. trimmed.len - 10]);
            } else if (std.mem.startsWith(u8, trimmed, "<category term=\"") and std.mem.endsWith(u8, trimmed, "\"/>")) {
                const term_start = 15; // length of "<category term=\""
                const term_end = trimmed.len - 3; // remove "\"/>"
                allocator.free(current_release.?.provider);
                current_release.?.provider = try allocator.dupe(u8, trimmed[term_start..term_end]);
            } else if (std.mem.startsWith(u8, trimmed, "<summary>") and std.mem.endsWith(u8, trimmed, "</summary>")) {
                allocator.free(current_release.?.description);
                current_release.?.description = try allocator.dupe(u8, trimmed[9 .. trimmed.len - 10]);
            }
        }
    }

    // Clean up any incomplete release that wasn't properly closed
    if (current_release) |release| {
        release.deinit(allocator);
    }

    return releases;
}

fn filterNewReleases(allocator: Allocator, all_releases: []const Release, since_timestamp: i64) !ArrayList(Release) {
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

fn parseReleaseTimestamp(date_str: []const u8) !i64 {
    // Try parsing as direct timestamp first
    if (std.fmt.parseInt(i64, date_str, 10)) |timestamp| {
        return timestamp;
    } else |_| {
        // Try parsing as ISO 8601 format using Zeit
        const instant = zeit.instant(.{
            .source = .{ .iso8601 = date_str },
        }) catch return 0;
        return @intCast(instant.timestamp);
    }
}

fn compareReleasesByDate(context: void, a: Release, b: Release) bool {
    _ = context;
    const timestamp_a = parseReleaseTimestamp(a.published_at) catch 0;
    const timestamp_b = parseReleaseTimestamp(b.published_at) catch 0;
    return timestamp_a > timestamp_b; // Most recent first
}

fn formatTimestampForDisplay(allocator: Allocator, timestamp: i64) ![]const u8 {
    if (timestamp == 0) {
        return try allocator.dupe(u8, "beginning of time");
    }

    // Convert timestamp to approximate ISO date for display
    const days_since_epoch = @divTrunc(timestamp, 24 * 60 * 60);
    const years_since_1970 = @divTrunc(days_since_epoch, 365);
    const remaining_days = @mod(days_since_epoch, 365);
    const months = @divTrunc(remaining_days, 30);
    const days = @mod(remaining_days, 30);

    const year = 1970 + years_since_1970;
    const month = 1 + months;
    const day = 1 + days;

    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T00:00:00Z", .{ year, month, day });
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
    print("Fetching releases from {s} (since: {s})...\n", .{ provider.getName(), since_str });

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
        print("✓ {s}: Found {} new releases\n", .{ provider.getName(), filtered.items.len });
    } else |err| {
        const error_msg = std.fmt.allocPrint(allocator, "Error fetching releases: {}", .{err}) catch "Unknown fetch error";
        result.error_msg = error_msg;
        print("✗ {s}: {s}\n", .{ provider.getName(), error_msg });
    }
}
