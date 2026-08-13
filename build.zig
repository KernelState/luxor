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
        "enable Context.zig, disabling this removes the dependency on harfbuzz and freetype2",
    ) orelse true;
    const images = b.option(
        bool,
        "images",
        "enable image decoding (png/jpeg/webp/svg) and the image widgets; links libpng, libjpeg, libwebp and vendored nanosvg",
    ) orelse true;

    // Per-layout / per-context capacity knobs. `Inner` (requests/children per
    // container), `Max` (packed layout scratch) and the element `pool` default
    // to the library's baseline; raise them to lay out more elements at once.
    // The un-defaulted option is kept (`*_opt`) so the stress executable can
    // inherit the runner's explicit choice instead of forcing its own defaults.
    const layout_inner_opt = b.option(
        usize,
        "layout-inner",
        "Per-layout child/request capacity (Layout.Inner)",
    );
    const layout_max_opt = b.option(
        usize,
        "layout-max",
        "Packed layout scratch size (Layout.Max)",
    );
    const element_pool_opt = b.option(
        usize,
        "element-pool",
        "Context element pool size (Context.PoolN)",
    );

    const layout_inner = layout_inner_opt orelse 200;
    const layout_max = layout_max_opt orelse 1000;
    const element_pool = element_pool_opt orelse 512;

    // The stress executable builds against its own luxor module so its
    // capacities can be much larger than the library's baseline without
    // ballooning every app's Context. It only defaults up (1600/1600/2048,
    // sized for the 1500-element screen the example renders) when the runner
    // picked no capacity at all; an explicit -Dlayout-* or -Dstress-* wins.
    const stress_inner = b.option(
        usize,
        "stress-inner",
        "Per-layout child/request capacity for the stress example (defaults to -Dlayout-inner, or 1600 in stress mode)",
    ) orelse layout_inner_opt orelse 1600;
    const stress_max = b.option(
        usize,
        "stress-max",
        "Packed layout scratch size for the stress example (defaults to -Dlayout-max, or 1600 in stress mode)",
    ) orelse layout_max_opt orelse 1600;
    const stress_pool = b.option(
        usize,
        "stress-pool",
        "Element pool size for the stress example (defaults to -Delement-pool, or 2048 in stress mode)",
    ) orelse element_pool_opt orelse 2048;

    // Batch queue sizes for the window's primitive queue. Raised from the old
    // hardcoded values so a big flex scene (thousands of rounded rects merged
    // into one run) fits in a single flush instead of overflowing mid-frame.
    const batch_verts = b.option(
        usize,
        "batch-verts",
        "Window primitive batch vertex capacity",
    ) orelse 65536;
    const batch_idx = b.option(
        usize,
        "batch-idx",
        "Window primitive batch index capacity",
    ) orelse 262144;
    const batch_prims = b.option(
        usize,
        "batch-prims",
        "Window primitive batch run capacity",
    ) orelse 16384;

    const sdl = b.dependency("zsdl3", .{
        .sdl_image = false,
        .sdl_mixer = false,
        .sdl_ttf = false,
    }).module("zsdl3");

    const lib_caps = Caps{
        .sdl = use_sdl,
        .widgets = widgets,
        .images = images,
        .inner = layout_inner,
        .max = layout_max,
        .pool = element_pool,
        .batch_verts = batch_verts,
        .batch_idx = batch_idx,
        .batch_prims = batch_prims,
    };

    const lib = b.addLibrary(.{
        .name = "luxor",
        .root_module = makeLuxorModule(b, target, optimize, sdl, lib_caps),
        .use_llvm = true,
    });

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

    const hr = b.addExecutable(.{
        .name = "harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/harness.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "luxor", .module = lib.root_module }},
        }),
        .use_llvm = true,
    });
    b.installArtifact(hr);

    const itest = b.addExecutable(.{
        .name = "interaction_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/interaction_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "luxor", .module = lib.root_module },
                .{ .name = "sdl", .module = sdl },
            },
        }),
        .use_llvm = true,
    });
    const itest_install = b.addInstallArtifact(itest, .{});
    b.getInstallStep().dependOn(&itest_install.step);

    const stress_caps = Caps{
        .sdl = use_sdl,
        .widgets = widgets,
        .images = images,
        .inner = stress_inner,
        .max = stress_max,
        .pool = stress_pool,
        .batch_verts = batch_verts,
        .batch_idx = batch_idx,
        .batch_prims = batch_prims,
    };
    const stress_luxor = makeLuxorModule(b, target, optimize, sdl, stress_caps);

    const stress = b.addExecutable(.{
        .name = "stress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/stress.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "luxor", .module = stress_luxor },
                .{ .name = "sdl", .module = sdl },
            },
        }),
        .use_llvm = true,
    });
    const stress_install = b.addInstallArtifact(stress, .{});
    b.getInstallStep().dependOn(&stress_install.step);
    const stress_run = b.addRunArtifact(stress);

    const stress_step = b.step("stress", "Build the flexbox stress test (one container packed to Layout.Inner children)");
    stress_step.dependOn(&stress_install.step);
    stress_step.dependOn(&stress_run.step);

    const run_stress_step = b.step("run-stress", "Run the flexbox stress test");
    const run_stress_cmd = b.addRunArtifact(stress);
    run_stress_step.dependOn(&stress_install.step);
    run_stress_step.dependOn(&run_stress_cmd.step);
    run_stress_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_stress_cmd.addArgs(args);
    }

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

/// Compile-time knobs for one luxor module instance, exposed to `src/luxor.zig`
/// (and friends) through its generated `options` module. Set `inner`/`max`/`pool`
/// to raise the per-container and element-pool capacities for that instance.
const Caps = struct {
    sdl: bool,
    widgets: bool,
    images: bool,
    inner: usize,
    max: usize,
    pool: usize,
    batch_verts: usize,
    batch_idx: usize,
    batch_prims: usize,
};

/// Builds a luxor module with the given `Caps`, wiring the vendored/system
/// dependencies that `sdl`/`widgets`/`images` enable. Callers can instantiate
/// this more than once to compile luxor with different capacities (the stress
/// example uses bigger ones without inflating the default Context).
fn makeLuxorModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdl: *std.Build.Module,
    caps: Caps,
) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "sdl", caps.sdl);
    options.addOption(bool, "widgets", caps.widgets);
    options.addOption(bool, "images", caps.images);
    options.addOption(usize, "inner", caps.inner);
    options.addOption(usize, "max", caps.max);
    options.addOption(usize, "pool", caps.pool);
    options.addOption(usize, "batch_verts", caps.batch_verts);
    options.addOption(usize, "batch_idx", caps.batch_idx);
    options.addOption(usize, "batch_prims", caps.batch_prims);

    const m = b.createModule(.{
        .root_source_file = b.path("src/luxor.zig"),
        .optimize = optimize,
        .target = target,
        .imports = &.{
            .{ .name = "options", .module = options.createModule() },
        },
    });

    if (caps.sdl) {
        m.addImport("sdl", sdl);
        m.linkSystemLibrary("SDL3", .{ .needed = true });
    }
    if (caps.widgets) {
        m.linkSystemLibrary("harfbuzz", .{});
        m.linkSystemLibrary("freetype2", .{});
        m.addIncludePath(b.path("vendor/harfbuzz/"));
        m.addIncludePath(b.path("vendor/freetype2/"));
    }
    if (caps.images) {
        m.addCSourceFile(.{ .file = b.path("vendor/luxor_c/image_shim.c"), .flags = &.{ "-std=c11" } });
        m.addCSourceFile(.{ .file = b.path("vendor/luxor_c/svg_shim.c"), .flags = &.{ "-std=c11" } });
        m.addIncludePath(b.path("vendor/luxor_c"));
        m.addIncludePath(b.path("vendor/nanosvg"));
        m.linkSystemLibrary("png", .{});
        m.linkSystemLibrary("jpeg", .{});
        m.linkSystemLibrary("webp", .{});
        m.linkSystemLibrary("m", .{});
    }
    return m;
}
