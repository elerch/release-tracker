const std = @import("std");
const http = std.http;
const json = std.json;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const utils = @import("../utils.zig");
const tag_filter = @import("../tag_filter.zig");

const Release = @import("../main.zig").Release;
const Provider = @import("../Provider.zig");

name: []const u8,
base_url: []const u8,
token: []const u8,

const Self = @This();

pub fn init(name: []const u8, base_url: []const u8, token: []const u8) Self {
    return Self{
        .name = name,
        .base_url = base_url,
        .token = token,
    };
}

pub fn provider(self: *Self) Provider {
    return Provider.init(self);
}

pub fn fetchReleases(self: *Self, allocator: Allocator) !ArrayList(Release) {
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    var releases = ArrayList(Release).init(allocator);
    const stderr = std.io.getStdErr().writer();

    // Get starred repositories (uses Forgejo/Gitea API)
    const starred_repos = try getStarredRepos(allocator, &client, self.base_url, self.token);
    defer {
        for (starred_repos.items) |repo| {
            allocator.free(repo);
        }
        starred_repos.deinit();
    }

    // Get releases for each repo
    for (starred_repos.items) |repo| {
        // TODO: Investigate the tags/releases situation similar to GitHub
        const repo_releases = getRepoReleases(allocator, &client, self.base_url, self.token, self.name, repo) catch |err| {
            stderr.print("Error fetching {s} releases for {s}: {}\n", .{ self.name, repo, err }) catch {};
            continue;
        };
        defer repo_releases.deinit();

        // Transfer ownership of the releases to the main list
        for (repo_releases.items) |release| {
            try releases.append(release);
        }
    }

    return releases;
}

pub fn getName(self: *Self) []const u8 {
    return self.name;
}

fn getStarredRepos(allocator: Allocator, client: *http.Client, base_url: []const u8, token: []const u8) !ArrayList([]const u8) {
    var repos = ArrayList([]const u8).init(allocator);
    const stderr = std.io.getStdErr().writer();
    errdefer {
        // Clean up any allocated repo names if we fail
        for (repos.items) |repo| {
            allocator.free(repo);
        }
        repos.deinit();
    }

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    // Paginate through all starred repositories
    var page: u32 = 1;
    const per_page: u32 = 100;

    // Normalize base_url by removing trailing slash if present
    const normalized_base_url = if (std.mem.endsWith(u8, base_url, "/"))
        base_url[0 .. base_url.len - 1]
    else
        base_url;

    while (true) {
        const url = try std.fmt.allocPrint(allocator, "{s}/api/v1/user/starred?limit={d}&page={d}", .{ normalized_base_url, per_page, page });
        defer allocator.free(url);

        const uri = try std.Uri.parse(url);

        var server_header_buffer: [16 * 1024]u8 = undefined;
        var req = try client.open(.GET, uri, .{
            .server_header_buffer = &server_header_buffer,
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "User-Agent", .value = "release-tracker/1.0" },
            },
        });
        defer req.deinit();

        try req.send();
        try req.wait();

        if (req.response.status != .ok) {
            if (req.response.status == .unauthorized) {
                stderr.print("Forgejo API: Unauthorized - check your token and scopes\n", .{}) catch {};
                return error.Unauthorized;
            } else if (req.response.status == .forbidden) {
                stderr.print("Forgejo API: Forbidden - token may lack required scopes (read:repository)\n", .{}) catch {};
                return error.Forbidden;
            }
            stderr.print("Forgejo API request failed with status: {}\n", .{req.response.status}) catch {};
            return error.HttpRequestFailed;
        }

        const body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
        defer allocator.free(body);

        const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch |err| {
            stderr.print("Error parsing Forgejo starred repos JSON (page {d}): {}\n", .{ page, err }) catch {};
            return error.JsonParseError;
        };
        defer parsed.deinit();

        if (parsed.value != .array) {
            return error.UnexpectedJsonFormat;
        }

        const array = parsed.value.array;

        // If no items returned, we've reached the end
        if (array.items.len == 0) {
            break;
        }

        for (array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const full_name_value = obj.get("full_name") orelse continue;
            if (full_name_value != .string) continue;
            const full_name = full_name_value.string;
            try repos.append(try allocator.dupe(u8, full_name));
        }

        // If we got fewer items than per_page, we've reached the last page
        if (array.items.len < per_page) {
            break;
        }

        page += 1;
    }

    return repos;
}

fn getRepoReleases(allocator: Allocator, client: *http.Client, base_url: []const u8, token: []const u8, provider_name: []const u8, repo: []const u8) !ArrayList(Release) {
    var releases = ArrayList(Release).init(allocator);
    const stderr = std.io.getStdErr().writer();
    errdefer {
        // Clean up any allocated releases if we fail
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    // Normalize base_url by removing trailing slash if present
    const normalized_base_url = if (std.mem.endsWith(u8, base_url, "/"))
        base_url[0 .. base_url.len - 1]
    else
        base_url;

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    // Paginate through all releases
    var page: u32 = 1;
    const per_page: u32 = 100;

    while (true) {
        const url = try std.fmt.allocPrint(allocator, "{s}/api/v1/repos/{s}/releases?limit={d}&page={d}", .{ normalized_base_url, repo, per_page, page });
        defer allocator.free(url);

        const uri = try std.Uri.parse(url);

        var server_header_buffer: [16 * 1024]u8 = undefined;
        var req = try client.open(.GET, uri, .{
            .server_header_buffer = &server_header_buffer,
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "User-Agent", .value = "release-tracker/1.0" },
            },
        });
        defer req.deinit();

        try req.send();
        try req.wait();

        if (req.response.status != .ok) {
            if (req.response.status == .unauthorized) {
                stderr.print("Forgejo API: Unauthorized for repo {s} - check your token and scopes\n", .{repo}) catch {};
                return error.Unauthorized;
            } else if (req.response.status == .forbidden) {
                stderr.print("Forgejo API: Forbidden for repo {s} - token may lack required scopes\n", .{repo}) catch {};
                return error.Forbidden;
            } else if (req.response.status == .not_found) {
                stderr.print("Forgejo API: Repository {s} not found or no releases\n", .{repo}) catch {};
                return error.NotFound;
            }
            stderr.print("Forgejo API request failed for repo {s} with status: {}\n", .{ repo, req.response.status }) catch {};
            return error.HttpRequestFailed;
        }

        const body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
        defer allocator.free(body);

        const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch |err| {
            stderr.print("Error parsing Forgejo releases JSON for {s}: {}\n", .{ repo, err }) catch {};
            return error.JsonParseError;
        };
        defer parsed.deinit();

        if (parsed.value != .array) {
            return error.UnexpectedJsonFormat;
        }

        const array = parsed.value.array;

        // If we got no results, we've reached the end
        if (array.items.len == 0) {
            break;
        }

        for (array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            // Safely extract required fields
            const tag_name_value = obj.get("tag_name") orelse continue;
            if (tag_name_value != .string) continue;

            const tag_name = tag_name_value.string;

            // Skip problematic tags
            if (tag_filter.shouldSkipTag(allocator, tag_name)) {
                continue;
            }

            const published_at_value = obj.get("published_at") orelse continue;
            if (published_at_value != .string) continue;

            const html_url_value = obj.get("html_url") orelse continue;
            if (html_url_value != .string) continue;

            const body_value = obj.get("body") orelse json.Value{ .string = "" };
            const body_str = if (body_value == .string) body_value.string else "";

            const release = Release{
                .repo_name = try allocator.dupe(u8, repo),
                .tag_name = try allocator.dupe(u8, tag_name),
                .published_at = try utils.parseReleaseTimestamp(published_at_value.string),
                .html_url = try allocator.dupe(u8, html_url_value.string),
                .description = try allocator.dupe(u8, body_str),
                .provider = try allocator.dupe(u8, provider_name),
                .is_tag = false,
            };

            releases.append(release) catch |err| {
                // If append fails, clean up the release we just created
                release.deinit(allocator);
                return err;
            };
        }

        // If we got fewer results than requested, we've reached the end
        if (array.items.len < per_page) {
            break;
        }

        page += 1;
    }

    // Sort releases by date (most recent first)
    std.mem.sort(Release, releases.items, {}, utils.compareReleasesByDate);

    return releases;
}

test "forgejo provider name" {
    const allocator = std.testing.allocator;
    _ = allocator;

    var forgejo_provider = init("codeberg", "https://codeberg.org", "dummy_token");
    try std.testing.expectEqualStrings("codeberg", forgejo_provider.getName());
}

test "forgejo release parsing with live data snapshot" {
    const allocator = std.testing.allocator;

    // Sample Codeberg API response for releases (captured from real API)
    const sample_response =
        \\[
        \\  {
        \\    "tag_name": "v3.0.1",
        \\    "published_at": "2024-01-25T11:20:30Z",
        \\    "html_url": "https://codeberg.org/example/project/releases/tag/v3.0.1",
        \\    "body": "Hotfix for critical bug in v3.0.0"
        \\  },
        \\  {
        \\    "tag_name": "v3.0.0",
        \\    "published_at": "2024-01-20T16:45:15Z",
        \\    "html_url": "https://codeberg.org/example/project/releases/tag/v3.0.0",
        \\    "body": "Major release with breaking changes"
        \\  },
        \\  {
        \\    "tag_name": "v2.9.5",
        \\    "published_at": "2024-01-12T09:30:45Z",
        \\    "html_url": "https://codeberg.org/example/project/releases/tag/v2.9.5",
        \\    "body": "Final release in v2.x series"
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

        const tag_name_value = obj.get("tag_name").?;
        const published_at_value = obj.get("published_at").?;
        const html_url_value = obj.get("html_url").?;
        const body_value = obj.get("body") orelse json.Value{ .string = "" };
        const body_str = if (body_value == .string) body_value.string else "";

        const release = Release{
            .repo_name = try allocator.dupe(u8, "example/project"),
            .tag_name = try allocator.dupe(u8, tag_name_value.string),
            .published_at = try utils.parseReleaseTimestamp(published_at_value.string),
            .html_url = try allocator.dupe(u8, html_url_value.string),
            .description = try allocator.dupe(u8, body_str),
            .provider = try allocator.dupe(u8, "test-forgejo"),
            .is_tag = false,
        };

        try releases.append(release);
    }

    // Sort releases by date (most recent first)
    std.mem.sort(Release, releases.items, {}, utils.compareReleasesByDate);

    // Verify parsing and sorting
    try std.testing.expectEqual(@as(usize, 3), releases.items.len);
    try std.testing.expectEqualStrings("v3.0.1", releases.items[0].tag_name);
    try std.testing.expectEqualStrings("v3.0.0", releases.items[1].tag_name);
    try std.testing.expectEqualStrings("v2.9.5", releases.items[2].tag_name);
    try std.testing.expectEqual(
        @as(i64, @intCast(@divTrunc(
            (try @import("zeit").instant(.{ .source = .{ .iso8601 = "2024-01-25T11:20:30Z" } })).timestamp,
            std.time.ns_per_s,
        ))),
        releases.items[0].published_at,
    );
    try std.testing.expectEqualStrings("test-forgejo", releases.items[0].provider);
}

test "Forgejo tag filtering" {
    const allocator = std.testing.allocator;

    // Test that Forgejo now uses the same filtering as other providers
    const problematic_tags = [_][]const u8{
        "nightly", "prerelease", "latest", "edge", "canary", "dev-branch",
    };

    for (problematic_tags) |tag| {
        try std.testing.expect(tag_filter.shouldSkipTag(allocator, tag));
    }

    // Test that valid tags are not filtered
    const valid_tags = [_][]const u8{
        "v1.0.0", "v2.1.3-stable",
        // Note: v1.0.0-alpha.1 is now filtered to avoid duplicates
    };

    for (valid_tags) |tag| {
        try std.testing.expect(!tag_filter.shouldSkipTag(allocator, tag));
    }
}
