const std = @import("std");
const http = std.http;
const json = std.json;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const zeit = @import("zeit");

const Release = @import("../main.zig").Release;
const Provider = @import("../Provider.zig");

repositories: [][]const u8,
token: []const u8,

const Self = @This();

pub fn init(token: []const u8, repositories: [][]const u8) Self {
    return Self{ .token = token, .repositories = repositories };
}

pub fn provider(self: *Self) Provider {
    return Provider.init(self);
}

pub fn fetchReleases(self: *Self, allocator: Allocator) !ArrayList(Release) {
    return self.fetchReleasesForRepos(allocator, self.repositories, self.token);
}

pub fn fetchReleasesForRepos(self: *Self, allocator: Allocator, repositories: [][]const u8, token: ?[]const u8) !ArrayList(Release) {
    _ = self;
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    var releases = ArrayList(Release).init(allocator);
    errdefer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    for (repositories) |repo| {
        const repo_tags = getRepoTags(allocator, &client, token, repo) catch |err| {
            std.debug.print("Error fetching SourceHut tags for {s}: {}\n", .{ repo, err });
            continue;
        };
        defer {
            for (repo_tags.items) |release| {
                release.deinit(allocator);
            }
            repo_tags.deinit();
        }

        for (repo_tags.items) |release| {
            const duplicated_release = Release{
                .repo_name = try allocator.dupe(u8, release.repo_name),
                .tag_name = try allocator.dupe(u8, release.tag_name),
                .published_at = try allocator.dupe(u8, release.published_at),
                .html_url = try allocator.dupe(u8, release.html_url),
                .description = try allocator.dupe(u8, release.description),
                .provider = try allocator.dupe(u8, release.provider),
            };
            releases.append(duplicated_release) catch |err| {
                duplicated_release.deinit(allocator);
                return err;
            };
        }
    }

    return releases;
}

pub fn fetchReleasesForReposFiltered(self: *Self, allocator: Allocator, repositories: [][]const u8, token: ?[]const u8, existing_releases: []const Release) !ArrayList(Release) {
    var latest_date: i64 = 0;
    for (existing_releases) |release| {
        if (std.mem.eql(u8, release.provider, "sourcehut")) {
            const release_time = parseReleaseTimestamp(release.published_at) catch 0;
            if (release_time > latest_date) {
                latest_date = release_time;
            }
        }
    }

    const all_releases = try self.fetchReleasesForRepos(allocator, repositories, token);
    defer {
        for (all_releases.items) |release| {
            release.deinit(allocator);
        }
        all_releases.deinit();
    }

    return filterNewReleases(allocator, all_releases.items, latest_date);
}

pub fn getName(self: *Self) []const u8 {
    _ = self;
    return "sourcehut";
}

fn getRepoTags(allocator: Allocator, client: *http.Client, token: ?[]const u8, repo: []const u8) !ArrayList(Release) {
    var releases = ArrayList(Release).init(allocator);
    errdefer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    // Parse repo format: "~username/reponame" or "username/reponame"
    const repo_clean = if (std.mem.startsWith(u8, repo, "~")) repo[1..] else repo;
    var parts = std.mem.splitScalar(u8, repo_clean, '/');
    const username = parts.next() orelse return error.InvalidRepoFormat;
    const reponame = parts.next() orelse return error.InvalidRepoFormat;

    const auth_token = token orelse {
        std.debug.print("SourceHut: No token provided for {s}, skipping\n", .{repo});
        return releases;
    };

    if (auth_token.len == 0) {
        std.debug.print("SourceHut: Empty token for {s}, skipping\n", .{repo});
        return releases;
    }

    // Use SourceHut's GraphQL API
    const graphql_url = "https://git.sr.ht/query";
    const uri = try std.Uri.parse(graphql_url);

    // Use the exact same GraphQL query that worked in curl, with proper brace escaping
    const request_body = try std.fmt.allocPrint(allocator, "{{\"query\":\"query {{ user(username: \\\"{s}\\\") {{ repository(name: \\\"{s}\\\") {{ references {{ results {{ name target }} }} }} }} }}\"}}", .{ username, reponame });
    defer allocator.free(request_body);

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{auth_token});
    defer allocator.free(auth_header);

    const headers: []const http.Header = &.{
        .{ .name = "User-Agent", .value = "release-tracker/1.0" },
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Content-Type", .value = "application/json" },
    };

    var server_header_buffer: [16 * 1024]u8 = undefined;
    var req = try client.open(.POST, uri, .{
        .server_header_buffer = &server_header_buffer,
        .extra_headers = headers,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = request_body.len };
    try req.send();
    try req.writeAll(request_body);
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        std.debug.print("SourceHut GraphQL API request failed with status: {} for {s}\n", .{ req.response.status, repo });
        return error.HttpRequestFailed;
    }

    const body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(body);

    // First, get basic tag info
    const basic_releases = try parseBasicTagInfo(allocator, body, username, reponame);
    defer {
        for (basic_releases.items) |item| {
            allocator.free(item.tag_name);
            allocator.free(item.commit_id);
        }
        basic_releases.deinit();
    }

    // If we have tags, fetch their commit dates individually
    if (basic_releases.items.len > 0) {
        return fetchCommitDatesIndividually(allocator, client, auth_token, username, reponame, basic_releases.items);
    } else {
        return ArrayList(Release).init(allocator);
    }
}

const TagInfo = struct {
    tag_name: []const u8,
    commit_id: []const u8,
};

fn parseBasicTagInfo(allocator: Allocator, response_body: []const u8, username: []const u8, reponame: []const u8) !ArrayList(TagInfo) {
    _ = username;
    _ = reponame;
    var tag_infos = ArrayList(TagInfo).init(allocator);
    errdefer {
        for (tag_infos.items) |item| {
            allocator.free(item.tag_name);
            allocator.free(item.commit_id);
        }
        tag_infos.deinit();
    }

    var parsed = json.parseFromSlice(json.Value, allocator, response_body, .{}) catch |err| {
        std.debug.print("SourceHut: Failed to parse JSON response: {}\n", .{err});
        return tag_infos;
    };
    defer parsed.deinit();

    const root = parsed.value;

    // Check for GraphQL errors first
    if (root.object.get("errors")) |errors| {
        std.debug.print("GraphQL errors in tag parsing: ", .{});
        for (errors.array.items) |error_item| {
            if (error_item.object.get("message")) |message| {
                std.debug.print("{s} ", .{message.string});
            }
        }
        std.debug.print("\n", .{});
        return tag_infos;
    }

    const data = root.object.get("data") orelse return tag_infos;
    const user = data.object.get("user") orelse return tag_infos;
    if (user == .null) return tag_infos;
    const repository = user.object.get("repository") orelse return tag_infos;
    if (repository == .null) return tag_infos;
    const references = repository.object.get("references") orelse return tag_infos;
    const results = references.object.get("results") orelse return tag_infos;

    for (results.array.items) |ref_item| {
        const ref_name = ref_item.object.get("name") orelse continue;
        const target = ref_item.object.get("target") orelse continue;

        if (target == .null) continue;

        // Skip heads/branches - only process tags
        if (std.mem.startsWith(u8, ref_name.string, "refs/heads/")) {
            continue;
        }

        // Only process tags
        if (!std.mem.startsWith(u8, ref_name.string, "refs/tags/")) {
            continue;
        }

        // Extract tag name from refs/tags/tagname
        const tag_name = ref_name.string[10..]; // Skip "refs/tags/"

        var commit_id: []const u8 = "";
        if (target == .string) {
            commit_id = target.string;
        }

        // Skip if the target is not a commit ID (e.g., refs/heads/master)
        if (commit_id.len > 0 and !std.mem.startsWith(u8, commit_id, "refs/")) {
            const tag_info = TagInfo{
                .tag_name = try allocator.dupe(u8, tag_name),
                .commit_id = try allocator.dupe(u8, commit_id),
            };
            tag_infos.append(tag_info) catch |err| {
                allocator.free(tag_info.tag_name);
                allocator.free(tag_info.commit_id);
                return err;
            };
        }
    }

    return tag_infos;
}

fn fetchCommitDatesIndividually(allocator: Allocator, client: *http.Client, token: []const u8, username: []const u8, reponame: []const u8, tag_infos: []const TagInfo) !ArrayList(Release) {
    var releases = ArrayList(Release).init(allocator);
    errdefer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    for (tag_infos) |tag_info| {
        const commit_date = getCommitDate(allocator, client, token, username, reponame, tag_info.commit_id) catch |err| blk: {
            std.debug.print("Failed to get commit date for {s}: {s}\n", .{ tag_info.commit_id, @errorName(err) });
            break :blk "";
        };
        defer if (commit_date.len > 0) allocator.free(commit_date);

        const published_at = if (commit_date.len > 0)
            try allocator.dupe(u8, commit_date)
        else
            try allocator.dupe(u8, "1970-01-01T00:00:00Z");

        const release = Release{
            .repo_name = try std.fmt.allocPrint(allocator, "~{s}/{s}", .{ username, reponame }),
            .tag_name = try allocator.dupe(u8, tag_info.tag_name),
            .published_at = published_at,
            .html_url = try std.fmt.allocPrint(allocator, "https://git.sr.ht/~{s}/{s}/refs/{s}", .{ username, reponame, tag_info.tag_name }),
            .description = try std.fmt.allocPrint(allocator, "Tag {s} (commit: {s})", .{ tag_info.tag_name, tag_info.commit_id }),
            .provider = try allocator.dupe(u8, "sourcehut"),
        };

        releases.append(release) catch |err| {
            release.deinit(allocator);
            return err;
        };
    }

    // Sort releases by date (most recent first)
    std.mem.sort(Release, releases.items, {}, compareReleasesByDate);

    return releases;
}

fn getCommitDate(allocator: Allocator, client: *http.Client, token: []const u8, username: []const u8, reponame: []const u8, commit_id: []const u8) ![]const u8 {
    if (commit_id.len == 0) return "";

    const graphql_url = "https://git.sr.ht/query";
    const uri = try std.Uri.parse(graphql_url);

    // Use the exact same GraphQL query that worked in curl, with proper brace escaping
    const request_body = try std.fmt.allocPrint(allocator, "{{\"query\":\"query {{ user(username: \\\"{s}\\\") {{ repository(name: \\\"{s}\\\") {{ revparse_single(revspec: \\\"{s}\\\") {{ author {{ time }} committer {{ time }} }} }} }} }}\"}}", .{ username, reponame, commit_id });
    defer allocator.free(request_body);

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    const headers: []const http.Header = &.{
        .{ .name = "User-Agent", .value = "release-tracker/1.0" },
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Content-Type", .value = "application/json" },
    };

    var server_header_buffer: [16 * 1024]u8 = undefined;
    var req = try client.open(.POST, uri, .{
        .server_header_buffer = &server_header_buffer,
        .extra_headers = headers,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = request_body.len };
    try req.send();
    try req.writeAll(request_body);
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        std.debug.print("SourceHut commit date query failed with status: {} for commit {s}\n", .{ req.response.status, commit_id });
        return "";
    }

    const body = try req.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(body);

    // Parse the response
    var parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch |err| {
        std.debug.print("Failed to parse commit date response: {}\n", .{err});
        return "";
    };
    defer parsed.deinit();

    const root = parsed.value;

    // Check for GraphQL errors first
    if (root.object.get("errors")) |errors| {
        std.debug.print("GraphQL errors for commit {s}: ", .{commit_id});
        for (errors.array.items) |error_item| {
            if (error_item.object.get("message")) |message| {
                std.debug.print("{s} ", .{message.string});
            }
        }
        std.debug.print("\n", .{});
        return "";
    }

    const data = root.object.get("data") orelse return "";
    const user = data.object.get("user") orelse return "";
    if (user == .null) return "";
    const repository = user.object.get("repository") orelse return "";
    if (repository == .null) return "";
    const revparse_single = repository.object.get("revparse_single") orelse return "";
    if (revparse_single == .null) return "";

    // Try to get author time first, then committer time as fallback
    if (revparse_single.object.get("author")) |author| {
        if (author.object.get("time")) |time| {
            if (time == .string) {
                return try allocator.dupe(u8, time.string);
            }
        }
    }

    if (revparse_single.object.get("committer")) |committer| {
        if (committer.object.get("time")) |time| {
            if (time == .string) {
                return try allocator.dupe(u8, time.string);
            }
        }
    }

    return "";
}

fn compareReleasesByDate(context: void, a: Release, b: Release) bool {
    _ = context;
    const timestamp_a = parseTimestamp(a.published_at) catch 0;
    const timestamp_b = parseTimestamp(b.published_at) catch 0;
    return timestamp_a > timestamp_b; // Most recent first
}

fn parseReleaseTimestamp(date_str: []const u8) !i64 {
    return parseTimestamp(date_str);
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

fn filterNewReleases(allocator: Allocator, all_releases: []const Release, since_timestamp: i64) !ArrayList(Release) {
    var new_releases = ArrayList(Release).init(allocator);
    errdefer {
        for (new_releases.items) |release| {
            release.deinit(allocator);
        }
        new_releases.deinit();
    }

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
            new_releases.append(new_release) catch |err| {
                new_release.deinit(allocator);
                return err;
            };
        }
    }

    return new_releases;
}

test "sourcehut provider" {
    const allocator = std.testing.allocator;

    const repos = [_][]const u8{};
    var sourcehut_provider = init("", &repos);

    // Test with empty token (should fail gracefully)
    const releases = sourcehut_provider.fetchReleases(allocator) catch |err| {
        try std.testing.expect(err == error.HttpRequestFailed);
        return;
    };
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    try std.testing.expectEqualStrings("sourcehut", sourcehut_provider.getName());
}
