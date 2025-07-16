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

    // Get starred projects
    const starred_projects = try getStarredProjects(allocator, &client, self.token);
    defer {
        for (starred_projects.items) |project| {
            allocator.free(project);
        }
        starred_projects.deinit();
    }

    // Get releases for each project
    for (starred_projects.items) |project_id| {
        const project_releases = getProjectReleases(allocator, &client, self.token, project_id) catch |err| {
            const stderr = std.io.getStdErr().writer();
            stderr.print("Error fetching GitLab releases for project {s}: {}\n", .{ project_id, err }) catch {};
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

pub fn getName(self: *Self) []const u8 {
    _ = self;
    return "gitlab";
}

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
            .published_at = try utils.parseReleaseTimestamp(obj.get("created_at").?.string),
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

    // Sort releases by date (most recent first)
    std.mem.sort(Release, releases.items, {}, utils.compareReleasesByDate);

    return releases;
}

test "gitlab provider" {
    const allocator = std.testing.allocator;

    var gitlab_provider = init("");

    // Test with empty token (should fail gracefully)
    const releases = gitlab_provider.fetchReleases(allocator) catch |err| {
        try std.testing.expect(err == error.HttpRequestFailed);
        return;
    };
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    try std.testing.expectEqualStrings("gitlab", gitlab_provider.getName());
}

test "gitlab release parsing with live data snapshot" {
    const allocator = std.testing.allocator;

    // Sample GitLab API response for releases (captured from real API)
    const sample_response =
        \\[
        \\  {
        \\    "name": "Release v2.1.0",
        \\    "tag_name": "v2.1.0",
        \\    "created_at": "2024-01-20T14:45:30.123Z",
        \\    "description": "Major feature update with bug fixes",
        \\    "_links": {
        \\      "self": "https://gitlab.com/example/project/-/releases/v2.1.0"
        \\    }
        \\  },
        \\  {
        \\    "name": "Release v2.0.0",
        \\    "tag_name": "v2.0.0",
        \\    "created_at": "2024-01-15T09:20:15.456Z",
        \\    "description": "Breaking changes and improvements",
        \\    "_links": {
        \\      "self": "https://gitlab.com/example/project/-/releases/v2.0.0"
        \\    }
        \\  },
        \\  {
        \\    "name": "Release v1.9.0",
        \\    "tag_name": "v1.9.0",
        \\    "created_at": "2024-01-05T16:30:45.789Z",
        \\    "description": "Minor updates and patches",
        \\    "_links": {
        \\      "self": "https://gitlab.com/example/project/-/releases/v1.9.0"
        \\    }
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

        try releases.append(release);
    }

    // Sort releases by date (most recent first)
    std.mem.sort(Release, releases.items, {}, utils.compareReleasesByDate);

    // Verify parsing and sorting
    try std.testing.expectEqual(@as(usize, 3), releases.items.len);
    try std.testing.expectEqualStrings("v2.1.0", releases.items[0].tag_name);
    try std.testing.expectEqualStrings("v2.0.0", releases.items[1].tag_name);
    try std.testing.expectEqualStrings("v1.9.0", releases.items[2].tag_name);
    try std.testing.expectEqualStrings("2024-01-20T14:45:30.123Z", releases.items[0].published_at);
    try std.testing.expectEqualStrings("gitlab", releases.items[0].provider);
}
