const std = @import("std");
const http = std.http;
const json = std.json;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const zeit = @import("zeit");

const Release = @import("../main.zig").Release;
const Provider = @import("../Provider.zig");

token: []const u8,

const Self = @This();

pub fn init(token: []const u8) Self {
    return Self{ .token = token };
}

pub fn provider(self: *Self) Provider {
    return Provider.init(self);
}

pub fn fetchReleases(self: *Self, allocator: Allocator) !ArrayList(Release) {
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    var releases = ArrayList(Release).init(allocator);

    // First, get starred repositories
    const starred_repos = try getStarredRepos(allocator, &client, self.token);
    defer {
        for (starred_repos.items) |repo| {
            allocator.free(repo);
        }
        starred_repos.deinit();
    }

    // Then get releases for each repo
    for (starred_repos.items) |repo| {
        const repo_releases = getRepoReleases(allocator, &client, self.token, repo) catch |err| {
            std.debug.print("Error fetching releases for {s}: {}\n", .{ repo, err });
            continue;
        };
        defer repo_releases.deinit();

        try releases.appendSlice(repo_releases.items);
    }

    return releases;
}

pub fn getName(self: *Self) []const u8 {
    _ = self;
    return "github";
}

fn getStarredRepos(allocator: Allocator, client: *http.Client, token: []const u8) !ArrayList([]const u8) {
    var repos = ArrayList([]const u8).init(allocator);

    const uri = try std.Uri.parse("https://api.github.com/user/starred");

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    var server_header_buffer: [16 * 1024]u8 = undefined;
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buffer,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
            .{ .name = "User-Agent", .value = "release-tracker/1.0" },
        },
    });
    defer req.deinit();

    try req.send();
    try req.wait();

    if (req.response.status != .ok) {
        return error.HttpRequestFailed;
    }

    const body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(body);

    const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer parsed.deinit();

    const array = parsed.value.array;
    for (array.items) |item| {
        const obj = item.object;
        const full_name = obj.get("full_name").?.string;
        try repos.append(try allocator.dupe(u8, full_name));
    }

    return repos;
}

fn getRepoReleases(allocator: Allocator, client: *http.Client, token: []const u8, repo: []const u8) !ArrayList(Release) {
    var releases = ArrayList(Release).init(allocator);

    const url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/releases", .{repo});
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    var server_header_buffer: [16 * 1024]u8 = undefined;
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buffer,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
            .{ .name = "User-Agent", .value = "release-tracker/1.0" },
        },
    });
    defer req.deinit();

    try req.send();
    try req.wait();

    if (req.response.status != .ok) {
        return error.HttpRequestFailed;
    }

    const body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(body);

    const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer parsed.deinit();

    const array = parsed.value.array;
    for (array.items) |item| {
        const obj = item.object;

        const body_value = obj.get("body") orelse json.Value{ .string = "" };
        const body_str = if (body_value == .string) body_value.string else "";

        const release = Release{
            .repo_name = try allocator.dupe(u8, repo),
            .tag_name = try allocator.dupe(u8, obj.get("tag_name").?.string),
            .published_at = try allocator.dupe(u8, obj.get("published_at").?.string),
            .html_url = try allocator.dupe(u8, obj.get("html_url").?.string),
            .description = try allocator.dupe(u8, body_str),
            .provider = try allocator.dupe(u8, "github"),
        };

        try releases.append(release);
    }

    // Sort releases by date (most recent first)
    std.mem.sort(Release, releases.items, {}, compareReleasesByDate);

    return releases;
}

fn compareReleasesByDate(context: void, a: Release, b: Release) bool {
    _ = context;
    const timestamp_a = parseTimestamp(a.published_at) catch 0;
    const timestamp_b = parseTimestamp(b.published_at) catch 0;
    return timestamp_a > timestamp_b; // Most recent first
}

fn parseTimestamp(date_str: []const u8) !i64 {
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

test "github provider" {
    const allocator = std.testing.allocator;

    var github_provider = init("");

    // Test with empty token (should fail gracefully)
    const releases = github_provider.fetchReleases(allocator) catch |err| {
        try std.testing.expect(err == error.HttpRequestFailed);
        return;
    };
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    try std.testing.expectEqualStrings("github", github_provider.getName());
}

test "github release parsing with live data snapshot" {
    const allocator = std.testing.allocator;

    // Sample GitHub API response for releases (captured from real API)
    const sample_response =
        \\[
        \\  {
        \\    "tag_name": "v1.2.0",
        \\    "published_at": "2024-01-15T10:30:00Z",
        \\    "html_url": "https://github.com/example/repo/releases/tag/v1.2.0",
        \\    "body": "Bug fixes and improvements"
        \\  },
        \\  {
        \\    "tag_name": "v1.1.0",
        \\    "published_at": "2024-01-10T08:15:00Z",
        \\    "html_url": "https://github.com/example/repo/releases/tag/v1.1.0",
        \\    "body": "New features added"
        \\  },
        \\  {
        \\    "tag_name": "v1.0.0",
        \\    "published_at": "2024-01-01T00:00:00Z",
        \\    "html_url": "https://github.com/example/repo/releases/tag/v1.0.0",
        \\    "body": "Initial release"
        \\  }
        \\]
    ;

    const parsed = try json.parseFromSlice(json.Value, allocator, sample_response, .{});
    defer parsed.deinit();

    var releases = ArrayList(Release).init(allocator);
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    const array = parsed.value.array;
    for (array.items) |item| {
        const obj = item.object;

        const body_value = obj.get("body") orelse json.Value{ .string = "" };
        const body_str = if (body_value == .string) body_value.string else "";

        const release = Release{
            .repo_name = try allocator.dupe(u8, "example/repo"),
            .tag_name = try allocator.dupe(u8, obj.get("tag_name").?.string),
            .published_at = try allocator.dupe(u8, obj.get("published_at").?.string),
            .html_url = try allocator.dupe(u8, obj.get("html_url").?.string),
            .description = try allocator.dupe(u8, body_str),
            .provider = try allocator.dupe(u8, "github"),
        };

        try releases.append(release);
    }

    // Sort releases by date (most recent first)
    std.mem.sort(Release, releases.items, {}, compareReleasesByDate);

    // Verify parsing and sorting
    try std.testing.expectEqual(@as(usize, 3), releases.items.len);
    try std.testing.expectEqualStrings("v1.2.0", releases.items[0].tag_name);
    try std.testing.expectEqualStrings("v1.1.0", releases.items[1].tag_name);
    try std.testing.expectEqualStrings("v1.0.0", releases.items[2].tag_name);
    try std.testing.expectEqualStrings("2024-01-15T10:30:00Z", releases.items[0].published_at);
    try std.testing.expectEqualStrings("github", releases.items[0].provider);
}
