const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

pub const ForgejoInstance = struct {
    name: []const u8,
    base_url: []const u8,
    token: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *const ForgejoInstance) void {
        self.allocator.free(self.name);
        self.allocator.free(self.base_url);
        self.allocator.free(self.token);
    }
};

pub const ForgejoConfig = struct {
    instances: []ForgejoInstance,
    allocator: Allocator,

    pub fn deinit(self: *const ForgejoConfig) void {
        for (self.instances) |*instance| {
            instance.deinit();
        }
        self.allocator.free(self.instances);
    }
};

pub const SourceHutConfig = struct {
    token: ?[]const u8 = null,
    repositories: [][]const u8,
    allocator: Allocator,

    pub fn deinit(self: *const SourceHutConfig) void {
        if (self.token) |token| self.allocator.free(token);
        for (self.repositories) |repo| {
            self.allocator.free(repo);
        }
        self.allocator.free(self.repositories);
    }
};

pub const Config = struct {
    github_token: ?[]const u8 = null,
    gitlab_token: ?[]const u8 = null,
    codeberg_token: ?[]const u8 = null, // Legacy support
    forgejo: ?ForgejoConfig = null,
    sourcehut: ?SourceHutConfig = null,
    allocator: Allocator,

    pub fn deinit(self: *const Config) void {
        if (self.github_token) |token| self.allocator.free(token);
        if (self.gitlab_token) |token| self.allocator.free(token);
        if (self.codeberg_token) |token| self.allocator.free(token);
        if (self.forgejo) |*forgejo_config| forgejo_config.deinit();
        if (self.sourcehut) |*sh_config| sh_config.deinit();
    }
};

pub fn loadConfig(allocator: Allocator, path: []const u8) !Config {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const stderr = std.io.getStdErr().writer();
            stderr.print("Config file not found, creating default config at {s}\n", .{path}) catch {};
            try createDefaultConfig(path);
            return Config{ .allocator = allocator };
        },
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    return parseConfigFromJson(allocator, content);
}

pub fn parseConfigFromJson(allocator: Allocator, json_content: []const u8) !Config {
    const parsed = try json.parseFromSlice(json.Value, allocator, json_content, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    var sourcehut_config: ?SourceHutConfig = null;
    if (root.get("sourcehut")) |sh_obj| {
        const sh_object = sh_obj.object;
        const repos_array = sh_object.get("repositories").?.array;

        var repositories = try allocator.alloc([]const u8, repos_array.items.len);
        for (repos_array.items, 0..) |repo_item, i| {
            repositories[i] = try allocator.dupe(u8, repo_item.string);
        }

        sourcehut_config = SourceHutConfig{
            .token = if (sh_object.get("token")) |v| try allocator.dupe(u8, v.string) else null,
            .repositories = repositories,
            .allocator = allocator,
        };
    }

    // Parse forgejo instances
    var forgejo_config: ?ForgejoConfig = null;
    if (root.get("forgejo")) |forgejo_obj| {
        const forgejo_array = forgejo_obj.array;
        var instances = try allocator.alloc(ForgejoInstance, forgejo_array.items.len);

        for (forgejo_array.items, 0..) |instance_obj, i| {
            const instance = instance_obj.object;
            instances[i] = ForgejoInstance{
                .name = try allocator.dupe(u8, instance.get("name").?.string),
                .base_url = try allocator.dupe(u8, instance.get("base_url").?.string),
                .token = try allocator.dupe(u8, instance.get("token").?.string),
                .allocator = allocator,
            };
        }

        forgejo_config = ForgejoConfig{
            .instances = instances,
            .allocator = allocator,
        };
    }

    return Config{
        .github_token = if (root.get("github_token")) |v| switch (v) {
            .string => |s| if (s.len > 0) try allocator.dupe(u8, s) else null,
            .null => null,
            else => null,
        } else null,
        .gitlab_token = if (root.get("gitlab_token")) |v| switch (v) {
            .string => |s| if (s.len > 0) try allocator.dupe(u8, s) else null,
            .null => null,
            else => null,
        } else null,
        .codeberg_token = if (root.get("codeberg_token")) |v| switch (v) {
            .string => |s| if (s.len > 0) try allocator.dupe(u8, s) else null,
            .null => null,
            else => null,
        } else null,
        .forgejo = forgejo_config,
        .sourcehut = sourcehut_config,
        .allocator = allocator,
    };
}

fn createDefaultConfig(path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const default_config =
        \\{
        \\  "github_token": "",
        \\  "gitlab_token": "",
        \\  "codeberg_token": "",
        \\  "sourcehut": {
        \\    "repositories": []
        \\  }
        \\}
    ;

    try file.writeAll(default_config);
}

test "config loading" {
    const allocator = std.testing.allocator;

    // Test with non-existent file
    const config = loadConfig(allocator, "nonexistent.json") catch |err| {
        try std.testing.expect(err == error.FileNotFound or err == error.AccessDenied);
        return;
    };
    defer config.deinit();
}
