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

const RepoFetchTask = struct {
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

    if (starred_repos.items.len == 0) {
        return releases;
    }

    const starred_duration: u64 = @intCast(starred_end_time - starred_start_time);
    std.log.debug("GitHub: Found {} starred repositories in {}ms", .{ starred_repos.items.len, starred_duration });
    std.log.debug("GitHub: Processing {} starred repositories with thread pool...", .{starred_repos.items.len});

    const thread_start_time = std.time.milliTimestamp();

    // Create thread pool - use reasonable number of threads for API calls
    const thread_count = @min(@max(std.Thread.getCpuCount() catch 4, 8), 20);
    var thread_pool: Thread.Pool = undefined;
    try thread_pool.init(.{ .allocator = allocator, .n_jobs = thread_count });
    defer thread_pool.deinit();

    // Create tasks for each repository
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
    for (tasks) |*task| {
        thread_pool.spawnWg(&wait_group, fetchRepoReleasesTask, .{task});
    }

    // Wait for all tasks to complete
    thread_pool.waitAndWork(&wait_group);

    const thread_end_time = std.time.milliTimestamp();

    // Collect results from all tasks
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

    const total_end_time = std.time.milliTimestamp();
    const thread_duration: u64 = @intCast(thread_end_time - thread_start_time);
    const total_duration: u64 = @intCast(total_end_time - total_start_time);
    std.log.debug("GitHub: Thread pool completed in {}ms using {} threads ({} successful, {} failed)\n", .{ thread_duration, thread_count, successful_repos, failed_repos });
    std.log.debug("GitHub: Total time (including pagination): {}ms\n", .{total_duration});

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
        task.error_msg = std.fmt.allocPrint(task.allocator, "{}", .{err}) catch "Unknown error";
        return;
    };

    task.result = repo_releases;
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
        };

        try releases.append(release);
    }

    return releases;
}

fn compareReleasesByDate(context: void, a: Release, b: Release) bool {
    _ = context;
    return a.published_at > b.published_at;
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
    try std.testing.expectEqual(try @import("zeit").instant(.{ .source = .{ .iso8601 = "2024-01-15T10:30:00Z" } }), releases.items[0].published_at);
    try std.testing.expectEqualStrings("github", releases.items[0].provider);
}
