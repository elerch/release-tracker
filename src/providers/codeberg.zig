const std = @import("std");
const http = std.http;
const json = std.json;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Release = @import("../main.zig").Release;

pub const CodebergProvider = struct {
    pub fn fetchReleases(self: *@This(), allocator: Allocator, token: []const u8) !ArrayList(Release) {
        _ = self;
        var client = http.Client{ .allocator = allocator };
        defer client.deinit();

        var releases = ArrayList(Release).init(allocator);

        // Get starred repositories (Codeberg uses Gitea API)
        const starred_repos = try getStarredRepos(allocator, &client, token);
        defer {
            for (starred_repos.items) |repo| {
                allocator.free(repo);
            }
            starred_repos.deinit();
        }

        // Get releases for each repo
        for (starred_repos.items) |repo| {
            const repo_releases = getRepoReleases(allocator, &client, token, repo) catch |err| {
                std.debug.print("Error fetching Codeberg releases for {s}: {}\n", .{ repo, err });
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

    pub fn getName(self: *@This()) []const u8 {
        _ = self;
        return "codeberg";
    }
};

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
                std.debug.print("Codeberg API: Unauthorized - check your token and scopes\n", .{});
                return error.Unauthorized;
            } else if (req.response.status == .forbidden) {
                std.debug.print("Codeberg API: Forbidden - token may lack required scopes (read:repository)\n", .{});
                return error.Forbidden;
            }
            std.debug.print("Codeberg API request failed with status: {}\n", .{req.response.status});
            return error.HttpRequestFailed;
        }

        const body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
        defer allocator.free(body);

        const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch |err| {
            std.debug.print("Error parsing Codeberg starred repos JSON (page {d}): {}\n", .{ page, err });
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
            std.debug.print("Codeberg API: Unauthorized for repo {s} - check your token and scopes\n", .{repo});
            return error.Unauthorized;
        } else if (req.response.status == .forbidden) {
            std.debug.print("Codeberg API: Forbidden for repo {s} - token may lack required scopes\n", .{repo});
            return error.Forbidden;
        } else if (req.response.status == .not_found) {
            std.debug.print("Codeberg API: Repository {s} not found or no releases\n", .{repo});
            return error.NotFound;
        }
        std.debug.print("Codeberg API request failed for repo {s} with status: {}\n", .{ repo, req.response.status });
        return error.HttpRequestFailed;
    }

    const body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(body);

    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch |err| {
        std.debug.print("Error parsing Codeberg releases JSON for {s}: {}\n", .{ repo, err });
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
            .published_at = try allocator.dupe(u8, published_at_value.string),
            .html_url = try allocator.dupe(u8, html_url_value.string),
            .description = try allocator.dupe(u8, body_str),
            .provider = try allocator.dupe(u8, "codeberg"),
        };

        releases.append(release) catch |err| {
            // If append fails, clean up the release we just created
            release.deinit(allocator);
            return err;
        };
    }

    return releases;
}

test "codeberg provider" {
    const allocator = std.testing.allocator;

    var provider = CodebergProvider{};

    // Test with empty token (should fail gracefully)
    const releases = provider.fetchReleases(allocator, "") catch |err| {
        try std.testing.expect(err == error.Unauthorized or err == error.HttpRequestFailed);
        return;
    };
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    try std.testing.expectEqualStrings("codeberg", provider.getName());
}
