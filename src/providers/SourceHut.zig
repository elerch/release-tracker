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

    if (repositories.len == 0) {
        return ArrayList(Release).init(allocator);
    }

    const auth_token = token orelse {
        std.debug.print("SourceHut: No token provided, skipping\n", .{});
        return ArrayList(Release).init(allocator);
    };

    if (auth_token.len == 0) {
        std.debug.print("SourceHut: Empty token, skipping\n", .{});
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
            std.debug.print("Invalid repo format '{s}': {}\n", .{ repo, err });
            continue;
        };
        try parsed_repos.append(parsed);
    }

    if (parsed_repos.items.len == 0) {
        return releases;
    }

    // Step 1: Get all references for all repositories in one query
    const all_tag_data = getAllReferencesMultiRepo(allocator, client, token, parsed_repos.items) catch |err| {
        std.debug.print("Failed to get references: {}\n", .{err});
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
        std.debug.print("Failed to get commit dates: {}\n", .{err});
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
            .published_at = try allocator.dupe(u8, commit_date),
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
    std.mem.sort(Release, releases.items, {}, compareReleasesByDate);

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
        std.debug.print("SourceHut: Failed to parse references JSON response: {}\n", .{err});
        return all_tag_data;
    };
    defer parsed.deinit();

    const root = parsed.value;

    // Check for GraphQL errors first
    if (root.object.get("errors")) |errors| {
        std.debug.print("GraphQL errors in references query: ", .{});
        for (errors.array.items) |error_item| {
            if (error_item.object.get("message")) |message| {
                std.debug.print("{s} ", .{message.string});
            }
        }
        std.debug.print("\n", .{});
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

    // Group commit hashes by repository using simple arrays
    const RepoCommits = struct {
        repo_idx: u32,
        commits: ArrayList([]const u8),
    };

    var repo_commits_list = ArrayList(RepoCommits).init(allocator);
    defer {
        for (repo_commits_list.items) |*item| {
            item.commits.deinit();
        }
        repo_commits_list.deinit();
    }

    // Build mapping of tag_data to repository indices
    for (tag_data, 0..) |tag, tag_idx| {
        // Find which repository this tag belongs to
        for (repos, 0..) |repo, repo_idx| {
            if (std.mem.eql(u8, tag.username, repo.username) and std.mem.eql(u8, tag.reponame, repo.reponame)) {
                // Find or create entry for this repo
                var found = false;
                for (repo_commits_list.items) |*item| {
                    if (item.repo_idx == repo_idx) {
                        try item.commits.append(tag.commit_id);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    var new_commits = ArrayList([]const u8).init(allocator);
                    try new_commits.append(tag.commit_id);
                    try repo_commits_list.append(RepoCommits{
                        .repo_idx = @intCast(repo_idx),
                        .commits = new_commits,
                    });
                }
                break;
            }
        }
        _ = tag_idx;
    }

    // Build GraphQL query with variables for commit hashes grouped by repository
    var query_builder = ArrayList(u8).init(allocator);
    defer query_builder.deinit();

    var variables_builder = ArrayList(u8).init(allocator);
    defer variables_builder.deinit();

    try query_builder.appendSlice("query(");
    try variables_builder.appendSlice("{");

    // Build query variables and structure
    var first_var = true;
    for (repo_commits_list.items) |item| {
        if (item.commits.items.len == 0) continue;

        const var_name = try std.fmt.allocPrint(allocator, "repo{d}Hashes", .{item.repo_idx});
        defer allocator.free(var_name);

        if (!first_var) {
            try query_builder.appendSlice(", ");
            try variables_builder.appendSlice(", ");
        }
        first_var = false;

        try query_builder.writer().print("${s}: [String!]!", .{var_name});

        // Build JSON array of commit hashes
        try variables_builder.writer().print("\"{s}\": [", .{var_name});
        for (item.commits.items, 0..) |commit, i| {
            if (i > 0) try variables_builder.appendSlice(", ");
            try variables_builder.writer().print("\"{s}\"", .{commit});
        }
        try variables_builder.appendSlice("]");
    }

    try query_builder.appendSlice(") {");
    try variables_builder.appendSlice("}");

    // Build query body
    for (repo_commits_list.items) |item| {
        if (item.commits.items.len == 0) continue;

        const repo = repos[item.repo_idx];
        const alias = try std.fmt.allocPrint(allocator, "repo{d}", .{item.repo_idx});
        defer allocator.free(alias);
        const var_name = try std.fmt.allocPrint(allocator, "repo{d}Hashes", .{item.repo_idx});
        defer allocator.free(var_name);

        const repo_query = try std.fmt.allocPrint(allocator,
            \\
            \\  {s}: user(username: "{s}") {{
            \\    repository(name: "{s}") {{
            \\      objects(ids: ${s}) {{
            \\        id
            \\        ... on Commit {{
            \\          committer {{
            \\            time
            \\          }}
            \\        }}
            \\      }}
            \\    }}
            \\  }}
        , .{ alias, repo.username, repo.reponame, var_name });
        defer allocator.free(repo_query);

        try query_builder.appendSlice(repo_query);
    }

    try query_builder.appendSlice("\n}");

    // Properly escape the query string for JSON
    var escaped_query = ArrayList(u8).init(allocator);
    defer escaped_query.deinit();

    for (query_builder.items) |char| {
        switch (char) {
            '"' => try escaped_query.appendSlice("\\\""),
            '\\' => try escaped_query.appendSlice("\\\\"),
            '\n' => try escaped_query.appendSlice("\\n"),
            '\r' => try escaped_query.appendSlice("\\r"),
            '\t' => try escaped_query.appendSlice("\\t"),
            else => try escaped_query.append(char),
        }
    }

    // Build the complete JSON request body manually
    var request_body = ArrayList(u8).init(allocator);
    defer request_body.deinit();

    try request_body.appendSlice("{\"query\":\"");
    try request_body.appendSlice(escaped_query.items);
    try request_body.appendSlice("\",\"variables\":");
    try request_body.appendSlice(variables_builder.items);
    try request_body.appendSlice("}");

    // Make the GraphQL request
    const response_body = try makeGraphQLRequest(allocator, client, token, request_body.items);
    defer allocator.free(response_body);

    // Parse the response
    var parsed = json.parseFromSlice(json.Value, allocator, response_body, .{}) catch |err| {
        std.debug.print("SourceHut: Failed to parse commit dates JSON response: {}\n", .{err});
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
        std.debug.print("GraphQL errors in commit dates query: ", .{});
        for (errors.array.items) |error_item| {
            if (error_item.object.get("message")) |message| {
                std.debug.print("{s} ", .{message.string});
            }
        }
        std.debug.print("\n", .{});
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

    // Build a simple list of commit_id -> date pairs for quick lookup
    const CommitDate = struct {
        commit_id: []const u8,
        date: []const u8,
    };
    var commit_date_list = ArrayList(CommitDate).init(allocator);
    defer commit_date_list.deinit();

    for (repo_commits_list.items) |item| {
        const alias = try std.fmt.allocPrint(allocator, "repo{d}", .{item.repo_idx});
        defer allocator.free(alias);

        const repo_data = data.object.get(alias) orelse continue;
        if (repo_data == .null) continue;
        const repository = repo_data.object.get("repository") orelse continue;
        if (repository == .null) continue;
        const objects = repository.object.get("objects") orelse continue;

        for (objects.array.items) |obj| {
            const id = obj.object.get("id") orelse continue;
            const committer = obj.object.get("committer") orelse continue;
            const time = committer.object.get("time") orelse continue;

            if (id == .string and time == .string) {
                try commit_date_list.append(CommitDate{
                    .commit_id = id.string,
                    .date = time.string,
                });
            }
        }
    }

    // Now build the result array in the same order as tag_data
    for (tag_data) |tag| {
        var found_date: []const u8 = "";
        for (commit_date_list.items) |item| {
            if (std.mem.eql(u8, item.commit_id, tag.commit_id)) {
                found_date = item.date;
                break;
            }
        }

        if (found_date.len > 0) {
            try commit_dates.append(try allocator.dupe(u8, found_date));
        } else {
            try commit_dates.append("");
        }
    }

    return commit_dates;
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
        std.debug.print("SourceHut GraphQL API request failed with status: {}\n", .{req.response.status});
        return error.HttpRequestFailed;
    }

    return try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
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
