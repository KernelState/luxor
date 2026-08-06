const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_sdl = b.option(
        bool,
        "sdl",
        "Use sdl, disabling this removes Window.zig",
    ) orelse true;
    const widgets = b.option(
        bool,
        "widgets",
        "enable Widget.zig, disabling this removes the dependency on harfbuzz and freetype2",
    ) orelse true;
    const images = b.option(
        bool,
        "images",
        "enable image decoding (png/jpeg/webp/svg) and the image widgets; links libpng, libjpeg, libwebp and vendored nanosvg",
    ) orelse true;

    const sdl = b.dependency("zsdl3", .{
        .sdl_image = false,
        .sdl_mixer = false,
        .sdl_ttf = false,
    }).module("zsdl3");

    const options = b.addOptions();
    options.addOption(bool, "sdl", use_sdl);
    options.addOption(bool, "widgets", widgets);
    options.addOption(bool, "images", images);

    const lib = b.addLibrary(.{
        .name = "luxor",
        .root_module = b.addModule("luxor", .{
            .root_source_file = b.path("src/luxor.zig"),
            .optimize = optimize,
            .target = target,
            .imports = &.{
                .{ .name = "options", .module = options.createModule() },
            },
        }),
        .use_llvm = true,
    });

    if (use_sdl) {
        lib.root_module.addImport("sdl", sdl);
        lib.root_module.linkSystemLibrary("SDL3", .{ .needed = true });
    }
    if (widgets) {
        lib.root_module.linkSystemLibrary("harfbuzz", .{});
        lib.root_module.linkSystemLibrary("freetype2", .{});
        lib.root_module.addIncludePath(b.path("vendor/harfbuzz/"));
        lib.root_module.addIncludePath(b.path("vendor/freetype2/"));
    }
    if (images) {
        lib.root_module.addCSourceFile(.{ .file = b.path("vendor/luxor_c/image_shim.c"), .flags = &.{ "-std=c11" } });
        lib.root_module.addCSourceFile(.{ .file = b.path("vendor/luxor_c/svg_shim.c"), .flags = &.{ "-std=c11" } });
        lib.root_module.addIncludePath(b.path("vendor/luxor_c"));
        lib.root_module.addIncludePath(b.path("vendor/nanosvg"));
        lib.root_module.linkSystemLibrary("png", .{});
        lib.root_module.linkSystemLibrary("jpeg", .{});
        lib.root_module.linkSystemLibrary("webp", .{});
        lib.root_module.linkSystemLibrary("m", .{});
    }

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/example.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "luxor", .module = lib.root_module },
                .{ .name = "sdl", .module = sdl },
            },
        }),
        .use_llvm = true,
    });

    const exe_install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&exe_install.step);

    const lib_tests = b.addTest(.{
        .root_module = lib.root_module,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);

    const lib_test_step = b.step("libtest", "Run library-only tests");
    lib_test_step.dependOn(&run_lib_tests.step);

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
