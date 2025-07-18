const std = @import("std");
const zeit = @import("zeit");
const Release = @import("main.zig").Release;

/// Parse a timestamp string into Unix timestamp (seconds since epoch)
/// Handles both direct integer timestamps and ISO 8601 date strings
pub fn parseReleaseTimestamp(date_str: []const u8) !i64 {
    // Try parsing as direct timestamp first
    if (std.fmt.parseInt(i64, date_str, 10)) |timestamp| {
        return timestamp;
    } else |_| {
        // Try parsing as ISO 8601 format using Zeit
        const instant = zeit.instant(.{
            .source = .{ .iso8601 = date_str },
        }) catch |err| {
            if (!@import("builtin").is_test)
                std.log.err("Error parsing date_str: {s}", .{date_str});
            return err;
        };
        // Zeit returns nanoseconds, convert to seconds
        const seconds = @divTrunc(instant.timestamp, std.time.ns_per_s);
        return @intCast(seconds);
    }
}

test "parseReleaseTimestamp with various formats" {
    // Test ISO 8601 format
    const timestamp1 = try parseReleaseTimestamp("2024-01-01T00:00:00Z");
    try std.testing.expect(timestamp1 > 0);

    // Test direct timestamp
    const timestamp2 = try parseReleaseTimestamp("1704067200");
    try std.testing.expectEqual(@as(i64, 1704067200), timestamp2);

    // Test ISO format with milliseconds
    const timestamp3 = try parseReleaseTimestamp("2024-01-01T12:30:45.123Z");
    try std.testing.expect(timestamp3 > timestamp1);
}

pub fn compareReleasesByDate(context: void, a: Release, b: Release) bool {
    _ = context;
    return a.published_at > b.published_at; // Most recent first
}

test "compareReleasesByDate" {
    const release1 = Release{
        .repo_name = "test/repo1",
        .tag_name = "v1.0.0",
        .published_at = @intCast(@divTrunc(
            (try zeit.instant(.{ .source = .{ .iso8601 = "2024-01-01T00:00:00Z" } })).timestamp,
            std.time.ns_per_s,
        )),
        .html_url = "https://github.com/test/repo1/releases/tag/v1.0.0",
        .description = "First release",
        .provider = "github",
        .is_tag = false,
    };

    const release2 = Release{
        .repo_name = "test/repo2",
        .tag_name = "v2.0.0",
        .published_at = @intCast(@divTrunc(
            (try zeit.instant(.{ .source = .{ .iso8601 = "2024-01-02T00:00:00Z" } })).timestamp,
            std.time.ns_per_s,
        )),
        .html_url = "https://github.com/test/repo2/releases/tag/v2.0.0",
        .description = "Second release",
        .provider = "github",
        .is_tag = false,
    };

    // release2 should come before release1 (more recent first)
    try std.testing.expect(compareReleasesByDate({}, release2, release1));
    try std.testing.expect(!compareReleasesByDate({}, release1, release2));
}
