const std = @import("std");
const http = std.http;
const json = std.json;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Thread = std.Thread;
const utils = @import("../utils.zig");

const Release = @import("../main.zig").Release;
const Provider = @import("../Provider.zig");

token: []const u8,

const Self = @This();

const log = std.log.scoped(.@"");

const RepoFetchTask = struct {
    allocator: Allocator,
    token: []const u8,
    repo: []const u8,
    result: ?ArrayList(Release) = null,
    error_msg: ?[]const u8 = null,
};

const RepoTagsTask = struct {
    allocator: Allocator,
    token: []const u8,
    repo: []const u8,
    result: ?ArrayList(Release) = null,
    error_msg: ?[]const u8 = null,
};

pub fn init(token: []const u8) Self {
    return Self{ .token = token };
}

pub fn provider(self: *Self) Provider {
    return Provider.init(self);
}

pub fn fetchReleases(self: *Self, allocator: Allocator) !ArrayList(Release) {
    const total_start_time = std.time.milliTimestamp();

    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    var releases = ArrayList(Release).init(allocator);

    // First, get starred repositories
    const starred_start_time = std.time.milliTimestamp();
    const starred_repos = try getStarredRepos(allocator, &client, self.token);
    defer {
        for (starred_repos.items) |repo| {
            allocator.free(repo);
        }
        starred_repos.deinit();
    }
    const starred_end_time = std.time.milliTimestamp();

    if (starred_repos.items.len == 0) return releases;

    const starred_duration: u64 = @intCast(starred_end_time - starred_start_time);
    log.debug("Found {} starred repositories in {}ms", .{ starred_repos.items.len, starred_duration });

    // Check for potentially inaccessible repositories due to enterprise policies
    // try checkForInaccessibleRepos(allocator, &client, self.token, starred_repos.items);

    const thread_start_time = std.time.milliTimestamp();

    // Create thread pool - use reasonable number of threads for API calls
    var thread_pool: Thread.Pool = undefined;
    try thread_pool.init(.{ .allocator = allocator });
    defer thread_pool.deinit();

    // Create tasks for each repository: fetch releases
    var tasks = try allocator.alloc(RepoFetchTask, starred_repos.items.len);
    defer allocator.free(tasks);

    // Initialize tasks
    for (starred_repos.items, 0..) |repo, i| {
        tasks[i] = RepoFetchTask{
            .allocator = allocator,
            .token = self.token,
            .repo = repo,
        };
    }

    // Submit all tasks to the thread pool
    var wait_group: Thread.WaitGroup = .{};
    for (tasks) |*task|
        thread_pool.spawnWg(&wait_group, fetchRepoReleasesTask, .{task});

    // Create tasks for each repository: fetch tags
    var tag_tasks = try allocator.alloc(RepoTagsTask, starred_repos.items.len);
    defer allocator.free(tag_tasks);

    // Initialize tag tasks
    for (starred_repos.items, 0..) |repo, i| {
        tag_tasks[i] = RepoTagsTask{
            .allocator = allocator,
            .token = self.token,
            .repo = repo,
        };
    }

    // Submit all tag tasks to the thread pool
    var tag_wait_group: Thread.WaitGroup = .{};
    for (tag_tasks) |*task|
        thread_pool.spawnWg(&tag_wait_group, fetchRepoTagsTask, .{task});

    // Wait for all tasks to complete: releases
    thread_pool.waitAndWork(&wait_group);
    const releases_end_time = std.time.milliTimestamp();

    // Collect results from releases
    var successful_repos: usize = 0;
    var failed_repos: usize = 0;

    for (tasks) |*task| {
        if (task.result) |task_releases| {
            defer task_releases.deinit();
            try releases.appendSlice(task_releases.items);
            successful_repos += 1;
        } else {
            failed_repos += 1;
            if (task.error_msg) |err_msg| {
                const is_test = @import("builtin").is_test;
                if (!is_test) {
                    const stderr = std.io.getStdErr().writer();
                    stderr.print("Error fetching releases for {s}: {s}\n", .{ task.repo, err_msg }) catch {};
                }
                allocator.free(err_msg);
            }
        }
    }

    // Wait for all tasks to complete: tags
    thread_pool.waitAndWork(&tag_wait_group);

    const tags_end_time = std.time.milliTimestamp();

    // Process tag results with filtering
    var total_tags_found: usize = 0;
    for (tag_tasks) |*tag_task| {
        if (tag_task.result) |task_tags| {
            defer task_tags.deinit();
            const debug = std.mem.eql(u8, tag_task.repo, "DonIsaac/zlint");
            if (debug)
                log.debug("Processing target repo for debugging {s}", .{tag_task.repo});

            total_tags_found += task_tags.items.len;
            if (debug)
                log.debug("Found {} tags for {s}", .{ task_tags.items.len, tag_task.repo });

            // Filter out tags that already have corresponding releases
            // Tags filtered will be deinitted here
            const added_tags = try addNonReleaseTags(
                allocator,
                &releases,
                task_tags.items,
            );

            if (debug)
                log.debug("Added {d} tags out of {d} to release list for {s} ({d} filtered)", .{
                    added_tags,
                    task_tags.items.len,
                    tag_task.repo,
                    task_tags.items.len - added_tags,
                });
        } else if (tag_task.error_msg) |err_msg| {
            const is_test = @import("builtin").is_test;
            if (!is_test) {
                const stderr = std.io.getStdErr().writer();
                stderr.print("Error fetching tags for {s}: {s}\n", .{ tag_task.repo, err_msg }) catch {};
            }
            allocator.free(err_msg);
        }
    }

    log.debug("Total tags found across all repositories: {}", .{total_tags_found});

    const total_end_time = std.time.milliTimestamp();
    const releases_duration: u64 = @intCast(releases_end_time - thread_start_time);
    const tags_duration: u64 = @intCast(tags_end_time - thread_start_time);
    const total_duration: u64 = @intCast(total_end_time - total_start_time);
    log.debug("Fetched releases {}ms, tags {}ms ({} successful, {} failed)\n", .{
        releases_duration,
        tags_duration,
        successful_repos,
        failed_repos,
    });
    log.debug("Total processing time: {}ms\n", .{total_duration});

    // Sort releases by date (most recent first)
    std.mem.sort(Release, releases.items, {}, compareReleasesByDate);

    return releases;
}

pub fn getName(self: *Self) []const u8 {
    _ = self;
    return "github";
}

fn fetchRepoReleasesTask(task: *RepoFetchTask) void {
    var client = http.Client{ .allocator = task.allocator };
    defer client.deinit();

    const repo_releases = getRepoReleases(task.allocator, &client, task.token, task.repo) catch |err| {
        task.error_msg = std.fmt.allocPrint(task.allocator, "{s}: {}", .{ task.repo, err }) catch "Unknown error";
        return;
    };

    task.result = repo_releases;
}

fn fetchRepoTagsTask(task: *RepoTagsTask) void {
    var client = http.Client{ .allocator = task.allocator };
    defer client.deinit();

    const repo_tags = getRepoTags(task.allocator, &client, task.token, task.repo) catch |err| {
        task.error_msg = std.fmt.allocPrint(task.allocator, "{s}: {}", .{ task.repo, err }) catch "Unknown error";
        return;
    };

    task.result = repo_tags;
}

fn getStarredRepos(allocator: Allocator, client: *http.Client, token: []const u8) !ArrayList([]const u8) {
    var repos = ArrayList([]const u8).init(allocator);

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    const per_page: u32 = 100; // Use maximum per_page for efficiency
    const is_test = @import("builtin").is_test;

    // First, get the first page to determine total pages
    const url = try std.fmt.allocPrint(allocator, "https://api.github.com/user/starred?page=1&per_page={}", .{per_page});
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);

    var server_header_buffer: [16 * 1024]u8 = undefined;
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buffer,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
            .{ .name = "User-Agent", .value = "release-tracker/1.0" },
        },
    });
    defer req.deinit();

    try req.send();
    try req.wait();

    if (req.response.status != .ok) {
        if (!is_test) {
            const stderr = std.io.getStdErr().writer();
            stderr.print("GitHub: API error on page 1: HTTP {}\n", .{@intFromEnum(req.response.status)}) catch {};
        }
        return error.HttpRequestFailed;
    }

    // Parse Link header to get total pages
    var total_pages: u32 = 1;
    var header_it = req.response.iterateHeaders();
    while (header_it.next()) |header| {
        if (std.mem.eql(u8, header.name, "link") or std.mem.eql(u8, header.name, "Link")) {
            // Look for rel="last" to get total pages
            if (std.mem.indexOf(u8, header.value, "rel=\"last\"")) |_| {
                // Extract page number from URL like: <https://api.github.com/user/starred?page=3&per_page=100>; rel="last"
                var parts = std.mem.splitSequence(u8, header.value, ",");
                while (parts.next()) |part| {
                    if (std.mem.indexOf(u8, part, "rel=\"last\"")) |_| {
                        if (std.mem.indexOf(u8, part, "page=")) |page_start| {
                            const page_start_num = page_start + 5; // Skip "page="
                            if (std.mem.indexOf(u8, part[page_start_num..], "&")) |page_end| {
                                const page_str = part[page_start_num .. page_start_num + page_end];
                                total_pages = std.fmt.parseInt(u32, page_str, 10) catch 1;
                            }
                        }
                        break;
                    }
                }
            }
        }
    }

    // Process first page
    const body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(body);

    const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer parsed.deinit();

    const array = parsed.value.array;
    for (array.items) |item| {
        const obj = item.object;
        const full_name = obj.get("full_name").?.string;
        try repos.append(try allocator.dupe(u8, full_name));
    }

    // If there are more pages, fetch them in parallel
    if (total_pages > 1) {
        const PageFetchTask = struct {
            allocator: Allocator,
            token: []const u8,
            page: u32,
            per_page: u32,
            result: ?ArrayList([]const u8) = null,
            error_msg: ?[]const u8 = null,
        };

        const fetchPageTask = struct {
            fn run(task: *PageFetchTask) void {
                var page_client = http.Client{ .allocator = task.allocator };
                defer page_client.deinit();

                const page_url = std.fmt.allocPrint(task.allocator, "https://api.github.com/user/starred?page={}&per_page={}", .{ task.page, task.per_page }) catch {
                    task.error_msg = std.fmt.allocPrint(task.allocator, "Failed to format URL", .{}) catch "URL format error";
                    return;
                };
                defer task.allocator.free(page_url);

                const page_uri = std.Uri.parse(page_url) catch {
                    task.error_msg = std.fmt.allocPrint(task.allocator, "Failed to parse URL", .{}) catch "URL parse error";
                    return;
                };

                const page_auth_header = std.fmt.allocPrint(task.allocator, "Bearer {s}", .{task.token}) catch {
                    task.error_msg = std.fmt.allocPrint(task.allocator, "Failed to format auth header", .{}) catch "Auth header error";
                    return;
                };
                defer task.allocator.free(page_auth_header);

                var page_server_header_buffer: [16 * 1024]u8 = undefined;
                var page_req = page_client.open(.GET, page_uri, .{
                    .server_header_buffer = &page_server_header_buffer,
                    .extra_headers = &.{
                        .{ .name = "Authorization", .value = page_auth_header },
                        .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
                        .{ .name = "User-Agent", .value = "release-tracker/1.0" },
                    },
                }) catch {
                    task.error_msg = std.fmt.allocPrint(task.allocator, "Failed to open request", .{}) catch "Request open error";
                    return;
                };
                defer page_req.deinit();

                page_req.send() catch {
                    task.error_msg = std.fmt.allocPrint(task.allocator, "Failed to send request", .{}) catch "Request send error";
                    return;
                };
                page_req.wait() catch {
                    task.error_msg = std.fmt.allocPrint(task.allocator, "Failed to wait for response", .{}) catch "Request wait error";
                    return;
                };

                if (page_req.response.status != .ok) {
                    task.error_msg = std.fmt.allocPrint(task.allocator, "HTTP {}", .{@intFromEnum(page_req.response.status)}) catch "HTTP error";
                    return;
                }

                const page_body = page_req.reader().readAllAlloc(task.allocator, 10 * 1024 * 1024) catch {
                    task.error_msg = std.fmt.allocPrint(task.allocator, "Failed to read response body", .{}) catch "Body read error";
                    return;
                };
                defer task.allocator.free(page_body);

                const page_parsed = json.parseFromSlice(json.Value, task.allocator, page_body, .{}) catch {
                    task.error_msg = std.fmt.allocPrint(task.allocator, "Failed to parse JSON", .{}) catch "JSON parse error";
                    return;
                };
                defer page_parsed.deinit();

                var page_repos = ArrayList([]const u8).init(task.allocator);
                const page_array = page_parsed.value.array;
                for (page_array.items) |item| {
                    const obj = item.object;
                    const full_name = obj.get("full_name").?.string;
                    page_repos.append(task.allocator.dupe(u8, full_name) catch {
                        task.error_msg = std.fmt.allocPrint(task.allocator, "Failed to duplicate string", .{}) catch "String dup error";
                        return;
                    }) catch {
                        task.error_msg = std.fmt.allocPrint(task.allocator, "Failed to append repo", .{}) catch "Append error";
                        return;
                    };
                }

                task.result = page_repos;
            }
        }.run;

        // Create thread pool for parallel page fetching
        const thread_count = @min(total_pages - 1, 8); // Limit concurrent page requests
        var thread_pool: Thread.Pool = undefined;
        try thread_pool.init(.{ .allocator = allocator, .n_jobs = thread_count });
        defer thread_pool.deinit();

        // Create tasks for remaining pages (pages 2 to total_pages)
        const page_tasks = try allocator.alloc(PageFetchTask, total_pages - 1);
        defer allocator.free(page_tasks);

        for (page_tasks, 0..) |*task, i| {
            task.* = PageFetchTask{
                .allocator = allocator,
                .token = token,
                .page = @intCast(i + 2), // Pages 2, 3, 4, etc.
                .per_page = per_page,
            };
        }

        // Submit all page tasks to the thread pool
        var wait_group: Thread.WaitGroup = .{};
        for (page_tasks) |*task| {
            thread_pool.spawnWg(&wait_group, fetchPageTask, .{task});
        }

        // Wait for all page tasks to complete
        thread_pool.waitAndWork(&wait_group);

        // Collect results from all page tasks
        for (page_tasks) |*task| {
            if (task.result) |page_repos| {
                defer page_repos.deinit();
                try repos.appendSlice(page_repos.items);
            } else if (task.error_msg) |err_msg| {
                if (!is_test) {
                    const stderr = std.io.getStdErr().writer();
                    stderr.print("GitHub: Error fetching page {}: {s}\n", .{ task.page, err_msg }) catch {};
                }
                allocator.free(err_msg);
            }
        }
    }

    return repos;
}

fn getRepoReleases(allocator: Allocator, client: *http.Client, token: []const u8, repo: []const u8) !ArrayList(Release) {
    var releases = ArrayList(Release).init(allocator);

    const url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/releases", .{repo});
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    var server_header_buffer: [16 * 1024]u8 = undefined;
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buffer,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
            .{ .name = "User-Agent", .value = "release-tracker/1.0" },
        },
    });
    defer req.deinit();

    try req.send();
    try req.wait();

    if (req.response.status != .ok) {
        const is_test = @import("builtin").is_test;
        if (!is_test) {
            // Try to read the error response body for more details
            const error_body = req.reader().readAllAlloc(allocator, 4096) catch "";
            defer if (error_body.len > 0) allocator.free(error_body);

            const stderr = std.io.getStdErr().writer();
            stderr.print("GitHub: Failed to fetch releases for {s}: HTTP {} - {s}\n", .{ repo, @intFromEnum(req.response.status), error_body }) catch {};
        }
        return error.HttpRequestFailed;
    }

    const body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(body);

    const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer parsed.deinit();

    const array = parsed.value.array;
    for (array.items) |item| {
        const obj = item.object;

        const body_value = obj.get("body") orelse json.Value{ .string = "" };
        const body_str = if (body_value == .string) body_value.string else "";

        const release = Release{
            .repo_name = try allocator.dupe(u8, repo),
            .tag_name = try allocator.dupe(u8, obj.get("tag_name").?.string),
            .published_at = try utils.parseReleaseTimestamp(obj.get("published_at").?.string),
            .html_url = try allocator.dupe(u8, obj.get("html_url").?.string),
            .description = try allocator.dupe(u8, body_str),
            .provider = try allocator.dupe(u8, "github"),
            .is_tag = false,
        };

        try releases.append(release);
    }

    return releases;
}

fn shouldSkipTag(allocator: std.mem.Allocator, tag_name: []const u8) bool {
    // List of common moving tags that should be filtered out
    const moving_tags = [_][]const u8{
        // common "latest commit tags"
        "latest",
        "tip",
        "continuous",
        "head",

        // common branch tags
        "main",
        "master",
        "trunk",
        "develop",
        "development",
        "dev",

        // common fast moving channel names
        "nightly",
        "edge",
        "canary",
        "alpha",

        // common slower channels, but without version information
        // they probably are not something we're interested in
        "beta",
        "rc",
        "release",
        "snapshot",
        "unstable",
        "experimental",
        "prerelease",
        "preview",
    };

    // Check if tag name contains common moving patterns
    const tag_lower = std.ascii.allocLowerString(allocator, tag_name) catch return false;
    defer allocator.free(tag_lower);

    for (moving_tags) |moving_tag|
        if (std.mem.eql(u8, tag_lower, moving_tag))
            return true;

    // Skip pre-release and development tags
    if (std.mem.startsWith(u8, tag_lower, "pre-") or
        std.mem.startsWith(u8, tag_lower, "dev-") or
        std.mem.startsWith(u8, tag_lower, "test-") or
        std.mem.startsWith(u8, tag_lower, "debug-"))
        return true;

    return false;
}

fn getRepoTags(allocator: Allocator, client: *http.Client, token: []const u8, repo: []const u8) !ArrayList(Release) {
    var tags = ArrayList(Release).init(allocator);

    // Split repo into owner and name
    const slash_pos = std.mem.indexOf(u8, repo, "/") orelse return error.InvalidRepoFormat;
    const owner = repo[0..slash_pos];
    const repo_name = repo[slash_pos + 1 ..];

    var has_next_page = true;
    var cursor: ?[]const u8 = null;

    while (has_next_page) {
        // Build GraphQL query for tags with commit info
        const query = if (cursor) |c|
            try std.fmt.allocPrint(allocator,
                \\{{"query": "query {{ repository(owner: \"{s}\", name: \"{s}\") {{ refs(refPrefix: \"refs/tags/\", first: 100, after: \"{s}\", orderBy: {{field: TAG_COMMIT_DATE, direction: DESC}}) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ name target {{ ... on Commit {{ message committedDate }} ... on Tag {{ message target {{ ... on Commit {{ message committedDate }} }} }} }} }} }} }} }}"}}
            , .{ owner, repo_name, c })
        else
            try std.fmt.allocPrint(allocator,
                \\{{"query": "query {{ repository(owner: \"{s}\", name: \"{s}\") {{ refs(refPrefix: \"refs/tags/\", first: 100, orderBy: {{field: TAG_COMMIT_DATE, direction: DESC}}) {{ pageInfo {{ hasNextPage endCursor }} nodes {{ name target {{ ... on Commit {{ message committedDate }} ... on Tag {{ message target {{ ... on Commit {{ message committedDate }} }} }} }} }} }} }} }}"}}
            , .{ owner, repo_name });
        defer allocator.free(query);

        const uri = try std.Uri.parse("https://api.github.com/graphql");

        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        defer allocator.free(auth_header);

        var server_header_buffer: [16 * 1024]u8 = undefined;
        var req = try client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buffer,
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "User-Agent", .value = "release-tracker/1.0" },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = query.len };
        try req.send();
        _ = try req.writeAll(query);
        try req.finish();
        try req.wait();

        if (req.response.status != .ok) {
            // Try to read the error response body for more details
            const error_body = req.reader().readAllAlloc(allocator, 4096) catch "";
            defer if (error_body.len > 0) allocator.free(error_body);

            const is_test = @import("builtin").is_test;
            if (!is_test) {
                const stderr = std.io.getStdErr().writer();
                stderr.print("GitHub GraphQL: Failed to fetch tags for {s}: HTTP {} - {s}\n", .{ repo, @intFromEnum(req.response.status), error_body }) catch {};
            }
            return error.HttpRequestFailed;
        }

        const body = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
        defer allocator.free(body);

        has_next_page = try parseGraphQL(allocator, repo, body, &cursor, &tags);
    }

    // Clean up cursor if allocated
    if (cursor) |c| allocator.free(c);

    return tags;
}

fn parseGraphQL(allocator: std.mem.Allocator, repo: []const u8, body: []const u8, cursor: *?[]const u8, releases: *ArrayList(Release)) !bool {
    const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer parsed.deinit();

    // Check for GraphQL errors
    if (parsed.value.object.get("errors")) |errors| {
        log.err("GraphQL errors in output for repository {s}: {}", .{ repo, errors });
        return error.GraphQLError;
    }

    const data = parsed.value.object.get("data") orelse return error.NoData;
    const repository = data.object.get("repository") orelse return error.NoRepository;
    const refs = repository.object.get("refs") orelse return error.NoRefs;
    const page_info = refs.object.get("pageInfo").?.object;
    const nodes = refs.object.get("nodes").?.array;

    // Update pagination info
    const has_next_page = page_info.get("hasNextPage").?.bool;
    if (has_next_page) {
        const end_cursor = page_info.get("endCursor").?.string;
        if (cursor.*) |old_cursor| allocator.free(old_cursor);
        cursor.* = try allocator.dupe(u8, end_cursor);
    }

    // Process each tag
    for (nodes.items) |node| {
        const node_obj = node.object;
        const tag_name = node_obj.get("name").?.string;

        // Skip common moving tags
        if (shouldSkipTag(allocator, tag_name)) continue;

        const target = node_obj.get("target").?.object;

        var commit_date: i64 = 0;

        // Handle lightweight tags (point directly to commits)
        if (target.get("committedDate")) |date| {
            commit_date = utils.parseReleaseTimestamp(date.string) catch continue;
        }
        // Handle annotated tags (point to tag objects which point to commits)
        else if (target.get("target")) |nested_target| {
            if (nested_target.object.get("committedDate")) |date| {
                commit_date = utils.parseReleaseTimestamp(date.string) catch continue;
            } else {
                // Skip tags that don't have commit dates
                continue;
            }
        } else {
            // Skip tags that don't have commit dates
            continue;
        }

        // Create tag URL
        const tag_url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/tag/{s}", .{ repo, tag_name });

        var tag_message: []const u8 = "";
        if (target.get("message")) |m| {
            if (m == .string) tag_message = m.string;
        } else if (target.get("target")) |nested_target| {
            if (nested_target.object.get("message")) |nm| {
                if (nm == .string) tag_message = nm.string;
            }
        }
        const tag_release = Release{
            .repo_name = try allocator.dupe(u8, repo),
            .tag_name = try allocator.dupe(u8, tag_name),
            .published_at = commit_date,
            .html_url = tag_url,
            .description = try allocator.dupe(u8, tag_message),
            .provider = try allocator.dupe(u8, "github"),
            .is_tag = true,
        };

        try releases.append(tag_release);
    }
    return has_next_page;
}

/// Adds non-duplicate tags to the releases array.
///
/// This function takes ownership of all Release structs in `all_tags`. For each tag:
/// - If it's NOT a duplicate of an existing release, it's added to the releases array
/// - If it IS a duplicate, it's freed immediately using tag.deinit(allocator)
///
/// The caller should NOT call deinit on any Release structs in `all_tags` after calling
/// this function, as ownership has been transferred.
///
/// Duplicate detection is based on matching both repo_name and tag_name.
fn addNonReleaseTags(allocator: std.mem.Allocator, releases: *ArrayList(Release), all_tags: []const Release) !usize {
    var added: usize = 0;
    for (all_tags) |tag| {
        var is_duplicate = false;

        // Check if this tag already exists as a release
        for (releases.items) |release| {
            if (std.mem.eql(u8, tag.repo_name, release.repo_name) and
                std.mem.eql(u8, tag.tag_name, release.tag_name))
            {
                is_duplicate = true;
                break;
            }
        }

        if (is_duplicate) {
            tag.deinit(allocator);
        } else {
            try releases.append(tag);
            added += 1;
        }
    }
    return added;
}

fn getCommitDate(allocator: Allocator, client: *http.Client, token: []const u8, repo: []const u8, commit_sha: []const u8) !i64 {
    const url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/commits/{s}", .{ repo, commit_sha });
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    var server_header_buffer: [16 * 1024]u8 = undefined;
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buffer,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
            .{ .name = "User-Agent", .value = "release-tracker/1.0" },
        },
    });
    defer req.deinit();

    try req.send();
    try req.wait();

    if (req.response.status != .ok) {
        return error.HttpRequestFailed;
    }

    const body = try req.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(body);

    const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer parsed.deinit();

    const commit_date_str = parsed.value.object.get("commit").?.object.get("committer").?.object.get("date").?.string;
    return try utils.parseReleaseTimestamp(commit_date_str);
}

fn compareReleasesByDate(context: void, a: Release, b: Release) bool {
    _ = context;
    return a.published_at > b.published_at;
}

fn checkForInaccessibleRepos(allocator: Allocator, client: *http.Client, token: []const u8, starred_repos: [][]const u8) !void {
    const is_test = @import("builtin").is_test;
    if (is_test) return; // Skip in tests

    // List of repositories that are commonly affected by enterprise policies
    const problematic_repos = [_][]const u8{
        "aws/language-server-runtimes",
        "aws/aws-cli",
        "aws/aws-sdk-js",
        "aws/aws-cdk",
    };

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth_header);

    for (problematic_repos) |repo| {
        // Check if this repo is in our starred list
        var found_in_starred = false;
        for (starred_repos) |starred_repo| {
            if (std.mem.eql(u8, starred_repo, repo)) {
                found_in_starred = true;
                break;
            }
        }

        if (!found_in_starred) {
            // Check if we can access this repository directly to see if it's a policy issue
            const check_url = try std.fmt.allocPrint(allocator, "https://api.github.com/user/starred/{s}", .{repo});
            defer allocator.free(check_url);

            const uri = std.Uri.parse(check_url) catch continue;

            var server_header_buffer: [16 * 1024]u8 = undefined;
            var req = client.open(.GET, uri, .{
                .server_header_buffer = &server_header_buffer,
                .extra_headers = &.{
                    .{ .name = "Authorization", .value = auth_header },
                    .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
                    .{ .name = "User-Agent", .value = "release-tracker/1.0" },
                },
            }) catch continue;
            defer req.deinit();

            req.send() catch continue;
            req.wait() catch continue;

            if (req.response.status == .forbidden) {
                // Try to read the error response for more details
                const error_body = req.reader().readAllAlloc(allocator, 4096) catch "";
                defer if (error_body.len > 0) allocator.free(error_body);

                const stderr = std.io.getStdErr().writer();
                if (std.mem.indexOf(u8, error_body, "enterprise") != null or
                    std.mem.indexOf(u8, error_body, "personal access token") != null or
                    std.mem.indexOf(u8, error_body, "fine-grained") != null)
                {
                    stderr.print("GitHub: Repository '{s}' may be starred but is inaccessible due to enterprise policies: {s}\n", .{ repo, error_body }) catch {};
                } else {
                    stderr.print("GitHub: Repository '{s}' is not accessible (HTTP 403): {s}\n", .{ repo, error_body }) catch {};
                }
            }
        }
    }
}

test "github provider" {
    const allocator = std.testing.allocator;

    var github_provider = init("");

    // Test with empty token (should fail gracefully)
    const releases = github_provider.fetchReleases(allocator) catch |err| {
        try std.testing.expect(err == error.HttpRequestFailed);
        return;
    };
    defer {
        for (releases.items) |release| {
            release.deinit(allocator);
        }
        releases.deinit();
    }

    try std.testing.expectEqualStrings("github", github_provider.getName());
}

test "github release parsing with live data snapshot" {
    const allocator = std.testing.allocator;

    // Sample GitHub API response for releases (captured from real API)
    const sample_response =
        \\[
        \\  {
        \\    "tag_name": "v1.2.0",
        \\    "published_at": "2024-01-15T10:30:00Z",
        \\    "html_url": "https://github.com/example/repo/releases/tag/v1.2.0",
        \\    "body": "Bug fixes and improvements"
        \\  },
        \\  {
        \\    "tag_name": "v1.1.0",
        \\    "published_at": "2024-01-10T08:15:00Z",
        \\    "html_url": "https://github.com/example/repo/releases/tag/v1.1.0",
        \\    "body": "New features added"
        \\  },
        \\  {
        \\    "tag_name": "v1.0.0",
        \\    "published_at": "2024-01-01T00:00:00Z",
        \\    "html_url": "https://github.com/example/repo/releases/tag/v1.0.0",
        \\    "body": "Initial release"
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

        const body_value = obj.get("body") orelse json.Value{ .string = "" };
        const body_str = if (body_value == .string) body_value.string else "";

        const release = Release{
            .repo_name = try allocator.dupe(u8, "example/repo"),
            .tag_name = try allocator.dupe(u8, obj.get("tag_name").?.string),
            .published_at = try utils.parseReleaseTimestamp(obj.get("published_at").?.string),
            .html_url = try allocator.dupe(u8, obj.get("html_url").?.string),
            .description = try allocator.dupe(u8, body_str),
            .provider = try allocator.dupe(u8, "github"),
            .is_tag = false,
        };

        try releases.append(release);
    }

    // Sort releases by date (most recent first)
    std.mem.sort(Release, releases.items, {}, compareReleasesByDate);

    // Verify parsing and sorting
    try std.testing.expectEqual(@as(usize, 3), releases.items.len);
    try std.testing.expectEqualStrings("v1.2.0", releases.items[0].tag_name);
    try std.testing.expectEqualStrings("v1.1.0", releases.items[1].tag_name);
    try std.testing.expectEqualStrings("v1.0.0", releases.items[2].tag_name);
    try std.testing.expectEqual(
        @as(i64, @intCast(@divTrunc(
            (try @import("zeit").instant(.{ .source = .{ .iso8601 = "2024-01-15T10:30:00Z" } })).timestamp,
            std.time.ns_per_s,
        ))),
        releases.items[0].published_at,
    );
    try std.testing.expectEqualStrings("github", releases.items[0].provider);
}

test "addNonReleaseTags should not add duplicate tags" {
    const allocator = std.testing.allocator;

    // Create initial releases array with one existing release
    var releases = ArrayList(Release).init(allocator);
    defer {
        for (releases.items) |release| release.deinit(allocator);
        releases.deinit();
    }

    const existing_release = Release{
        .repo_name = try allocator.dupe(u8, "pkgforge-dev/Cromite-AppImage"),
        .tag_name = try allocator.dupe(u8, "v138.0.7204.97@2025-07-19_1752905672"),
        .published_at = 1721404800,
        .html_url = try allocator.dupe(u8, "https://github.com/pkgforge-dev/Cromite-AppImage/releases/tag/v138.0.7204.97@2025-07-19_1752905672"),
        .description = try allocator.dupe(u8, ""),
        .provider = try allocator.dupe(u8, "github"),
        .is_tag = false,
    };
    try releases.append(existing_release);

    // Create a tag that duplicates the existing release (should NOT be added)
    const duplicate_tag = Release{
        .repo_name = try allocator.dupe(u8, "pkgforge-dev/Cromite-AppImage"),
        .tag_name = try allocator.dupe(u8, "v138.0.7204.97@2025-07-19_1752905672"),
        .published_at = 1721404800,
        .html_url = try allocator.dupe(u8, "https://github.com/pkgforge-dev/Cromite-AppImage/releases/tag/v138.0.7204.97@2025-07-19_1752905672"),
        .description = try allocator.dupe(u8, ""),
        .provider = try allocator.dupe(u8, "github"),
        .is_tag = true,
    };

    // Create a tag that should be added (unique)
    const unique_tag = Release{
        .repo_name = try allocator.dupe(u8, "pkgforge-dev/Cromite-AppImage"),
        .tag_name = try allocator.dupe(u8, "v137.0.7204.96@2025-07-18_1752905671"),
        .published_at = 1721318400,
        .html_url = try allocator.dupe(u8, "https://github.com/pkgforge-dev/Cromite-AppImage/releases/tag/v137.0.7204.96@2025-07-18_1752905671"),
        .description = try allocator.dupe(u8, ""),
        .provider = try allocator.dupe(u8, "github"),
        .is_tag = true,
    };

    // Array of tags to process
    const all_tags = [_]Release{ duplicate_tag, unique_tag };

    // Add non-duplicate tags to releases
    const added = try addNonReleaseTags(allocator, &releases, &all_tags);
    try std.testing.expectEqual(@as(usize, 1), added);

    // Should have 2 releases total: 1 original + 1 unique tag (duplicate should be ignored)
    try std.testing.expectEqual(@as(usize, 2), releases.items.len);

    // Verify the unique tag was added
    var found_unique = false;
    for (releases.items) |release| {
        if (std.mem.eql(u8, release.tag_name, "v137.0.7204.96@2025-07-18_1752905671")) {
            found_unique = true;
            try std.testing.expectEqual(true, release.is_tag);
            break;
        }
    }
    try std.testing.expect(found_unique);
}

test "parse tag graphQL output" {
    const result =
        \\{"data":{"repository":{"refs":{"pageInfo":{"hasNextPage":false,"endCursor":"MzY"},"nodes":[{"name":"v0.7.9","target":{"committedDate":"2025-07-16T06:14:23Z","message":"chore: bump version to v0.7.9"}},{"name":"v0.7.8","target":{"committedDate":"2025-07-15T23:01:11Z","message":"chore: bump version to v0.7.8"}},{"name":"v0.7.7","target":{"committedDate":"2025-04-16T02:32:43Z","message":"chore: bump version to v0.7.0"}},{"name":"v0.7.6","target":{"committedDate":"2025-04-13T18:00:14Z","message":"chore: bump version to v0.7.6"}},{"name":"v0.7.5","target":{"committedDate":"2025-04-12T20:31:13Z","message":"chore: bump version to v0.7.5"}},{"name":"v0.7.4","target":{"committedDate":"2025-04-06T02:08:45Z","message":"chore: bump version to v0.7.4"}},{"name":"v0.3.6","target":{"committedDate":"2024-12-20T07:25:36Z","message":"chore: bump version to v3.4.6"}},{"name":"v0.1.0","target":{"committedDate":"2024-11-16T23:19:14Z","message":"chore: bump version to v0.1.0"}}]}}}}
    ;
    const allocator = std.testing.allocator;
    var cursor: ?[]const u8 = null;
    var tags = ArrayList(Release).init(allocator);
    defer {
        for (tags.items) |tag| {
            tag.deinit(allocator);
        }
        tags.deinit();
    }

    const has_next_page = try parseGraphQL(allocator, "DonIsaac/zlint", result, &cursor, &tags);

    // Verify parsing results
    try std.testing.expectEqual(false, has_next_page);
    try std.testing.expectEqual(@as(usize, 8), tags.items.len);

    // Check first tag (most recent)
    try std.testing.expectEqualStrings("v0.7.9", tags.items[0].tag_name);
    try std.testing.expectEqualStrings("DonIsaac/zlint", tags.items[0].repo_name);
    try std.testing.expectEqualStrings("chore: bump version to v0.7.9", tags.items[0].description);
    try std.testing.expectEqualStrings("https://github.com/DonIsaac/zlint/releases/tag/v0.7.9", tags.items[0].html_url);
    try std.testing.expectEqualStrings("github", tags.items[0].provider);
    try std.testing.expectEqual(true, tags.items[0].is_tag);

    // Check last tag
    try std.testing.expectEqualStrings("v0.1.0", tags.items[7].tag_name);
    try std.testing.expectEqualStrings("chore: bump version to v0.1.0", tags.items[7].description);

    // Verify that commit messages are properly extracted
    try std.testing.expectEqualStrings("chore: bump version to v0.7.8", tags.items[1].description);
    try std.testing.expectEqualStrings("chore: bump version to v3.4.6", tags.items[6].description); // Note: this one has a typo in the original data
}
