const std = @import("std");
const lu = @import("luxor");
const sdl = @import("sdl");

// Root column fills the window and lays everything top to bottom. It has no
// parent, so it is the root of the tree. Layouts are now embedded by value in
// the element that owns them, so the config is shared but each container gets
// its own layout instance.
var root_cfg = lu.Layout.FlexConfig{ .direction = .column, .gap = 12, .align_items = .flex_start };

// A wrap row that fills the parent's width (main = fixed) and takes its height
// from the wrapped content (cross = content).
var toolbar_cfg = lu.Layout.FlexConfig{ .direction = .row, .gap = 8, .wrap = true, .sizing = .{ .main = .fixed, .cross = .content } };

// A long list of buttons wrapped into rows. Like the toolbar it fills the
// window width and takes its height from the wrapped rows, but every button has
// an explicit min/max so it never shrinks below `min_size`, never grows past
// `max_size`, and never overflows: the surplus width in each row is handed to
// `grow` buttons only up to their `max_size`, and wrapping grows this row's
// height to fit the rows instead of letting them spill.
var button_field_cfg = lu.Layout.FlexConfig{ .direction = .row, .gap = 8, .wrap = true, .sizing = .{ .main = .fixed, .cross = .content } };

// Sizes itself to its children's cells.
var grid_cfg = lu.Layout.GridConfig{ .columns = 4, .gap = 8, .sizing = .{ .main = .content, .cross = .content } };

var slider_row_cfg = lu.Layout.FlexConfig{ .direction = .row, .gap = 16, .sizing = .{ .main = .content, .cross = .content } };

const toolbar_colors = [_]u32{ 0xFF5555FF, 0xFF55AAFF, 0xFF55FFAA, 0xFFAACCFF, 0xFFCCAAFF, 0xFFAA55FF, 0xFF55FFFF, 0xFFFFAA55 };
const tile_colors = [_]u32{ 0xEE3344FF, 0xEE8855FF, 0xEECC33FF, 0x66CC55FF, 0x3399EEFF, 0x7744CCFF, 0xCC3388FF, 0x4488AAFF };

/// Mutable app state the interaction hooks read and write. Hooks are raw
/// function pointers (`fn (*anyopaque, T, bool) void`) so they cannot close
/// over locals; everything they need lives behind `data` here.
const AppState = struct {
    win: *lu.Window,
    quit: bool = false,
    /// Completed clicks on the toolbar buttons (the hook fires true on press,
    /// false when the press is released inside the same button).
    click_count: u32 = 0,
    /// Driven by the slider: while `ctx.events.dragged` names the slider, the
    /// build phase maps `ctx.events.pointer` onto the track. The drag hook only
    /// fires once at press/release; it captures the slider's laid-out position.
    slider_value: f32 = 0.66,
    /// The slider element built this frame. Valid during the post-draw
    /// processing pass (the tree is not reset until the next build), so the
    /// drag hook can read its laid-out geometry when it fires.
    slider_el: ?*lu.Element = null,
    /// The slider's laid-out position, captured when a drag starts.
    slider_pos: lu.Pos = .{ .x = 0, .y = 0 },
    checkbox_value: bool = true,
};

fn onKey(data: *anyopaque, key: lu.Key, down: bool) void {
    const app: *AppState = @ptrCast(@alignCast(data));
    if (down and key == .escape) app.quit = true;
}

fn onClick(data: *anyopaque, _: void, pressed: bool) void {
    const app: *AppState = @ptrCast(@alignCast(data));
    if (!pressed) app.click_count += 1;
}

fn onCheckbox(data: *anyopaque, _: void, pressed: bool) void {
    const app: *AppState = @ptrCast(@alignCast(data));
    if (!pressed) app.checkbox_value = !app.checkbox_value;
}

/// Fires once when a drag starts (during the post-draw processing pass, so the
/// slider element has been laid out) and once when it ends. Per-frame tracking
/// happens in the build phase from `ctx.events.dragged` + `ctx.events.pointer`;
/// this only remembers where the slider's track sits so that mapping works.
fn onSliderDrag(data: *anyopaque, _: u32, _: bool) void {
    const app: *AppState = @ptrCast(@alignCast(data));
    const el = app.slider_el orelse return;
    app.slider_pos = el.pos;
}

/// Maps the view's pointer onto the slider's track, clamping to 0.0-1.0. Reads
/// the pointer from `ctx.events` (last frame's) so the knob trails the mouse by
/// one frame, consistent with the rest of the interaction model.
fn sliderFromPointer(app: *AppState, slider: *lu.Element) void {
    const w: f32 = @floatFromInt(slider.size.w);
    if (w <= 0) return;
    const x: f32 = @floatFromInt(app.win.ctx.?.events.pointer.x);
    const left: f32 = @floatFromInt(app.slider_pos.x);
    app.slider_value = std.math.clamp((x - left) / w, 0.0, 1.0);
}

pub fn main() !void {
    // `Context` embeds the element pool (512 elements), so it is multi-megabyte;
    // allocating it on the heap keeps `main`'s stack frame small enough for the
    // default 8 MiB stack.
    const ctx = try std.heap.page_allocator.create(lu.Context);
    @memset(std.mem.asBytes(ctx), 0);
    // The memset above zeroes `flags`, wiping the documented all-on defaults;
    // `applyFlags` only ever disables a cache (via env), so restore the defaults
    // explicitly or every cache silently stays off.
    ctx.flags = .{};
    ctx.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    ctx.frame_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    ctx.freetype = try lu.Context.Freetype.init();
    ctx.leaf_layout = .{ .vtable = &lu.Layout.leaf, .parent = null };
    // Destroy the context last, after the defers below have torn down the
    // allocators and freetype that live inside it.
    defer std.heap.page_allocator.destroy(ctx);
    defer ctx.freetype.deinit();
    defer ctx.arena.deinit();
    defer ctx.frame_arena.deinit();

    ctx.fonts[0] = try ctx.freetype.createFont(
        "/usr/share/fonts/TTF/IBMPlexSans-Regular.ttf",
        32,
    );
    ctx.fonts[1] = try ctx.freetype.createFont(
        "/usr/share/fonts/noto/NotoSansArabic-Regular.ttf",
        32,
    );
    ctx.font_count = 2;
    defer {
        for (0..ctx.font_count) |i| {
            ctx.fonts[i].deinit();
        }
    }

    if (!sdl.init(sdl.SDL_INIT_VIDEO))
        return error.SDLInitFailed;
    defer sdl.quit();

    // Toggle caches via environment so the profiler can compare their cost.
    // `LUXOR_NO_GPU_CACHE=1`, `LUXOR_NO_TEXT_CACHE=1`, `LUXOR_NO_IMAGE_CACHE=1`.
    applyFlags(ctx);

    var window = try lu.Window.init(.{
        .min_size = .{ .w = 800, .h = 600 },
        .title = "luxor example",
        .transparent = false,
        .decorated = true,
    });
    defer window.deinit();
    window.plugCache(ctx);

    // Button labels are rebuilt every frame, so format them once into buffers
    // that live for the whole app instead of leaking into the arena per frame.
    var toolbar_labels: [toolbar_colors.len][32]u8 = undefined;
    var toolbar_slices: [toolbar_colors.len][]const u8 = undefined;
    for (0..toolbar_colors.len) |i| {
        toolbar_slices[i] = try std.fmt.bufPrint(&toolbar_labels[i], "Button {d}", .{i + 1});
    }
    var item_labels: [32][16]u8 = undefined;
    var item_slices: [32][]const u8 = undefined;
    for (0..32) |i| {
        item_slices[i] = try std.fmt.bufPrint(&item_labels[i], "Item {d}", .{i + 1});
    }

    var app = AppState{ .win = &window };
    window.events.key = .{ .handle = .{ .fptrs = &.{.{ .data = &app, .func = &onKey } } } };

    var dbg = window.debug();
    defer window.debugRelease();
    var frame: u64 = 0;
    while (true) {
        dbg.begin(.frame);
        dbg.begin(.events);
        window.update();
        dbg.end(.events);
        if (window.shouldQuit() or app.quit) return;

        // Immediate mode: reclaim the element pool, rebuild the tree, render.
        dbg.begin(.build);
        ctx.clear();

        // A light canvas so the black drop shadows stay visible.
        var root = lu.Element{
            .size = .{ .w = 800, .h = 600 },
            .pos = .{ .x = 0, .y = 0 },
            .background = lu.Background.solid(lu.Color{ .r = 0xDC, .g = 0xE4, .b = 0xF0, .a = 0xFF }),
            .layout = .{ .vtable = &lu.Layout.flex, .parent = null, .data = &root_cfg },
            .ctx = ctx,
            .events = lu.Context.noEvents,
        };

        // Start with the root as the current parent. Nested containers push the
        // widget onto their own layout with `start` and restore it with `end`.
        root.layout.?.element = &root;
        root.layout.?.start();

        _ = try ctx.label("Hello, World! adflahflajhlfhjkhdalvjnzn.dv,mneafhdpoapohz;dfjkhalejkhlajkdhapdoifehwa---", .{
            .border_radius = .all(4),
            .background = .{ .base = .{ .solid = .red }, .effects = &.{} },
        }, .{ .size = 28, .color = .white }, @src());
        _ = try ctx.label("\u{645}\u{631}\u{62D}\u{628}\u{627} \u{628}\u{644}\u{639}\u{627}\u{644}\u{645}", .{}, .{
            .font_idx = 1,
            .direction = .rtl,
            .size = 28,
        }, @src());

        // Interaction status, rebuilt fresh every frame so clicks/drag updates
        // from the previous frame show up immediately. The hover id lags one
        // frame by construction (it is written during render).
        var status_buf: [64]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buf, "Clicks: {d} | slider: {d:.2} | box: {s}", .{
            app.click_count,
            app.slider_value,
            if (app.checkbox_value) "on" else "off",
        });
        _ = try ctx.label(status, .{}, .{ .size = 22, .color = .{ .r = 0x44, .g = 0x44, .b = 0x44, .a = 0xFF } }, @src());

        // Toolbar: a flexbox wrap row. It is a child of the root, so it is
        // published while the root is the current parent; its buttons are built
        // against its own embedded layout, and `end` restores the root as current.
        var toolbar = lu.Element{
            .size = .{ .w = 0, .h = 0 },
            .pos = .{ .x = 0, .y = 0 },
            .background = lu.Background.solid(.{ .r = 0, .g = 0, .b = 0, .a = 0 }),
            .layout = .{ .vtable = &lu.Layout.flex, .parent = &root.layout.?, .data = &toolbar_cfg },
            .ctx = ctx,
            .events = lu.Context.noEvents,
        };
        // Stretch the toolbar across the window width (main is fixed), wrap the
        // buttons, and let its height come from the wrapped content.
        _ = ctx.publishRequest(&toolbar, .{ .min_size = .{ .w = 0, .h = 0 }, .align_self = .stretch });
        toolbar.layout.?.start();
        for (toolbar_colors, 0..) |col, i| {
            // The click hook rides in through the overrides: widgets evaluate
            // `fromId` *after* overrides, so `btn.events.hover.active` below
            // reflects last frame's hit-test and the hook handles are attached.
            const btn = try ctx.button(toolbar_slices[i], .{
                .id_extra = i,
                .events = .{ .click = .{ .handle = .{ .fptrs = &.{.{ .data = &app, .func = &onClick } } } } },
            }, .{ .color = lu.Color.fromU32(col) }, @src());
            // Hover styling reflects the *previous* frame's hit-test (the view
            // publishes hover after the frame is drawn); lighten the fill while
            // it's under the pointer.
            if (btn.events.hover.active)
                btn.background = .{ .base = .{ .solid = lu.Color.fromU32(0xFFFFFFFF) }, .effects = &.{} };
        }
        toolbar.layout.?.end();

        var button_field = lu.Element{
            .size = .{ .w = 0, .h = 0 },
            .pos = .{ .x = 0, .y = 0 },
            .background = lu.Background.solid(.{ .r = 0, .g = 0, .b = 0, .a = 0 }),
            .layout = .{ .vtable = &lu.Layout.flex, .parent = &root.layout.?, .data = &button_field_cfg },
            .ctx = ctx,
            .events = lu.Context.noEvents,
        };
        // Stretch across the window; each row fills the width, and the field's own
        // height comes from however many rows the buttons wrap into.
        _ = ctx.publishRequest(&button_field, .{ .min_size = .{ .w = 0, .h = 0 }, .align_self = .stretch });
        button_field.layout.?.start();
        for (item_slices, 0..) |label, i| {
            _ = try ctx.button(label, .{ .id_extra = i }, .{
                .min_size = .{ .w = 96, .h = 40 },
                .max_size = .{ .w = 168, .h = 40 },
                .grow = 1,
                .color = lu.Color.fromU32(0x8844CCFF),
            }, @src());
        }
        button_field.layout.?.end();

        // A content-sized grid of boxes nested inside the root. The grid container
        // is created through the widget pool so its embedded layout is stable.
        const grid = ctx.box(.{ .w = 0, .h = 0 }, .{
            .layout = .{ .vtable = &lu.Layout.grid, .parent = &root.layout.?, .data = &grid_cfg },
        }, @src());
        grid.layout.?.start();
        for (tile_colors, 0..) |col, i| {
            // Exercise every backdrop effect: a blur + drop shadow, shadows
            // with different offsets/blur/spread, an inset (`in`) mask, and
            // stacked shadows.
            const effects = switch (i % 4) {
                0 => &[_]lu.Effect{
                    .{ .blur = .{ .radius = 12, .saturation = 0.9 } },
                    .{ .shadow = .{ .mask = .out, .color = .{ .r = 0, .g = 0, .b = 0, .a = 160 }, .x_offset = 3, .y_offset = 3, .blur = 6 } },
                },
                1 => &[_]lu.Effect{
                    .{ .shadow = .{ .mask = .out, .color = .{ .r = 0, .g = 0, .b = 0, .a = 160 }, .x_offset = 0, .y_offset = 0, .spread = 4, .blur = 2 } },
                },
                2 => &[_]lu.Effect{
                    .{ .shadow = .{ .mask = .in, .color = .{ .r = 0, .g = 0, .b = 0, .a = 120 }, .x_offset = -2, .y_offset = 2, .blur = 8 } },
                },
                else => &[_]lu.Effect{
                    .{ .shadow = .{ .mask = .out, .color = .{ .r = 0, .g = 0, .b = 0, .a = 90 }, .x_offset = -3, .y_offset = -3, .blur = 4 } },
                    .{ .shadow = .{ .mask = .out, .color = .{ .r = 0, .g = 0, .b = 0, .a = 90 }, .x_offset = 3, .y_offset = 3, .blur = 4 } },
                },
            };
            _ = ctx.box(.{ .w = 40, .h = 40 }, .{
                .id_extra = i,
                .background = .{ .base = .{ .solid = lu.Color.fromU32(col) }, .effects = &.{} },
                .border_radius = .all(6),
                .has_effects = true,
                .effects = effects,
            }, @src());
        }
        grid.layout.?.end();

        var slider_row = lu.Element{
            .size = .{ .w = 0, .h = 0 },
            .pos = .{ .x = 0, .y = 0 },
            .background = lu.Background.solid(.{ .r = 0, .g = 0, .b = 0, .a = 0 }),
            .layout = .{ .vtable = &lu.Layout.flex, .parent = &root.layout.?, .data = &slider_row_cfg },
            .ctx = ctx,
            .events = lu.Context.noEvents,
        };
        _ = ctx.publishRequest(&slider_row, .{ .min_size = .{ .w = 0, .h = 0 } });
        slider_row.layout.?.start();
        _ = ctx.checkbox(app.checkbox_value, .{
            .events = .{ .click = .{ .handle = .{ .fptrs = &.{.{ .data = &app, .func = &onCheckbox } } } } },
        }, .{}, @src());
        _ = ctx.progress_bar(app.slider_value, .{}, .{}, @src());
        const slider = ctx.slider(app.slider_value, .{
            .events = .{ .drag = .{ .handle = .{ .fptrs = &.{.{ .data = &app, .func = &onSliderDrag } } } } },
        }, .{}, @src());
        // The drag hook fires once when a drag starts and ends (during the
        // post-draw processing pass, so `slider` is laid out and the handler can
        // capture its position). While the view reports this slider as dragged,
        // re-map the pointer onto the track every frame right here in the build.
        app.slider_el = slider;
        if (ctx.events.dragged != null and ctx.events.dragged.? == slider.id)
            sliderFromPointer(&app, slider);
        slider_row.layout.?.end();

        // Nothing is building any more; the window lays the tree out on render.
        root.layout.?.end();
        dbg.end(.build);

        _ = sdl.renderClear(window.renderer);

        // React to the live window size: override the root, then render.
        root.override(window.overrides());
        window.render(&root);
        dbg.begin(.present);
        _ = sdl.renderPresent(window.renderer);
        dbg.end(.present);
        dbg.end(.frame);

        // Print a report every full 200-frame window: it averages those exact
        // frames, so each line is directly comparable to the next.
        frame += 1;
        if (frame % lu.Debug.DebugInfo.HistoryWindow == 0) {
            dbg.print();
        }
    }
}

/// Parses `--no-{gpu,text,image}-cache` from argv and disables the matching
/// `Context` cache so the profiler can measure the real rasterization/decode
/// cost (an anomaly report will reflect it).
/// Turns the matching `Context` caches off when the `LUXOR_NO_{GPU,TEXT,IMAGE}_
/// CACHE` env vars are set (any non-empty value), so the profiler can measure
/// the real rasterization/decode cost.
fn applyFlags(ctx: *lu.Context) void {
    if (envSet("LUXOR_NO_GPU_CACHE")) ctx.flags.gpu_cache = false;
    if (envSet("LUXOR_NO_TEXT_CACHE")) ctx.flags.text_cache = false;
    if (envSet("LUXOR_NO_IMAGE_CACHE")) ctx.flags.image_cache = false;
}

fn envSet(name: [*:0]const u8) bool {
    const v = std.c.getenv(name) orelse return false;
    return v[0] != 0;
}
