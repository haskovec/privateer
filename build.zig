const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SDL3 dependency
    const sdl_dep = b.dependency("sdl", .{
        .optimize = optimize,
        .target = target,
    });

    // Core engine module (library)
    const engine_mod = b.addModule("privateer", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    engine_mod.linkLibrary(sdl_dep.artifact("SDL3"));

    // Main game executable
    const exe = b.addExecutable(.{
        .name = "privateer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "privateer", .module = engine_mod },
            },
        }),
    });
    exe.root_module.linkLibrary(sdl_dep.artifact("SDL3"));
    b.installArtifact(exe);

    // Asset extraction CLI tool
    const extract_exe = b.addExecutable(.{
        .name = "privateer-extract",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/extract_cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "privateer", .module = engine_mod },
            },
        }),
    });
    b.installArtifact(extract_exe);

    // Run step
    const run_step = b.step("run", "Run the game");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Extract step
    const extract_step = b.step("extract", "Run the asset extraction tool");
    const extract_cmd = b.addRunArtifact(extract_exe);
    extract_step.dependOn(&extract_cmd.step);
    extract_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        extract_cmd.addArgs(args);
    }

    // Engine module tests
    const mod_tests = b.addTest(.{
        .root_module = engine_mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Executable tests
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Extract CLI tests
    const extract_tests = b.addTest(.{
        .root_module = extract_exe.root_module,
    });
    const run_extract_tests = b.addRunArtifact(extract_tests);

    // Test step runs all test suites
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_extract_tests.step);
}
