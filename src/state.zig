const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

pub const ProviderState = struct {
    last_check: i64,
};

pub const AppState = struct {
    github: ProviderState,
    gitlab: ProviderState,
    codeberg: ProviderState,
    sourcehut: ProviderState,

    allocator: Allocator,

    pub fn init(allocator: Allocator) AppState {
        return AppState{
            .github = ProviderState{ .last_check = 0 },
            .gitlab = ProviderState{ .last_check = 0 },
            .codeberg = ProviderState{ .last_check = 0 },
            .sourcehut = ProviderState{ .last_check = 0 },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const AppState) void {
        _ = self;
        // Nothing to clean up for now
    }

    pub fn getProviderState(self: *AppState, provider_name: []const u8) *ProviderState {
        if (std.mem.eql(u8, provider_name, "github")) return &self.github;
        if (std.mem.eql(u8, provider_name, "gitlab")) return &self.gitlab;
        if (std.mem.eql(u8, provider_name, "codeberg")) return &self.codeberg;
        if (std.mem.eql(u8, provider_name, "sourcehut")) return &self.sourcehut;
        unreachable;
    }
};

pub fn loadState(allocator: Allocator, path: []const u8) !AppState {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("State file not found, creating default state at {s}\n", .{path});
            const default_state = AppState.init(allocator);
            try saveState(default_state, path);
            return default_state;
        },
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const parsed = try json.parseFromSlice(json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    var state = AppState.init(allocator);

    if (root.get("github")) |github_obj| {
        if (github_obj.object.get("last_check")) |last_check| {
            state.github.last_check = last_check.integer;
        }
    }

    if (root.get("gitlab")) |gitlab_obj| {
        if (gitlab_obj.object.get("last_check")) |last_check| {
            state.gitlab.last_check = last_check.integer;
        }
    }

    if (root.get("codeberg")) |codeberg_obj| {
        if (codeberg_obj.object.get("last_check")) |last_check| {
            state.codeberg.last_check = last_check.integer;
        }
    }

    if (root.get("sourcehut")) |sourcehut_obj| {
        if (sourcehut_obj.object.get("last_check")) |last_check| {
            state.sourcehut.last_check = last_check.integer;
        }
    }

    return state;
}

pub fn saveState(state: AppState, path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var string = std.ArrayList(u8).init(state.allocator);
    defer string.deinit();

    // Create JSON object
    var obj = std.json.ObjectMap.init(state.allocator);
    defer obj.deinit();

    // GitHub state
    var github_obj = std.json.ObjectMap.init(state.allocator);
    defer github_obj.deinit();
    try github_obj.put("last_check", json.Value{ .integer = state.github.last_check });
    try obj.put("github", json.Value{ .object = github_obj });

    // GitLab state
    var gitlab_obj = std.json.ObjectMap.init(state.allocator);
    defer gitlab_obj.deinit();
    try gitlab_obj.put("last_check", json.Value{ .integer = state.gitlab.last_check });
    try obj.put("gitlab", json.Value{ .object = gitlab_obj });

    // Codeberg state
    var codeberg_obj = std.json.ObjectMap.init(state.allocator);
    defer codeberg_obj.deinit();
    try codeberg_obj.put("last_check", json.Value{ .integer = state.codeberg.last_check });
    try obj.put("codeberg", json.Value{ .object = codeberg_obj });

    // SourceHut state
    var sourcehut_obj = std.json.ObjectMap.init(state.allocator);
    defer sourcehut_obj.deinit();
    try sourcehut_obj.put("last_check", json.Value{ .integer = state.sourcehut.last_check });
    try obj.put("sourcehut", json.Value{ .object = sourcehut_obj });

    try std.json.stringify(json.Value{ .object = obj }, .{ .whitespace = .indent_2 }, string.writer());
    try file.writeAll(string.items);
}

test "state management" {
    const allocator = std.testing.allocator;

    var state = AppState.init(allocator);
    defer state.deinit();

    // Test provider state access
    const github_state = state.getProviderState("github");
    github_state.last_check = 12345;

    try std.testing.expect(state.github.last_check == 12345);
}
