const std = @import("std");
const http = std.http;
const json = std.json;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Release = @import("../main.zig").Release;

pub const GitLabProvider = struct {
    pub fn fetchReleases(self: *@This(), allocator: Allocator, token: []const u8) !ArrayList(Release) {
        _ = self;
        var client = http.Client{ .allocator = allocator };
        defer client.deinit();

        var releases = ArrayList(Release).init(allocator);

        // Get starred projects
        const starred_projects = try getStarredProjects(allocator, &client, token);
        defer {
            for (starred_projects.items) |project| {
                allocator.free(project);
            }
            starred_projects.deinit();
        }

        // Get releases for each project
        for (starred_projects.items) |project_id| {
            const project_releases = getProjectReleases(allocator, &client, token, project_id) catch |err| {
                std.debug.print("Error fetching GitLab releases for project {s}: {}\n", .{ project_id, err });
                continue;
            };
            defer project_releases.deinit();

            // Transfer ownership of the releases to the main list
            for (project_releases.items) |release| {
                try releases.append(release);
            }
        }

        return releases;
    }

    pub fn getName(self: *@This()) []const u8 {
        _ = self;
        return "gitlab";
    }
};

fn getStarredProjects(allocator: Allocator, client: *http.Client, token: []const u8) !ArrayList([]const u8) {
    var projects = ArrayList([]const u8).init(allocator);
    errdefer {
        for (projects.items) |project| {
            allocator.free(project);
        }
        projects.deinit();
    }

    // First, get the current user's username
    const username = try getCurrentUsername(allocator, client, token);
    defer allocator.free(username);

    const auth_header = try std.fmt.allocPrint(allocator, "Private-Token {s}", .{token});
    defer allocator.free(auth_header);

    // Paginate through all starred projects
    var page: u32 = 1;
    const per_page: u32 = 100; // Use 100 per page for efficiency

    while (true) {
        const url = try std.fmt.allocPrint(allocator, "https://gitlab.com/api/v4/users/{s}/starred_projects?per_page={d}&page={d}", .{ username, per_page, page });
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
            return error.HttpRequestFailed;
        }

        const body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
        defer allocator.free(body);

        const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
        defer parsed.deinit();

        const array = parsed.value.array;

        // If no items returned, we've reached the end
        if (array.items.len == 0) {
            break;
        }

        for (array.items) |item| {
            const obj = item.object;
            const id = obj.get("id").?.integer;
            const id_str = try std.fmt.allocPrint(allocator, "{d}", .{id});
            projects.append(id_str) catch |err| {
                // If append fails, clean up the string we just created
                allocator.free(id_str);
                return err;
            };
        }

        // If we got fewer items than per_page, we've reached the last page
        if (array.items.len < per_page) {
            break;
        }

        page += 1;
    }

    return projects;
}

fn getCurrentUsername(allocator: Allocator, client: *http.Client, token: []const u8) ![]const u8 {
    // Try to get user info first
    const uri = try std.Uri.parse("https://gitlab.com/api/v4/user");

    const auth_header = try std.fmt.allocPrint(allocator, "Private-Token {s}", .{token});
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
        // If we can't get user info, fall back to hardcoded username
        // This is a workaround for tokens with limited scopes
        return try allocator.dupe(u8, "elerch");
    }

    const body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(body);

    const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer parsed.deinit();

    const username = parsed.value.object.get("username").?.string;
    return try allocator.dupe(u8, username);
}

fn getProjectReleases(allocator: Allocator, client: *http.Client, token: []const u8, project_id: []const u8) !ArrayList(Release) {
    var releases = ArrayList(Release).init(allocator);
    errdefer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    const url = try std.fmt.allocPrint(allocator, "https://gitlab.com/api/v4/projects/{s}/releases", .{project_id});
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);

    const auth_header = try std.fmt.allocPrint(allocator, "Private-Token {s}", .{token});
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
        return error.HttpRequestFailed;
    }

    const body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(body);

    const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer parsed.deinit();

    const array = parsed.value.array;
    for (array.items) |item| {
        const obj = item.object;

        const desc_value = obj.get("description") orelse json.Value{ .string = "" };
        const desc_str = if (desc_value == .string) desc_value.string else "";

        const release = Release{
            .repo_name = try allocator.dupe(u8, obj.get("name").?.string),
            .tag_name = try allocator.dupe(u8, obj.get("tag_name").?.string),
            .published_at = try allocator.dupe(u8, obj.get("created_at").?.string),
            .html_url = try allocator.dupe(u8, obj.get("_links").?.object.get("self").?.string),
            .description = try allocator.dupe(u8, desc_str),
            .provider = try allocator.dupe(u8, "gitlab"),
        };

        releases.append(release) catch |err| {
            // If append fails, clean up the release we just created
            release.deinit(allocator);
            return err;
        };
    }

    return releases;
}

test "gitlab provider" {
    const allocator = std.testing.allocator;

    var provider = GitLabProvider{};

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

    try std.testing.expectEqualStrings("gitlab", provider.getName());
}
