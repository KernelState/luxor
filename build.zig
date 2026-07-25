const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .dont_link_system_libs = true,
    });

    const lib = b.addLibrary(.{
        .name = "luxor",
        .root_module = b.addModule("luxor", .{
            .root_source_file = b.path("src/luxor.zig"),
            .optimize = optimize,
            .target = target,
        }),
        .use_llvm = true,
    });

    lib.root_module.addImport("sokol", dep_sokol.module("sokol"));
    lib.root_module.linkLibrary(dep_sokol.artifact("sokol_clib"));
    lib.root_module.linkSystemLibrary("asound", .{});
    lib.root_module.linkSystemLibrary("GL", .{});
    lib.root_module.linkSystemLibrary("X11", .{});
    lib.root_module.linkSystemLibrary("Xi", .{});
    lib.root_module.linkSystemLibrary("Xcursor", .{});

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/example.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "luxor", .module = lib.root_module },
                .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            },
        }),
        .use_llvm = true,
    });

    exe.root_module.linkLibrary(dep_sokol.artifact("sokol_clib"));
    exe.root_module.linkSystemLibrary("asound", .{});
    exe.root_module.linkSystemLibrary("GL", .{});
    exe.root_module.linkSystemLibrary("X11", .{});
    exe.root_module.linkSystemLibrary("Xi", .{});
    exe.root_module.linkSystemLibrary("Xcursor", .{});

    const exe_install = b.addInstallArtifact(exe, .{});

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&exe_install.step);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
