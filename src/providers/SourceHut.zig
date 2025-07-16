const std = @import("std");
const http = std.http;
const json = std.json;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const utils = @import("../utils.zig");

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

    if (repositories.len == 0) {
        return ArrayList(Release).init(allocator);
    }

    const auth_token = token orelse {
        const stderr = std.io.getStdErr().writer();
        stderr.print("SourceHut: No token provided, skipping\n", .{}) catch {};
        return ArrayList(Release).init(allocator);
    };

    if (auth_token.len == 0) {
        const stderr = std.io.getStdErr().writer();
        stderr.print("SourceHut: Empty token, skipping\n", .{}) catch {};
        return ArrayList(Release).init(allocator);
    }

    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    return fetchReleasesMultiRepo(allocator, &client, auth_token, repositories);
}

pub fn fetchReleasesForReposFiltered(self: *Self, allocator: Allocator, repositories: [][]const u8, token: ?[]const u8, existing_releases: []const Release) !ArrayList(Release) {
    var latest_date: i64 = 0;
    for (existing_releases) |release| {
        if (std.mem.eql(u8, release.provider, "sourcehut")) {
            const release_time = utils.parseReleaseTimestamp(release.published_at) catch 0;
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

// Multi-repository approach using 2 GraphQL queries total
fn fetchReleasesMultiRepo(allocator: Allocator, client: *http.Client, token: []const u8, repositories: [][]const u8) !ArrayList(Release) {
    var releases = ArrayList(Release).init(allocator);
    errdefer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    // Parse repositories and validate format
    var parsed_repos = ArrayList(ParsedRepo).init(allocator);
    defer {
        for (parsed_repos.items) |repo| {
            allocator.free(repo.username);
            allocator.free(repo.reponame);
        }
        parsed_repos.deinit();
    }

    for (repositories) |repo| {
        const parsed = parseRepoFormat(allocator, repo) catch |err| {
            const stderr = std.io.getStdErr().writer();
            stderr.print("Invalid repo format '{s}': {}\n", .{ repo, err }) catch {};
            continue;
        };
        try parsed_repos.append(parsed);
    }

    if (parsed_repos.items.len == 0) {
        return releases;
    }

    // Step 1: Get all references for all repositories in one query
    const all_tag_data = getAllReferencesMultiRepo(allocator, client, token, parsed_repos.items) catch |err| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("Failed to get references: {}\n", .{err}) catch {};
        return releases;
    };
    defer {
        for (all_tag_data.items) |tag_data| {
            allocator.free(tag_data.username);
            allocator.free(tag_data.reponame);
            allocator.free(tag_data.tag_name);
            allocator.free(tag_data.commit_id);
        }
        all_tag_data.deinit();
    }

    if (all_tag_data.items.len == 0) {
        return releases;
    }

    // Step 2: Get commit dates for all commits in one query
    const commit_dates = getAllCommitDatesMultiRepo(allocator, client, token, parsed_repos.items, all_tag_data.items) catch |err| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("Failed to get commit dates: {}\n", .{err}) catch {};
        return releases;
    };
    defer {
        for (commit_dates.items) |date| {
            if (date.len > 0) allocator.free(date);
        }
        commit_dates.deinit();
    }

    // Step 3: Combine tag data with commit dates to create releases
    for (all_tag_data.items, 0..) |tag_data, i| {
        const commit_date = if (i < commit_dates.items.len and commit_dates.items[i].len > 0)
            commit_dates.items[i]
        else
            "1970-01-01T00:00:00Z";

        const release = Release{
            .repo_name = try std.fmt.allocPrint(allocator, "~{s}/{s}", .{ tag_data.username, tag_data.reponame }),
            .tag_name = try allocator.dupe(u8, tag_data.tag_name),
            .published_at = try utils.parseReleaseTimestamp(commit_date),
            .html_url = try std.fmt.allocPrint(allocator, "https://git.sr.ht/~{s}/{s}/refs/{s}", .{ tag_data.username, tag_data.reponame, tag_data.tag_name }),
            .description = try std.fmt.allocPrint(allocator, "Tag {s} (commit: {s})", .{ tag_data.tag_name, tag_data.commit_id }),
            .provider = try allocator.dupe(u8, "sourcehut"),
        };

        releases.append(release) catch |err| {
            release.deinit(allocator);
            return err;
        };
    }

    // Sort releases by date (most recent first)
    std.mem.sort(Release, releases.items, {}, utils.compareReleasesByDate);

    return releases;
}

const ParsedRepo = struct {
    username: []const u8,
    reponame: []const u8,
};

const TagData = struct {
    username: []const u8,
    reponame: []const u8,
    tag_name: []const u8,
    commit_id: []const u8,
};

const TagInfo = struct {
    tag_name: []const u8,
    commit_id: []const u8,
    index: usize,
};

fn parseRepoFormat(allocator: Allocator, repo: []const u8) !ParsedRepo {
    // Parse repo format: "~username/reponame" or "username/reponame"
    const repo_clean = if (std.mem.startsWith(u8, repo, "~")) repo[1..] else repo;
    var parts = std.mem.splitScalar(u8, repo_clean, '/');
    const username = parts.next() orelse return error.InvalidRepoFormat;
    const reponame = parts.next() orelse return error.InvalidRepoFormat;

    return ParsedRepo{
        .username = try allocator.dupe(u8, username),
        .reponame = try allocator.dupe(u8, reponame),
    };
}

fn getAllReferencesMultiRepo(allocator: Allocator, client: *http.Client, token: []const u8, repos: []const ParsedRepo) !ArrayList(TagData) {
    var all_tag_data = ArrayList(TagData).init(allocator);
    errdefer {
        for (all_tag_data.items) |tag_data| {
            allocator.free(tag_data.username);
            allocator.free(tag_data.reponame);
            allocator.free(tag_data.tag_name);
            allocator.free(tag_data.commit_id);
        }
        all_tag_data.deinit();
    }

    // Build GraphQL query with aliases for all repositories
    var query_parts = ArrayList([]const u8).init(allocator);
    defer {
        for (query_parts.items) |part| {
            allocator.free(part);
        }
        query_parts.deinit();
    }

    try query_parts.append(try allocator.dupe(u8, "query {"));

    for (repos, 0..) |repo, i| {
        const repo_query = try std.fmt.allocPrint(allocator, "  repo{d}: user(username: \"{s}\") {{ repository(name: \"{s}\") {{ name references {{ results {{ name target }} }} }} }}", .{ i, repo.username, repo.reponame });
        try query_parts.append(repo_query);
    }

    try query_parts.append(try allocator.dupe(u8, "}"));

    // Join all parts with newlines
    var total_len: usize = 0;
    for (query_parts.items) |part| {
        total_len += part.len + 1; // +1 for newline
    }

    var query_str = try allocator.alloc(u8, total_len);
    defer allocator.free(query_str);

    var pos: usize = 0;
    for (query_parts.items) |part| {
        @memcpy(query_str[pos .. pos + part.len], part);
        pos += part.len;
        query_str[pos] = '\n';
        pos += 1;
    }

    // Create JSON request body using std.json
    var json_obj = std.json.ObjectMap.init(allocator);
    defer json_obj.deinit();

    try json_obj.put("query", std.json.Value{ .string = query_str[0 .. query_str.len - 1] }); // Remove last newline

    var json_string = ArrayList(u8).init(allocator);
    defer json_string.deinit();

    try std.json.stringify(std.json.Value{ .object = json_obj }, .{}, json_string.writer());

    // Make the GraphQL request
    const response_body = try makeGraphQLRequest(allocator, client, token, json_string.items);
    defer allocator.free(response_body);

    // Parse the response and extract tag data
    var parsed = json.parseFromSlice(json.Value, allocator, response_body, .{}) catch |err| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("SourceHut: Failed to parse references JSON response: {}\n", .{err}) catch {};
        return all_tag_data;
    };
    defer parsed.deinit();

    const root = parsed.value;

    // Check for GraphQL errors first
    if (root.object.get("errors")) |errors| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("GraphQL errors in references query: ", .{}) catch {};
        for (errors.array.items) |error_item| {
            if (error_item.object.get("message")) |message| {
                stderr.print("{s} ", .{message.string}) catch {};
            }
        }
        stderr.print("\n", .{}) catch {};
        return all_tag_data;
    }

    const data = root.object.get("data") orelse return all_tag_data;

    // Process each repository's results
    for (repos, 0..) |repo, i| {
        const alias = try std.fmt.allocPrint(allocator, "repo{d}", .{i});
        defer allocator.free(alias);

        const repo_data = data.object.get(alias) orelse continue;
        if (repo_data == .null) continue;
        const repository = repo_data.object.get("repository") orelse continue;
        if (repository == .null) continue;
        const references = repository.object.get("references") orelse continue;
        const results = references.object.get("results") orelse continue;

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
                const tag_data = TagData{
                    .username = try allocator.dupe(u8, repo.username),
                    .reponame = try allocator.dupe(u8, repo.reponame),
                    .tag_name = try allocator.dupe(u8, tag_name),
                    .commit_id = try allocator.dupe(u8, commit_id),
                };
                all_tag_data.append(tag_data) catch |err| {
                    allocator.free(tag_data.username);
                    allocator.free(tag_data.reponame);
                    allocator.free(tag_data.tag_name);
                    allocator.free(tag_data.commit_id);
                    return err;
                };
            }
        }
    }

    return all_tag_data;
}

fn getAllCommitDatesMultiRepo(allocator: Allocator, client: *http.Client, token: []const u8, repos: []const ParsedRepo, tag_data: []const TagData) !ArrayList([]const u8) {
    _ = repos; // unused in this implementation
    var commit_dates = ArrayList([]const u8).init(allocator);
    errdefer {
        for (commit_dates.items) |date| {
            if (date.len > 0) allocator.free(date);
        }
        commit_dates.deinit();
    }

    if (tag_data.len == 0) {
        return commit_dates;
    }

    // Since SourceHut's objects() query automatically resolves tag objects to their target commits,
    // we need to use a different approach. Let's use the revparse_single query for each tag individually
    // but batch them by repository to minimize queries.

    // Group tags by repository
    const RepoTags = struct {
        username: []const u8,
        reponame: []const u8,
        tags: ArrayList(TagInfo),
    };

    var repo_tags_map = ArrayList(RepoTags).init(allocator);
    defer {
        for (repo_tags_map.items) |*item| {
            item.tags.deinit();
        }
        repo_tags_map.deinit();
    }

    for (tag_data, 0..) |tag, i| {
        // Find or create repo entry
        var found = false;
        for (repo_tags_map.items) |*repo_tags| {
            if (std.mem.eql(u8, repo_tags.username, tag.username) and std.mem.eql(u8, repo_tags.reponame, tag.reponame)) {
                try repo_tags.tags.append(TagInfo{ .tag_name = tag.tag_name, .commit_id = tag.commit_id, .index = i });
                found = true;
                break;
            }
        }
        if (!found) {
            var new_tags = ArrayList(TagInfo).init(allocator);
            try new_tags.append(TagInfo{ .tag_name = tag.tag_name, .commit_id = tag.commit_id, .index = i });
            try repo_tags_map.append(RepoTags{
                .username = tag.username,
                .reponame = tag.reponame,
                .tags = new_tags,
            });
        }
    }

    // Initialize result array with empty strings
    for (tag_data) |_| {
        try commit_dates.append("");
    }

    // Build a single GraphQL query with all repositories and all their commits using aliases
    var query_builder = ArrayList(u8).init(allocator);
    defer query_builder.deinit();

    try query_builder.appendSlice("query {\n");

    // Build the query with aliases for each repository
    for (repo_tags_map.items, 0..) |repo_tags, repo_idx| {
        try query_builder.writer().print("  repo{d}: user(username: \"{s}\") {{\n", .{ repo_idx, repo_tags.username });
        try query_builder.writer().print("    repository(name: \"{s}\") {{\n", .{repo_tags.reponame});

        for (repo_tags.tags.items, 0..) |tag_info, tag_idx| {
            try query_builder.writer().print("      tag{d}_{d}: revparse_single(revspec: \"{s}\") {{\n", .{ repo_idx, tag_idx, tag_info.commit_id });
            try query_builder.appendSlice("        ... on Commit {\n");
            try query_builder.appendSlice("          committer { time }\n");
            try query_builder.appendSlice("        }\n");
            try query_builder.appendSlice("      }\n");
        }

        try query_builder.appendSlice("    }\n");
        try query_builder.appendSlice("  }\n");
    }

    try query_builder.appendSlice("}");

    // Create JSON request body
    var json_obj = std.json.ObjectMap.init(allocator);
    defer json_obj.deinit();

    try json_obj.put("query", std.json.Value{ .string = query_builder.items });

    var json_string = ArrayList(u8).init(allocator);
    defer json_string.deinit();

    try std.json.stringify(std.json.Value{ .object = json_obj }, .{}, json_string.writer());

    // Make the single GraphQL request for all repositories and commits
    const response_body = try makeGraphQLRequest(allocator, client, token, json_string.items);
    defer allocator.free(response_body);

    // Parse the response
    var parsed = json.parseFromSlice(json.Value, allocator, response_body, .{}) catch |err| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("SourceHut: Failed to parse commit dates JSON response: {}\n", .{err}) catch {};
        // Return empty dates for all tags
        for (tag_data) |_| {
            try commit_dates.append("");
        }
        return commit_dates;
    };
    defer parsed.deinit();

    const root = parsed.value;

    // Check for GraphQL errors first
    if (root.object.get("errors")) |errors| {
        const stderr = std.io.getStdErr().writer();
        stderr.print("GraphQL errors in commit dates query: ", .{}) catch {};
        for (errors.array.items) |error_item| {
            if (error_item.object.get("message")) |message| {
                stderr.print("{s} ", .{message.string}) catch {};
            }
        }
        stderr.print("\n", .{}) catch {};
        // Return empty dates for all tags
        for (tag_data) |_| {
            try commit_dates.append("");
        }
        return commit_dates;
    }

    const data = root.object.get("data") orelse {
        // Return empty dates for all tags
        for (tag_data) |_| {
            try commit_dates.append("");
        }
        return commit_dates;
    };

    // Extract dates for each tag using the aliases
    for (repo_tags_map.items, 0..) |repo_tags, repo_idx| {
        const repo_alias = try std.fmt.allocPrint(allocator, "repo{d}", .{repo_idx});
        defer allocator.free(repo_alias);

        const repo_data = data.object.get(repo_alias) orelse continue;
        if (repo_data == .null) continue;
        const repository = repo_data.object.get("repository") orelse continue;
        if (repository == .null) continue;

        for (repo_tags.tags.items, 0..) |tag_info, tag_idx| {
            const tag_alias = try std.fmt.allocPrint(allocator, "tag{d}_{d}", .{ repo_idx, tag_idx });
            defer allocator.free(tag_alias);

            const tag_obj = repository.object.get(tag_alias);
            if (tag_obj) |obj| {
                if (obj == .null) continue;

                if (obj.object.get("committer")) |committer| {
                    if (committer.object.get("time")) |time| {
                        if (time == .string) {
                            // Free the empty string we allocated earlier
                            if (commit_dates.items[tag_info.index].len > 0) {
                                allocator.free(commit_dates.items[tag_info.index]);
                            }
                            commit_dates.items[tag_info.index] = try allocator.dupe(u8, time.string);
                        }
                    }
                }
            }
        }
    }

    return commit_dates;
}

fn getSingleCommitDate(allocator: Allocator, client: *http.Client, token: []const u8, username: []const u8, reponame: []const u8, commit_id: []const u8) ![]const u8 {
    _ = allocator;
    _ = client;
    _ = token;
    _ = username;
    _ = reponame;
    _ = commit_id;
    // This function is no longer used but kept for compatibility
    return "";
}

fn makeGraphQLRequest(allocator: Allocator, client: *http.Client, token: []const u8, request_body: []const u8) ![]const u8 {
    const graphql_url = "https://git.sr.ht/query";
    const uri = try std.Uri.parse(graphql_url);

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
        const stderr = std.io.getStdErr().writer();
        stderr.print("SourceHut GraphQL API request failed with status: {}\n", .{req.response.status}) catch {};
        return error.HttpRequestFailed;
    }

    return try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
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
        const release_time = utils.parseReleaseTimestamp(release.published_at) catch continue;

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
