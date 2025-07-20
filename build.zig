const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const integration = b.option(bool, "integration", "Run integration tests") orelse false;
    const provider = b.option([]const u8, "provider", "Test specific provider (github, gitlab, forgejo, sourcehut)");
    const test_debug = b.option(bool, "test-debug", "Enable debug output in tests") orelse false;

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

    const test_debug_option = b.addOptions();
    test_debug_option.addOption(bool, "test_debug", test_debug);
    unit_tests.root_module.addOptions("build_options", test_debug_option);

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

        const integration_test_debug_option = b.addOptions();
        integration_test_debug_option.addOption(bool, "test_debug", test_debug);
        integration_tests.root_module.addOptions("build_options", integration_test_debug_option);

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
    const forgejo_step = b.step("test-forgejo", "Test Forgejo provider only");
    const sourcehut_step = b.step("test-sourcehut", "Test SourceHut provider only");

    const github_tests = b.addTest(.{
        .name = "github-tests",
        .root_source_file = b.path("src/integration_tests.zig"),
        .target = target,
        .optimize = optimize,
        .filters = &[_][]const u8{"GitHub provider"},
    });
    github_tests.root_module.addImport("zeit", zeit_dep.module("zeit"));
    const github_test_debug_option = b.addOptions();
    github_test_debug_option.addOption(bool, "test_debug", test_debug);
    github_tests.root_module.addOptions("build_options", github_test_debug_option);

    const gitlab_tests = b.addTest(.{
        .name = "gitlab-tests",
        .root_source_file = b.path("src/integration_tests.zig"),
        .target = target,
        .optimize = optimize,
        .filters = &[_][]const u8{"GitLab provider"},
    });
    gitlab_tests.root_module.addImport("zeit", zeit_dep.module("zeit"));
    const gitlab_test_debug_option = b.addOptions();
    gitlab_test_debug_option.addOption(bool, "test_debug", test_debug);
    gitlab_tests.root_module.addOptions("build_options", gitlab_test_debug_option);

    const forgejo_tests = b.addTest(.{
        .name = "forgejo-tests",
        .root_source_file = b.path("src/integration_tests.zig"),
        .target = target,
        .optimize = optimize,
        .filters = &[_][]const u8{"Forgejo provider"},
    });
    forgejo_tests.root_module.addImport("zeit", zeit_dep.module("zeit"));
    const forgejo_test_debug_option = b.addOptions();
    forgejo_test_debug_option.addOption(bool, "test_debug", test_debug);
    forgejo_tests.root_module.addOptions("build_options", forgejo_test_debug_option);

    const sourcehut_tests = b.addTest(.{
        .name = "sourcehut-tests",
        .root_source_file = b.path("src/integration_tests.zig"),
        .target = target,
        .optimize = optimize,
        .filters = &[_][]const u8{"SourceHut provider"},
    });
    sourcehut_tests.root_module.addImport("zeit", zeit_dep.module("zeit"));
    const sourcehut_test_debug_option = b.addOptions();
    sourcehut_test_debug_option.addOption(bool, "test_debug", test_debug);
    sourcehut_tests.root_module.addOptions("build_options", sourcehut_test_debug_option);

    github_step.dependOn(&b.addRunArtifact(github_tests).step);
    gitlab_step.dependOn(&b.addRunArtifact(gitlab_tests).step);
    forgejo_step.dependOn(&b.addRunArtifact(forgejo_tests).step);
    sourcehut_step.dependOn(&b.addRunArtifact(sourcehut_tests).step);
}
