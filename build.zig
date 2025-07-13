const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const integration = b.option(bool, "integration", "Run integration tests") orelse false;
    const provider = b.option([]const u8, "provider", "Test specific provider (github, gitlab, codeberg, sourcehut)");

    // Add Zeit dependency
    const zeit_dep = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "release-tracker",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zeit", zeit_dep.module("zeit"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    unit_tests.root_module.addImport("zeit", zeit_dep.module("zeit"));

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests
    if (integration) {
        const integration_tests = b.addTest(.{
            .name = "integration-tests",
            .root_source_file = b.path("src/integration_tests.zig"),
            .target = target,
            .optimize = optimize,
        });

        integration_tests.root_module.addImport("zeit", zeit_dep.module("zeit"));

        // Add filter for specific provider if specified
        if (provider) |p| {
            const filter = std.fmt.allocPrint(b.allocator, "{s} provider", .{p}) catch @panic("OOM");
            integration_tests.filters = &[_][]const u8{filter};
        }

        const run_integration_tests = b.addRunArtifact(integration_tests);
        test_step.dependOn(&run_integration_tests.step);
    }

    // Individual provider test steps
    const github_step = b.step("test-github", "Test GitHub provider only");
    const gitlab_step = b.step("test-gitlab", "Test GitLab provider only");
    const codeberg_step = b.step("test-codeberg", "Test Codeberg provider only");
    const sourcehut_step = b.step("test-sourcehut", "Test SourceHut provider only");

    const github_tests = b.addTest(.{
        .name = "github-tests",
        .root_source_file = b.path("src/integration_tests.zig"),
        .target = target,
        .optimize = optimize,
        .filters = &[_][]const u8{"GitHub provider"},
    });
    github_tests.root_module.addImport("zeit", zeit_dep.module("zeit"));

    const gitlab_tests = b.addTest(.{
        .name = "gitlab-tests",
        .root_source_file = b.path("src/integration_tests.zig"),
        .target = target,
        .optimize = optimize,
        .filters = &[_][]const u8{"GitLab provider"},
    });
    gitlab_tests.root_module.addImport("zeit", zeit_dep.module("zeit"));

    const codeberg_tests = b.addTest(.{
        .name = "codeberg-tests",
        .root_source_file = b.path("src/integration_tests.zig"),
        .target = target,
        .optimize = optimize,
        .filters = &[_][]const u8{"Codeberg provider"},
    });
    codeberg_tests.root_module.addImport("zeit", zeit_dep.module("zeit"));

    const sourcehut_tests = b.addTest(.{
        .name = "sourcehut-tests",
        .root_source_file = b.path("src/integration_tests.zig"),
        .target = target,
        .optimize = optimize,
        .filters = &[_][]const u8{"SourceHut provider"},
    });
    sourcehut_tests.root_module.addImport("zeit", zeit_dep.module("zeit"));

    github_step.dependOn(&b.addRunArtifact(github_tests).step);
    gitlab_step.dependOn(&b.addRunArtifact(gitlab_tests).step);
    codeberg_step.dependOn(&b.addRunArtifact(codeberg_tests).step);
    sourcehut_step.dependOn(&b.addRunArtifact(sourcehut_tests).step);
}
