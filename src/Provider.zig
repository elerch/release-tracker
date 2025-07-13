const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Release = @import("main.zig").Release;

// Provider interface using vtable pattern similar to std.mem.Allocator
ptr: *anyopaque,
vtable: *const VTable,

const Provider = @This();

pub const VTable = struct {
    fetchReleases: *const fn (ptr: *anyopaque, allocator: Allocator) anyerror!ArrayList(Release),
    getName: *const fn (ptr: *anyopaque) []const u8,
};

/// Fetch releases from this provider
pub fn fetchReleases(self: Provider, allocator: Allocator) !ArrayList(Release) {
    return self.vtable.fetchReleases(self.ptr, allocator);
}

/// Get the name of this provider
pub fn getName(self: Provider) []const u8 {
    return self.vtable.getName(self.ptr);
}

/// Create a Provider from any type that implements the required methods
pub fn init(pointer: anytype) Provider {
    const Ptr = @TypeOf(pointer);
    const ptr_info = @typeInfo(Ptr);

    if (ptr_info != .pointer) @compileError("Provider.init expects a pointer");
    if (ptr_info.pointer.size != .one) @compileError("Provider.init expects a single-item pointer");

    const gen = struct {
        fn fetchReleasesImpl(ptr: *anyopaque, allocator: Allocator) anyerror!ArrayList(Release) {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return @call(.always_inline, ptr_info.pointer.child.fetchReleases, .{ self, allocator });
        }

        fn getNameImpl(ptr: *anyopaque) []const u8 {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return @call(.always_inline, ptr_info.pointer.child.getName, .{self});
        }

        const vtable = VTable{
            .fetchReleases = fetchReleasesImpl,
            .getName = getNameImpl,
        };
    };

    return Provider{
        .ptr = @ptrCast(pointer),
        .vtable = &gen.vtable,
    };
}

test "Provider interface" {
    const TestProvider = struct {
        name: []const u8,

        pub fn fetchReleases(self: *@This(), allocator: Allocator) !ArrayList(Release) {
            _ = self;
            return ArrayList(Release).init(allocator);
        }

        pub fn getName(self: *@This()) []const u8 {
            return self.name;
        }
    };

    var test_provider = TestProvider{ .name = "test" };
    const provider = Provider.init(&test_provider);

    const allocator = std.testing.allocator;
    const releases = try provider.fetchReleases(allocator);
    defer releases.deinit();

    try std.testing.expectEqualStrings("test", provider.getName());
}
