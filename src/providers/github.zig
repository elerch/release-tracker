const std = @import("std");
const http = std.http;
const json = std.json;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Release = @import("../main.zig").Release;

pub const GitHubProvider = struct {
    pub fn fetchReleases(self: *@This(), allocator: Allocator, token: []const u8) !ArrayList(Release) {
        _ = self;
        var client = http.Client{ .allocator = allocator };
        defer client.deinit();

        var releases = ArrayList(Release).init(allocator);

        // First, get starred repositories
        const starred_repos = try getStarredRepos(allocator, &client, token);
        defer {
            for (starred_repos.items) |repo| {
                allocator.free(repo);
            }
            starred_repos.deinit();
        }

        // Then get releases for each repo
        for (starred_repos.items) |repo| {
            const repo_releases = getRepoReleases(allocator, &client, token, repo) catch |err| {
                std.debug.print("Error fetching releases for {s}: {}\n", .{ repo, err });
                continue;
            };
            defer repo_releases.deinit();

            try releases.appendSlice(repo_releases.items);
        }

        return releases;
    }

    pub fn getName(self: *@This()) []const u8 {
        _ = self;
        return "github";
    }
};

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

    return releases;
}

test "github provider" {
    const allocator = std.testing.allocator;

    var provider = GitHubProvider{};

    // Test with empty token (should fail gracefully)
    const releases = provider.fetchReleases(allocator, "") catch |err| {
        try std.testing.expect(err == error.HttpRequestFailed);
        return;
    };
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    try std.testing.expectEqualStrings("github", provider.getName());
}
