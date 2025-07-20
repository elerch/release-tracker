const std = @import("std");

/// Common tag filtering logic that can be used across all providers
pub fn shouldSkipTag(allocator: std.mem.Allocator, tag_name: []const u8) bool {
    // Check if tag name contains common moving patterns
    const tag_lower = std.ascii.allocLowerString(allocator, tag_name) catch return false;
    defer allocator.free(tag_lower);

    // First check if this looks like semantic versioning (v1.2.3-something or 1.2.3-something)
    // If it does, we should be more careful about filtering
    const is_semantic_versioning = isSemVer(tag_lower);

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

        // common slower channels, but without version information
        // they probably are not something we're interested in
        "release",
        "snapshot",
        "unstable",
        "experimental",
        "prerelease",
        "preview",
    };

    // Check for exact matches with moving tags
    for (moving_tags) |moving_tag|
        if (std.mem.eql(u8, tag_lower, moving_tag))
            return true;

    // Only filter standalone alpha/beta/rc if they're NOT part of semantic versioning
    if (!is_semantic_versioning) {
        const standalone_prerelease_tags = [_][]const u8{
            "alpha",
            "beta",
            "rc",
        };

        for (standalone_prerelease_tags) |tag|
            if (std.mem.eql(u8, tag_lower, tag))
                return true;
    } else {
        // For semantic versioning, be more conservative and filter out prerelease versions
        // since these are likely to be duplicates of releases that are already filtered
        // by the releases API prerelease flag
        if (containsPrereleaseIdentifier(tag_lower)) {
            return true;
        }
    }

    // Skip pre-release and development tags
    if (std.mem.startsWith(u8, tag_lower, "pre-") or
        std.mem.startsWith(u8, tag_lower, "dev-") or
        std.mem.startsWith(u8, tag_lower, "test-") or
        std.mem.startsWith(u8, tag_lower, "debug-"))
        return true;

    return false;
}

/// Check if a tag looks like semantic versioning
fn isSemVer(tag_lower: []const u8) bool {
    // Look for patterns like:
    // v1.2.3, v1.2.3-alpha.1, 1.2.3, 1.2.3-beta.2, etc.

    var start_idx: usize = 0;

    // Skip optional 'v' prefix
    if (tag_lower.len > 0 and tag_lower[0] == 'v') {
        start_idx = 1;
    }

    if (start_idx >= tag_lower.len) return false;

    // Look for pattern: number.number.number
    var dot_count: u8 = 0;
    var has_digit = false;

    for (tag_lower[start_idx..]) |c| {
        if (c >= '0' and c <= '9') {
            has_digit = true;
        } else if (c == '.') {
            if (!has_digit) return false; // dot without preceding digit
            dot_count += 1;
            has_digit = false;
            if (dot_count > 2) break; // we only care about major.minor.patch
        } else if (c == '-' or c == '+') {
            // This could be prerelease or build metadata
            break;
        } else {
            // Invalid character for semver
            return false;
        }
    }

    // Must have at least 2 dots (major.minor.patch) and end with a digit
    return dot_count >= 2 and has_digit;
}

/// Check if a semantic version contains prerelease identifiers
fn containsPrereleaseIdentifier(tag_lower: []const u8) bool {
    // Look for common prerelease identifiers in semantic versioning
    const prerelease_identifiers = [_][]const u8{
        "-alpha",
        "-beta",
        "-rc",
        "-pre",
    };

    for (prerelease_identifiers) |identifier| {
        if (std.mem.indexOf(u8, tag_lower, identifier) != null) {
            return true;
        }
    }

    // Note: We don't filter git-style version tags like v1.2.3-123-g1234567
    // These are development versions but may be useful to track
    // (e.g., kraftkit releases that should be included per user request)

    return false;
}

/// Check if a release should be filtered based on prerelease/draft status
pub fn shouldSkipRelease(is_prerelease: bool, is_draft: bool) bool {
    return is_prerelease or is_draft;
}

test "shouldSkipTag filters common moving tags" {
    const allocator = std.testing.allocator;

    // Test exact matches for moving tags
    const moving_tags = [_][]const u8{
        "latest",
        "tip",
        "continuous",
        "head",
        "main",
        "master",
        "trunk",
        "develop",
        "development",
        "dev",
        "nightly",
        "edge",
        "canary",
        "release",
        "snapshot",
        "unstable",
        "experimental",
        "prerelease",
        "preview",
    };

    for (moving_tags) |tag| {
        const should_skip = shouldSkipTag(allocator, tag);
        try std.testing.expect(should_skip);

        // Test case insensitive matching
        const upper_tag = try std.ascii.allocUpperString(allocator, tag);
        defer allocator.free(upper_tag);
        const should_skip_upper = shouldSkipTag(allocator, upper_tag);
        try std.testing.expect(should_skip_upper);
    }

    // Test standalone alpha/beta/rc (should be filtered)
    const standalone_prerelease = [_][]const u8{ "alpha", "beta", "rc" };
    for (standalone_prerelease) |tag| {
        try std.testing.expect(shouldSkipTag(allocator, tag));
    }
}

test "shouldSkipTag filters prefix patterns" {
    const allocator = std.testing.allocator;

    const prefix_patterns = [_][]const u8{
        "pre-release",
        "pre-1.0.0",
        "dev-branch",
        "dev-feature",
        "test-build",
        "test-123",
        "debug-version",
        "debug-info",
    };

    for (prefix_patterns) |tag| {
        const should_skip = shouldSkipTag(allocator, tag);
        try std.testing.expect(should_skip);
    }
}

test "shouldSkipTag allows valid version tags" {
    const allocator = std.testing.allocator;

    const valid_tags = [_][]const u8{
        "v1.0.0",
        "v2.1.3",
        "1.0.0",
        "2.1.3-stable",
        "v1.0.0-final",
        "release-1.0.0",
        "stable-v1.0.0",
        "v1.0.0-lts",
        "2023.1.0",
        // Note: Semantic versioning prerelease tags are now filtered to avoid duplicates
        // with the releases API, so they're not in this "valid" list anymore
    };

    for (valid_tags) |tag| {
        const should_skip = shouldSkipTag(allocator, tag);
        try std.testing.expect(!should_skip);
    }
}

test "shouldSkipRelease filters prerelease and draft" {
    // Test prerelease filtering
    try std.testing.expect(shouldSkipRelease(true, false));

    // Test draft filtering
    try std.testing.expect(shouldSkipRelease(false, true));

    // Test both prerelease and draft
    try std.testing.expect(shouldSkipRelease(true, true));

    // Test normal release
    try std.testing.expect(!shouldSkipRelease(false, false));
}

test "semantic versioning detection" {
    const allocator = std.testing.allocator;

    // Test that semantic versioning tags with alpha/beta/rc are now filtered
    // (to avoid duplicates with releases API)
    const semver_prerelease_tags = [_][]const u8{
        "v1.0.0-alpha.1",
        "v1.0.0-beta.2",
        "v1.0.0-rc.1",
        "1.0.0-alpha.1",
        "2.0.0-beta.1",
        "3.0.0-rc.1",
        "v5.5.0-rc1",
        "v0.5.0-alpha01",
        "v1.12.0-beta3",
        "v1.24.0-rc0",
    };

    for (semver_prerelease_tags) |tag| {
        const should_skip = shouldSkipTag(allocator, tag);
        try std.testing.expect(should_skip); // Now these should be filtered
    }

    // Test that git-style version tags are preserved (per user request for kraftkit)
    const git_style_tags = [_][]const u8{
        "v0.11.6-212-g74599361",
        "v1.2.3-45-g1234567",
        "v2.0.0-123-gabcdef0",
    };

    for (git_style_tags) |tag| {
        const should_skip = shouldSkipTag(allocator, tag);
        try std.testing.expect(!should_skip); // These should NOT be filtered
    }

    // Test that regular semantic versioning tags are preserved
    const regular_semver_tags = [_][]const u8{
        "v1.0.0",
        "v2.1.3",
        "1.0.0",
        "2.1.3",
        "v10.20.30",
    };

    for (regular_semver_tags) |tag| {
        const should_skip = shouldSkipTag(allocator, tag);
        try std.testing.expect(!should_skip);
    }

    // Test that standalone alpha/beta/rc are still filtered
    const standalone_tags = [_][]const u8{ "alpha", "beta", "rc", "ALPHA", "Beta", "RC" };
    for (standalone_tags) |tag| {
        const should_skip = shouldSkipTag(allocator, tag);
        try std.testing.expect(should_skip);
    }
}
