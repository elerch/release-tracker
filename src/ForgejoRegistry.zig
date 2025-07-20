const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const config = @import("config.zig");
const Forgejo = @import("providers/Forgejo.zig");
const Provider = @import("Provider.zig");

forgejo_instances: ArrayList(Forgejo),
allocator: Allocator,

const Self = @This();

pub fn init(allocator: Allocator, app_config: *const config.Config) !Self {
    var forgejo_instances = ArrayList(Forgejo).init(allocator);

    // Handle new forgejo array configuration
    if (app_config.forgejo) |forgejo_config| {
        for (forgejo_config.instances) |instance| {
            const forgejo_provider = Forgejo.init(instance.name, instance.base_url, instance.token);
            try forgejo_instances.append(forgejo_provider);
        }
    }

    // Handle legacy codeberg_token for backward compatibility
    if (app_config.codeberg_token) |token| {
        // Only add legacy if no forgejo instances were configured
        if (forgejo_instances.items.len > 0)
            return error.CodeBergTokenCannotBeProvidedWhenForgejoSet;

        const legacy_provider = Forgejo.init("codeberg", "https://codeberg.org", token);
        try forgejo_instances.append(legacy_provider);
    }

    return Self{
        .forgejo_instances = forgejo_instances,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.forgejo_instances.deinit();
}

pub fn providers(self: *Self) ![]Provider {
    const provider_list = try self.allocator.alloc(Provider, self.forgejo_instances.items.len);

    for (self.forgejo_instances.items, 0..) |*forgejo_instance, i| {
        provider_list[i] = forgejo_instance.provider();
    }

    return provider_list;
}

pub fn deinitProviders(self: *Self, provider_list: []Provider) void {
    self.allocator.free(provider_list);
}

test "ForgejoRegistry with new config format" {
    const allocator = std.testing.allocator;

    // Create test instances
    var instances = try allocator.alloc(config.ForgejoInstance, 2);
    defer allocator.free(instances);

    instances[0] = config.ForgejoInstance{
        .name = try allocator.dupe(u8, "codeberg"),
        .base_url = try allocator.dupe(u8, "https://codeberg.org"),
        .token = try allocator.dupe(u8, "test_token_1"),
        .allocator = allocator,
    };
    instances[1] = config.ForgejoInstance{
        .name = try allocator.dupe(u8, "company-forge"),
        .base_url = try allocator.dupe(u8, "https://git.company.com"),
        .token = try allocator.dupe(u8, "test_token_2"),
        .allocator = allocator,
    };

    // Create test config with forgejo instances
    const test_config = config.Config{
        .github_token = null,
        .gitlab_token = null,
        .codeberg_token = null,
        .forgejo = config.ForgejoConfig{
            .instances = instances,
            .allocator = allocator,
        },
        .sourcehut = null,
        .allocator = allocator,
    };
    defer {
        for (instances) |*instance| {
            instance.deinit();
        }
    }

    var registry = try Self.init(allocator, &test_config);
    defer registry.deinit();

    const provider_list = try registry.providers();
    defer registry.deinitProviders(provider_list);

    try std.testing.expect(provider_list.len == 2);
}

test "ForgejoRegistry with legacy config format" {
    const allocator = std.testing.allocator;

    // Create test config with legacy codeberg_token
    const test_config = config.Config{
        .github_token = null,
        .gitlab_token = null,
        .codeberg_token = try allocator.dupe(u8, "legacy_token"),
        .forgejo = null,
        .sourcehut = null,
        .allocator = allocator,
    };
    defer test_config.deinit();

    var registry = try Self.init(allocator, &test_config);
    defer registry.deinit();

    const provider_list = try registry.providers();
    defer registry.deinitProviders(provider_list);

    try std.testing.expect(provider_list.len == 1);
}
