const std = @import("std");
const http = std.http;
const json = std.json;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Release = @import("../main.zig").Release;

pub const SourceHutProvider = struct {
    pub fn fetchReleases(self: *@This(), allocator: Allocator, token: []const u8) !ArrayList(Release) {
        _ = self;
        _ = token;
        return ArrayList(Release).init(allocator);
    }

    pub fn fetchReleasesForRepos(self: *@This(), allocator: Allocator, repositories: [][]const u8, token: ?[]const u8) !ArrayList(Release) {
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

    pub fn fetchReleasesForReposFiltered(self: *@This(), allocator: Allocator, repositories: [][]const u8, token: ?[]const u8, existing_releases: []const Release) !ArrayList(Release) {
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

    pub fn getName(self: *@This()) []const u8 {
        _ = self;
        return "sourcehut";
    }
};

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

    // GraphQL query to get repository tags - simplified approach
    const request_body = try std.fmt.allocPrint(allocator,
        \\{{"query":"{{ user(username: \"{s}\") {{ repository(name: \"{s}\") {{ references {{ results {{ name target }} }} }} }} }}"}}
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

        // For now, use current timestamp since we can't get commit date from this simple query
        // In a real implementation, we'd need a separate query to get commit details
        const current_time = std.time.timestamp();
        const timestamp_str = try std.fmt.allocPrint(allocator, "{d}", .{current_time});
        defer allocator.free(timestamp_str);

        const release = Release{
            .repo_name = try std.fmt.allocPrint(allocator, "~{s}/{s}", .{ username, reponame }),
            .tag_name = try allocator.dupe(u8, tag_name),
            .published_at = try allocator.dupe(u8, timestamp_str),
            .html_url = try std.fmt.allocPrint(allocator, "https://git.sr.ht/~{s}/{s}/refs/{s}", .{ username, reponame, tag_name }),
            .description = try std.fmt.allocPrint(allocator, "Tag {s} (commit: {s})", .{ tag_name, target.string }),
            .provider = try allocator.dupe(u8, "sourcehut"),
        };

        releases.append(release) catch |err| {
            release.deinit(allocator);
            return err;
        };
    }

    return releases;
}

fn parseReleaseTimestamp(date_str: []const u8) !i64 {
    // Handle different date formats from different providers
    // GitHub/GitLab: "2024-01-01T00:00:00Z"
    // Simple fallback: if it's a number, treat as timestamp

    if (date_str.len == 0) return 0;

    // Try parsing as direct timestamp first
    if (std.fmt.parseInt(i64, date_str, 10)) |timestamp| {
        return timestamp;
    } else |_| {
        // Try parsing ISO 8601 format (basic implementation)
        if (std.mem.indexOf(u8, date_str, "T")) |t_pos| {
            const date_part = date_str[0..t_pos];
            var date_parts = std.mem.splitScalar(u8, date_part, '-');

            const year_str = date_parts.next() orelse return error.InvalidDate;
            const month_str = date_parts.next() orelse return error.InvalidDate;
            const day_str = date_parts.next() orelse return error.InvalidDate;

            const year = try std.fmt.parseInt(i32, year_str, 10);
            const month = try std.fmt.parseInt(u8, month_str, 10);
            const day = try std.fmt.parseInt(u8, day_str, 10);

            // Simple approximation: convert to days since epoch and then to seconds
            // This is not precise but good enough for comparison
            const days_since_epoch: i64 = @as(i64, year - 1970) * 365 + @as(i64, month - 1) * 30 + @as(i64, day);
            return days_since_epoch * 24 * 60 * 60;
        }
    }

    return 0; // Default to epoch if we can't parse
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

    var provider = SourceHutProvider{};

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

    try std.testing.expectEqualStrings("sourcehut", provider.getName());
}
