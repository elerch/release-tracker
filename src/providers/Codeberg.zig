const std = @import("std");
const http = std.http;
const json = std.json;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const utils = @import("../utils.zig");

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

    // Get starred repositories (Codeberg uses Gitea API)
    const starred_repos = try getStarredRepos(allocator, &client, self.token);
    defer {
        for (starred_repos.items) |repo| {
            allocator.free(repo);
        }
        starred_repos.deinit();
    }

    // Get releases for each repo
    for (starred_repos.items) |repo| {
        // TODO: Investigate the tags/releases situation similar to GitHub
        const repo_releases = getRepoReleases(allocator, &client, self.token, repo) catch |err| {
            const stderr = std.io.getStdErr().writer();
            stderr.print("Error fetching Codeberg releases for {s}: {}\n", .{ repo, err }) catch {};
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
    _ = self;
    return "codeberg";
}

fn getStarredRepos(allocator: Allocator, client: *http.Client, token: []const u8) !ArrayList([]const u8) {
    var repos = ArrayList([]const u8).init(allocator);
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

    while (true) {
        const url = try std.fmt.allocPrint(allocator, "https://codeberg.org/api/v1/user/starred?limit={d}&page={d}", .{ per_page, page });
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
                const stderr = std.io.getStdErr().writer();
                stderr.print("Codeberg API: Unauthorized - check your token and scopes\n", .{}) catch {};
                return error.Unauthorized;
            } else if (req.response.status == .forbidden) {
                const stderr = std.io.getStdErr().writer();
                stderr.print("Codeberg API: Forbidden - token may lack required scopes (read:repository)\n", .{}) catch {};
                return error.Forbidden;
            }
            const stderr = std.io.getStdErr().writer();
            stderr.print("Codeberg API request failed with status: {}\n", .{req.response.status}) catch {};
            return error.HttpRequestFailed;
        }

        const body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
        defer allocator.free(body);

        const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch |err| {
            const stderr = std.io.getStdErr().writer();
            stderr.print("Error parsing Codeberg starred repos JSON (page {d}): {}\n", .{ page, err }) catch {};
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

fn getRepoReleases(allocator: Allocator, client: *http.Client, token: []const u8, repo: []const u8) !ArrayList(Release) {
    var releases = ArrayList(Release).init(allocator);
    errdefer {
        // Clean up any allocated releases if we fail
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    const url = try std.fmt.allocPrint(allocator, "https://codeberg.org/api/v1/repos/{s}/releases", .{repo});
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

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
            const stderr = std.io.getStdErr().writer();
            stderr.print("Codeberg API: Unauthorized for repo {s} - check your token and scopes\n", .{repo}) catch {};
            return error.Unauthorized;
        } else if (req.response.status == .forbidden) {
            const stderr = std.io.getStdErr().writer();
            stderr.print("Codeberg API: Forbidden for repo {s} - token may lack required scopes\n", .{repo}) catch {};
            return error.Forbidden;
        } else if (req.response.status == .not_found) {
            const stderr = std.io.getStdErr().writer();
            stderr.print("Codeberg API: Repository {s} not found or no releases\n", .{repo}) catch {};
            return error.NotFound;
        }
        const stderr = std.io.getStdErr().writer();
        stderr.print("Codeberg API request failed for repo {s} with status: {}\n", .{ repo, req.response.status }) catch {};
        return error.HttpRequestFailed;
    }

    const body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(body);

    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch |err| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("Error parsing Codeberg releases JSON for {s}: {}\n", .{ repo, err }) catch {};
        return error.JsonParseError;
    };
    defer parsed.deinit();

    if (parsed.value != .array) {
        return error.UnexpectedJsonFormat;
    }

    const array = parsed.value.array;
    for (array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;

        // Safely extract required fields
        const tag_name_value = obj.get("tag_name") orelse continue;
        if (tag_name_value != .string) continue;

        const published_at_value = obj.get("published_at") orelse continue;
        if (published_at_value != .string) continue;

        const html_url_value = obj.get("html_url") orelse continue;
        if (html_url_value != .string) continue;

        const body_value = obj.get("body") orelse json.Value{ .string = "" };
        const body_str = if (body_value == .string) body_value.string else "";

        const release = Release{
            .repo_name = try allocator.dupe(u8, repo),
            .tag_name = try allocator.dupe(u8, tag_name_value.string),
            .published_at = try utils.parseReleaseTimestamp(published_at_value.string),
            .html_url = try allocator.dupe(u8, html_url_value.string),
            .description = try allocator.dupe(u8, body_str),
            .provider = try allocator.dupe(u8, "codeberg"),
            .is_tag = false,
        };

        releases.append(release) catch |err| {
            // If append fails, clean up the release we just created
            release.deinit(allocator);
            return err;
        };
    }

    // Sort releases by date (most recent first)
    std.mem.sort(Release, releases.items, {}, utils.compareReleasesByDate);

    return releases;
}

test "codeberg provider name" {
    const allocator = std.testing.allocator;
    _ = allocator;

    var codeberg_provider = init("dummy_token");
    try std.testing.expectEqualStrings("codeberg", codeberg_provider.getName());
}

test "codeberg release parsing with live data snapshot" {
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
            .provider = try allocator.dupe(u8, "codeberg"),
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
    try std.testing.expectEqualStrings("codeberg", releases.items[0].provider);
}
