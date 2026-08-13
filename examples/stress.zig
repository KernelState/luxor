const std = @import("std");
const lu = @import("luxor");
const sdl = @import("sdl");

/// Renders this many children in a single, giant flex container at once. The
/// example is compiled against its own luxor module (`makeLuxorModule` in
/// `build.zig`) whose capacities follow the runner's `-Dlayout-*` (or explicit
/// `-Dstress-*`) values, defaulting to 1600/1600/2048 in stress mode — so
/// 1500 requests fit the per-container arrays (`Layout.Inner`), the packed
/// scratch (`Layout.Max`), the layout cache slots (`LayoutEntry.kids`), and the
/// element pool (`Context.PoolN`, which the text widgets consume two slots per
/// item for).
const RENDER = 1500;

/// Every 8th item is a text button ("W<i>") so the stress screen exercises
/// labels, rasterized text, wrapping and hit-testing, not just flat boxes.
const button_mod = 8;

const buttons_max = @divTrunc(RENDER - 1, button_mod) + 1;

comptime {
    if (RENDER > lu.LayoutInner)
        @compileError("stress: RENDER exceeds the per-container capacity (Layout.Inner); raise with -Dstress-inner");
    if (lu.LayoutMax < lu.LayoutInner)
        @compileError("stress: Layout.Max must be at least Layout.Inner");
    // One pool slot per box, two per text button (button + its rasterized
    // label child), two per on-screen label (label + text child).
    const needed = 4 + @as(usize, buttons_max) * 2 + (RENDER - buttons_max);
    if (needed > lu.PoolN)
        @compileError("stress: the element pool is too small; raise with -Dstress-pool");
}

var field_cfg = lu.Layout.FlexConfig{
    .direction = .row,
    .gap = 2,
    .wrap = true,
    .sizing = .{ .main = .fixed, .cross = .content },
};

// Root column fills the window and stacks the labels and the packed field.
var root_cfg = lu.Layout.FlexConfig{ .direction = .column, .gap = 10, .align_items = .flex_start };

const tile_colors = [_]u32{ 0xEE3344FF, 0xEE8855FF, 0xEECC33FF, 0x66CC55FF, 0x3399EEFF, 0x7744CCFF, 0xCC3388FF, 0x4488AAFF };

fn onKey(data: *anyopaque, key: lu.Key, down: bool) void {
    const quit: *bool = @ptrCast(@alignCast(data));
    if (down and key == .escape) quit.* = true;
}

pub fn main() !void {
    const ctx = try std.heap.page_allocator.create(lu.Context);
    @memset(std.mem.asBytes(ctx), 0);
    ctx.flags = .{};
    ctx.initAlloc();
    ctx.freetype = try lu.Context.Freetype.init();
    ctx.leaf_layout = .{ .vtable = &lu.Layout.leaf, .parent = null };
    defer std.heap.page_allocator.destroy(ctx);
    defer ctx.freetype.deinit();

    ctx.fonts[0] = try ctx.freetype.createFont(
        "/usr/share/fonts/TTF/IBMPlexSans-Regular.ttf",
        24,
    );
    ctx.font_count = 1;
    defer ctx.fonts[0].deinit();

    if (!sdl.init(sdl.SDL_INIT_VIDEO))
        return error.SDLInitFailed;
    defer sdl.quit();

    var window = try lu.Window.init(.{
        .min_size = .{ .w = 1400, .h = 900 },
        .title = "luxor flexbox stress",
        .transparent = false,
        .decorated = true,
    }, ctx);
    defer window.deinit();
    window.plugCache(ctx);

    // Toggle caches via environment so the profiler can compare their cost.
    // `LUXOR_NO_GPU_CACHE=1`, `LUXOR_NO_TEXT_CACHE=1`, `LUXOR_NO_IMAGE_CACHE=1`.
    applyFlags(ctx);

    std.debug.print("caps: layout-inner={d} layout-max={d} pool={d} | rendering {d} children in one flex container\n", .{ lu.LayoutInner, lu.LayoutMax, lu.PoolN, RENDER });

    var quit = false;
    window.events.key = .{ .handle = .{ .fptrs = &.{.{ .data = &quit, .func = &onKey }} } };

    // Text labels ride on every 8th item; format them once, not per frame.
    var button_labels: [buttons_max][8]u8 = undefined;
    for (0..buttons_max) |k| {
        const idx = k * button_mod;
        _ = std.fmt.bufPrint(&button_labels[k], "W{d}", .{idx}) catch unreachable;
    }

    var status_buf: [160]u8 = undefined;
    const status = try std.fmt.bufPrint(&status_buf, "Luxor flexbox stress: {d} children in ONE container (inner={d} max={d} pool={d})", .{ RENDER, lu.LayoutInner, lu.LayoutMax, lu.PoolN });

    // Local knob to shut the profiler (and its plugin output) right off: with
    // `false` the debugger is never activated, so every `ctx.dbg.*` call below
    // is an internal no-op (Context.dbg.active == false). Flip the library-wide
    // `lu.Debug.enabled` switch in src/Debug.zig to drop every profiler call
    // from the build entirely.
    const profile = true;
    ctx.dbg.enable(profile);
    var verified = false;
    while (true) {
        ctx.dbg.begin(.frame);
        ctx.dbg.begin(.events);
        window.update();
        ctx.dbg.end(.events);
        if (window.shouldQuit() or quit) return;

        ctx.dbg.begin(.build);
        ctx.clear();

        var root = lu.Element{
            .size = .{ .w = 1400, .h = 900 },
            .pos = .{ .x = 0, .y = 0 },
            .background = lu.Background.solid(lu.Color{ .r = 0xDC, .g = 0xE4, .b = 0xF0, .a = 0xFF }),
            .layout = .{ .vtable = &lu.Layout.flex, .parent = null, .data = &root_cfg },
            .ctx = ctx,
            .events = lu.Context.noEvents,
        };
        root.layout.?.element = &root;
        root.layout.?.start();

        _ = try ctx.label("Flexbox stress: 1500 elements, wrapped and laying out at once", .{}, .{ .size = 26, .color = .{ .r = 0x33, .g = 0x33, .b = 0x33, .a = 0xFF } }, @src());

        // The single flex container pushed past the old 200-child cap:
        // `RENDER` requests, rebuilt from the pool every frame so the whole
        // packing path (packFlex, buildLines, flexLay) runs at full size.
        var field = lu.Element{
            .size = .{ .w = 0, .h = 0 },
            .pos = .{ .x = 0, .y = 0 },
            .background = lu.Background.solid(.{ .r = 0, .g = 0, .b = 0, .a = 0 }),
            .layout = .{ .vtable = &lu.Layout.flex, .parent = &root.layout.?, .data = &field_cfg },
            .ctx = ctx,
            .events = lu.Context.noEvents,
        };
        _ = ctx.publishRequest(&field, .{ .min_size = .{ .w = 0, .h = 0 }, .align_self = .stretch });
        field.layout.?.start();

        // Custom-trace node: the whole 1500-request loop is one "adding
        // elements" span; the built-in example plugin averages/worsts it per
        // frame in the periodic report (see src/Debug.zig).
        ctx.dbg.beginCustom("adding elements");
        var bi: usize = 0;
        for (0..RENDER) |i| {
            if (i % button_mod == 0) {
                // A labelled button: text + padding makes the wrap rows uneven,
                // and every label is rasterized (and texture-cached) per item.
                _ = try ctx.button(button_labels[bi][0..], .{
                    .id_extra = i,
                }, .{
                    .label = .{ .size = 14, .color = .white },
                    .padding = .all(3),
                    .color = lu.Color.fromU32(tile_colors[(i / button_mod) % tile_colors.len]),
                    .radius = .all(4),
                    .min_size = .{ .w = 30, .h = 18 },
                }, @src());
                bi += 1;
            } else {
                // Vary the footprint so row breaks hit at different widths.
                const tw: u32 = 24 + @as(u32, @intCast(i % 3)) * 6;
                _ = ctx.box(.{ .w = tw, .h = tw }, .{
                    .id_extra = i,
                    .background = .{ .base = .{ .solid = lu.Color.fromU32(tile_colors[i % tile_colors.len]) }, .effects = &.{} },
                    .border_radius = .all(4),
                }, @src());
            }
        }
        ctx.dbg.endCustom("adding elements");

        ctx.dbg.beginCustom("ending layout");
        field.layout.?.end();
        ctx.dbg.endCustom("ending layout");

        _ = try ctx.label(status, .{}, .{ .size = 20, .color = .{ .r = 0x44, .g = 0x44, .b = 0x44, .a = 0xFF } }, @src());

        root.layout.?.end();
        ctx.dbg.end(.build);

        _ = sdl.renderClear(window.renderer);
        root.override(window.overrides());
        window.render(&root);
        ctx.dbg.begin(.present);
        _ = sdl.renderPresent(window.renderer);
        ctx.dbg.end(.present);
        ctx.dbg.end(.frame);

        // After the first render the tree is laid out; prove every child landed
        // inside the single flex container. A wrap field never drops children,
        // so this must hit the requested count exactly.
        if (!verified) {
            verified = true;
            const laid = field.layout.?.cindex;
            if (laid == RENDER) {
                std.debug.print("PASS: flexbox laid out {d}/{d} children in one container\n", .{ laid, RENDER });
            } else {
                std.debug.print("FAIL: flexbox laid out {d}/{d} children (Layout.Inner cap = {d})\n", .{ laid, RENDER, lu.LayoutInner });
                return error.LayoutCapacityMismatch;
            }
        }
    }
}

/// Turns the matching `Context` caches off when the `LUXOR_NO_{GPU,TEXT,IMAGE}_
/// CACHE` env vars are set, or all of them at once via `LUXOR_NO_CACHE` (any
/// non-empty value), so the profiler can measure the real rasterization/decode
/// cost (an anomaly report will reflect it).
fn applyFlags(ctx: *lu.Context) void {
    if (envSet("LUXOR_NO_CACHE")) {
        ctx.flags.gpu_cache = false;
        ctx.flags.text_cache = false;
        ctx.flags.image_cache = false;
        return;
    }
    if (envSet("LUXOR_NO_GPU_CACHE")) ctx.flags.gpu_cache = false;
    if (envSet("LUXOR_NO_TEXT_CACHE")) ctx.flags.text_cache = false;
    if (envSet("LUXOR_NO_IMAGE_CACHE")) ctx.flags.image_cache = false;
}

fn envSet(name: [*:0]const u8) bool {
    const v = std.c.getenv(name) orelse return false;
    return v[0] != 0;
}
