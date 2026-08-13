const std = @import("std");
const lu = @import("luxor");
const sdl = @import("sdl");

/// This example packs a single flex container up to the maximum number of
/// children it is allowed to hold right now: `Layout.Inner` requests live in a
/// per-layout static array (`src/Layout.zig`), so 200 is the cap for one
/// container's `packFlex` / `buildLines` / `flexLay` path. `Layout.Max` (the
/// packed scratch) and the `Context` element pool (512) are both larger, so
/// `Inner` is the binding limit a stress test must hit.
const N = lu.LayoutInner;

var field_cfg = lu.Layout.FlexConfig{
    .direction = .row,
    .gap = 4,
    .wrap = true,
    .sizing = .{ .main = .fixed, .cross = .content },
};

// Root column fills the window and stacks the labels and the packed field.
var root_cfg = lu.Layout.FlexConfig{ .direction = .column, .gap = 12, .align_items = .flex_start };

const tile_colors = [_]u32{ 0xEE3344FF, 0xEE8855FF, 0xEECC33FF, 0x66CC55FF, 0x3399EEFF, 0x7744CCFF, 0xCC3388FF, 0x4488AAFF };

fn onKey(data: *anyopaque, key: lu.Key, down: bool) void {
    const quit: *bool = @ptrCast(@alignCast(data));
    if (down and key == .escape) quit.* = true;
}

pub fn main() !void {
    const ctx = try std.heap.page_allocator.create(lu.Context);
    @memset(std.mem.asBytes(ctx), 0);
    ctx.flags = .{};
    ctx.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    ctx.frame_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    ctx.freetype = try lu.Context.Freetype.init();
    ctx.leaf_layout = .{ .vtable = &lu.Layout.leaf, .parent = null };
    defer std.heap.page_allocator.destroy(ctx);
    defer ctx.freetype.deinit();
    defer ctx.arena.deinit();
    defer ctx.frame_arena.deinit();

    ctx.fonts[0] = try ctx.freetype.createFont(
        "/usr/share/fonts/TTF/IBMPlexSans-Regular.ttf",
        28,
    );
    ctx.font_count = 1;
    defer ctx.fonts[0].deinit();

    if (!sdl.init(sdl.SDL_INIT_VIDEO))
        return error.SDLInitFailed;
    defer sdl.quit();

    var window = try lu.Window.init(.{
        .min_size = .{ .w = 1200, .h = 800 },
        .title = "luxor flexbox stress",
        .transparent = false,
        .decorated = true,
    });
    defer window.deinit();
    window.plugCache(ctx);

    var quit = false;
    window.events.key = .{ .handle = .{ .fptrs = &.{.{ .data = &quit, .func = &onKey } } } };

    var status_buf: [128]u8 = undefined;
    const status = try std.fmt.bufPrint(&status_buf, "Luxor flexbox stress: {d} children in one container (Layout.Inner cap = {d})", .{ N, lu.LayoutInner });

    var dbg = window.debug();
    defer window.debugRelease();
    var frame: u64 = 0;
    var verified = false;
    while (true) {
        dbg.begin(.frame);
        dbg.begin(.events);
        window.update();
        dbg.end(.events);
        if (window.shouldQuit() or quit) return;

        dbg.begin(.build);
        ctx.clear();

        var root = lu.Element{
            .size = .{ .w = 1200, .h = 800 },
            .pos = .{ .x = 0, .y = 0 },
            .background = lu.Background.solid(lu.Color{ .r = 0xDC, .g = 0xE4, .b = 0xF0, .a = 0xFF }),
            .layout = .{ .vtable = &lu.Layout.flex, .parent = null, .data = &root_cfg },
            .ctx = ctx,
            .events = lu.Context.noEvents,
        };
        root.layout.?.element = &root;
        root.layout.?.start();

        _ = try ctx.label("Flexbox stress: one container packed to the maximum allowed children", .{}, .{ .size = 28, .color = .{ .r = 0x33, .g = 0x33, .b = 0x33, .a = 0xFF } }, @src());

        // The single flex container pushed to its cap: `N == Layout.Inner`
        // requests, rebuilding the pool every frame so the 200-pointer arrays
        // (requests, children, the packed scratch) are all written each frame.
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
        for (0..N) |i| {
            _ = ctx.box(.{ .w = 40, .h = 40 }, .{
                .id_extra = i,
                .background = .{ .base = .{ .solid = lu.Color.fromU32(tile_colors[i % tile_colors.len]) }, .effects = &.{} },
                .border_radius = .all(4),
            }, @src());
        }
        field.layout.?.end();

        _ = try ctx.label(status, .{}, .{ .size = 22, .color = .{ .r = 0x44, .g = 0x44, .b = 0x44, .a = 0xFF } }, @src());

        root.layout.?.end();
        dbg.end(.build);

        _ = sdl.renderClear(window.renderer);
        root.override(window.overrides());
        window.render(&root);
        dbg.begin(.present);
        _ = sdl.renderPresent(window.renderer);
        dbg.end(.present);
        dbg.end(.frame);

        // After the first render the tree is laid out; prove every child landed
        // inside the single flex container. A wrap field never drops children,
        // so this must hit the cap exactly.
        if (!verified) {
            verified = true;
            const laid = field.layout.?.cindex;
            if (laid == N) {
                std.debug.print("PASS: flexbox laid out {d}/{d} children in one container\n", .{ laid, N });
            } else {
                std.debug.print("FAIL: flexbox laid out {d}/{d} children (Layout.Inner cap = {d})\n", .{ laid, N, lu.LayoutInner });
                return error.LayoutCapacityMismatch;
            }
        }

        frame += 1;
        if (frame % lu.Debug.DebugInfo.HistoryWindow == 0) {
            dbg.print();
        }
    }
}