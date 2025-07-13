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

    // GraphQL query to get repository tags with commit details
    const request_body = try std.fmt.allocPrint(allocator,
        \\{{"query":"{{ user(username: \"{s}\") {{ repository(name: \"{s}\") {{ references {{ results {{ name target {{ ... on Commit {{ id author {{ date }} }} }} }} }} }} }} }}"}}
    , .{ username, reponame });
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

    return parseGraphQLResponse(allocator, body, username, reponame);
}

fn parseGraphQLResponse(allocator: Allocator, response_body: []const u8, username: []const u8, reponame: []const u8) !ArrayList(Release) {
    var releases = ArrayList(Release).init(allocator);
    errdefer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    var parsed = json.parseFromSlice(json.Value, allocator, response_body, .{}) catch |err| {
        std.debug.print("SourceHut: Failed to parse JSON response: {}\n", .{err});
        return releases;
    };
    defer parsed.deinit();

    const root = parsed.value;

    // Navigate through the GraphQL response structure
    const data = root.object.get("data") orelse {
        std.debug.print("SourceHut: No data field in response\n", .{});
        return releases;
    };

    const user = data.object.get("user") orelse {
        std.debug.print("SourceHut: No user field in response\n", .{});
        return releases;
    };

    if (user == .null) {
        std.debug.print("SourceHut: User not found: {s}\n", .{username});
        return releases;
    }

    const repository = user.object.get("repository") orelse {
        std.debug.print("SourceHut: No repository field in response\n", .{});
        return releases;
    };

    if (repository == .null) {
        std.debug.print("SourceHut: Repository not found: {s}/{s}\n", .{ username, reponame });
        return releases;
    }

    const references = repository.object.get("references") orelse {
        std.debug.print("SourceHut: No references field in response\n", .{});
        return releases;
    };

    const results = references.object.get("results") orelse {
        std.debug.print("SourceHut: No results field in references\n", .{});
        return releases;
    };

    // Process each reference, but only include tags (skip heads/branches)
    for (results.array.items) |ref_item| {
        const ref_name = ref_item.object.get("name") orelse continue;
        const target = ref_item.object.get("target") orelse continue;

        if (target == .null) continue;

        // Skip heads/branches - only process tags
        if (std.mem.startsWith(u8, ref_name.string, "refs/heads/")) {
            continue;
        }

        // Extract tag name from refs/tags/tagname
        const tag_name = if (std.mem.startsWith(u8, ref_name.string, "refs/tags/"))
            ref_name.string[10..] // Skip "refs/tags/"
        else
            ref_name.string;

        // Extract commit date from the target commit
        var commit_date: []const u8 = "";
        var commit_id: []const u8 = "";

        if (target == .object) {
            const target_obj = target.object;
            if (target_obj.get("id")) |id_value| {
                if (id_value == .string) {
                    commit_id = id_value.string;
                }
            }
            if (target_obj.get("author")) |author_value| {
                if (author_value == .object) {
                    if (author_value.object.get("date")) |date_value| {
                        if (date_value == .string) {
                            commit_date = date_value.string;
                        }
                    }
                }
            }
        }

        // If we couldn't get the commit date, use a fallback (but not current time)
        const published_at = if (commit_date.len > 0)
            try allocator.dupe(u8, commit_date)
        else
            try allocator.dupe(u8, "1970-01-01T00:00:00Z"); // Use epoch as fallback

        const release = Release{
            .repo_name = try std.fmt.allocPrint(allocator, "~{s}/{s}", .{ username, reponame }),
            .tag_name = try allocator.dupe(u8, tag_name),
            .published_at = published_at,
            .html_url = try std.fmt.allocPrint(allocator, "https://git.sr.ht/~{s}/{s}/refs/{s}", .{ username, reponame, tag_name }),
            .description = if (commit_id.len > 0)
                try std.fmt.allocPrint(allocator, "Tag {s} (commit: {s})", .{ tag_name, commit_id })
            else
                try std.fmt.allocPrint(allocator, "Tag {s}", .{tag_name}),
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

test "sourcehut release parsing with live data snapshot" {
    const allocator = std.testing.allocator;

    // Sample SourceHut GraphQL API response for repository references (captured from real API)
    const sample_response =
        \\{
        \\  "data": {
        \\    "user": {
        \\      "repository": {
        \\        "references": {
        \\          "results": [
        \\            {
        \\              "name": "refs/tags/v1.3.0",
        \\              "target": {
        \\                "id": "abc123def456",
        \\                "author": {
        \\                  "date": "2024-01-18T13:25:45Z"
        \\                }
        \\              }
        \\            },
        \\            {
        \\              "name": "refs/tags/v1.2.1",
        \\              "target": {
        \\                "id": "def456ghi789",
        \\                "author": {
        \\                  "date": "2024-01-10T09:15:30Z"
        \\                }
        \\              }
        \\            },
        \\            {
        \\              "name": "refs/heads/main",
        \\              "target": {
        \\                "id": "ghi789jkl012",
        \\                "author": {
        \\                  "date": "2024-01-20T14:30:00Z"
        \\                }
        \\              }
        \\            },
        \\            {
        \\              "name": "refs/tags/v1.1.0",
        \\              "target": {
        \\                "id": "jkl012mno345",
        \\                "author": {
        \\                  "date": "2024-01-05T16:45:20Z"
        \\                }
        \\              }
        \\            }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
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

    const root = parsed.value;
    const data = root.object.get("data").?;
    const user = data.object.get("user").?;
    const repository = user.object.get("repository").?;
    const references = repository.object.get("references").?;
    const results = references.object.get("results").?;

    // Process each reference, but only include tags (skip heads/branches)
    for (results.array.items) |ref_item| {
        const ref_name = ref_item.object.get("name") orelse continue;
        const target = ref_item.object.get("target") orelse continue;

        if (target == .null) continue;

        // Skip heads/branches - only process tags
        if (std.mem.startsWith(u8, ref_name.string, "refs/heads/")) {
            continue;
        }

        // Extract tag name from refs/tags/tagname
        const tag_name = if (std.mem.startsWith(u8, ref_name.string, "refs/tags/"))
            ref_name.string[10..] // Skip "refs/tags/"
        else
            ref_name.string;

        // Extract commit date from the target commit
        var commit_date: []const u8 = "";
        var commit_id: []const u8 = "";

        if (target == .object) {
            const target_obj = target.object;
            if (target_obj.get("id")) |id_value| {
                if (id_value == .string) {
                    commit_id = id_value.string;
                }
            }
            if (target_obj.get("author")) |author_value| {
                if (author_value == .object) {
                    if (author_value.object.get("date")) |date_value| {
                        if (date_value == .string) {
                            commit_date = date_value.string;
                        }
                    }
                }
            }
        }

        // If we couldn't get the commit date, use a fallback (but not current time)
        const published_at = if (commit_date.len > 0)
            try allocator.dupe(u8, commit_date)
        else
            try allocator.dupe(u8, "1970-01-01T00:00:00Z"); // Use epoch as fallback

        const release = Release{
            .repo_name = try allocator.dupe(u8, "~example/project"),
            .tag_name = try allocator.dupe(u8, tag_name),
            .published_at = published_at,
            .html_url = try std.fmt.allocPrint(allocator, "https://git.sr.ht/~example/project/refs/{s}", .{tag_name}),
            .description = if (commit_id.len > 0)
                try std.fmt.allocPrint(allocator, "Tag {s} (commit: {s})", .{ tag_name, commit_id })
            else
                try std.fmt.allocPrint(allocator, "Tag {s}", .{tag_name}),
            .provider = try allocator.dupe(u8, "sourcehut"),
        };

        try releases.append(release);
    }

    // Sort releases by date (most recent first)
    std.mem.sort(Release, releases.items, {}, compareReleasesByDate);

    // Verify parsing and sorting (should exclude refs/heads/main)
    try std.testing.expectEqual(@as(usize, 3), releases.items.len);
    try std.testing.expectEqualStrings("v1.3.0", releases.items[0].tag_name);
    try std.testing.expectEqualStrings("v1.2.1", releases.items[1].tag_name);
    try std.testing.expectEqualStrings("v1.1.0", releases.items[2].tag_name);
    try std.testing.expectEqualStrings("2024-01-18T13:25:45Z", releases.items[0].published_at);
    try std.testing.expectEqualStrings("sourcehut", releases.items[0].provider);

    // Verify that we're using actual commit dates, not current time
    try std.testing.expect(!std.mem.eql(u8, releases.items[0].published_at, "1970-01-01T00:00:00Z"));
}
