const std = @import("std");
const lu = @import("luxor");
const sdl = @import("sdl");

// Root column fills the window and lays everything top to bottom. It has no
// parent, so it is the root of the tree.
var root_cfg = lu.Layout.FlexConfig{ .direction = .column, .gap = 12, .align_items = .flex_start };
var root_layout = lu.Layout{
    .vtable = &lu.Layout.flex,
    .parent = null,
    .data = &root_cfg,
};

// A wrap row that fills the parent's width (main = fixed) and takes its height
// from the wrapped content (cross = content).
var toolbar_cfg = lu.Layout.FlexConfig{ .direction = .row, .gap = 8, .wrap = true, .sizing = .{ .main = .fixed, .cross = .content } };
var toolbar_layout = lu.Layout{
    .vtable = &lu.Layout.flex,
    .parent = &root_layout,
    .data = &toolbar_cfg,
};

// A long list of buttons wrapped into rows. Like the toolbar it fills the
// window width and takes its height from the wrapped rows, but every button has
// an explicit min/max so it never shrinks below `min_size`, never grows past
// `max_size`, and never overflows: the surplus width in each row is handed to
// `grow` buttons only up to their `max_size`, and wrapping grows this row's
// height to fit the rows instead of letting them spill.
var button_field_cfg = lu.Layout.FlexConfig{ .direction = .row, .gap = 8, .wrap = true, .sizing = .{ .main = .fixed, .cross = .content } };
var button_field_layout = lu.Layout{
    .vtable = &lu.Layout.flex,
    .parent = &root_layout,
    .data = &button_field_cfg,
};

// Sizes itself to its children's cells.
var grid_cfg = lu.Layout.GridConfig{ .columns = 4, .gap = 8, .sizing = .{ .main = .content, .cross = .content } };
var grid_layout = lu.Layout{
    .vtable = &lu.Layout.grid,
    .parent = &root_layout,
    .data = &grid_cfg,
};

var slider_row_cfg = lu.Layout.FlexConfig{ .direction = .row, .gap = 16, .sizing = .{ .main = .content, .cross = .content } };
var slider_row_layout = lu.Layout{
    .vtable = &lu.Layout.flex,
    .parent = &root_layout,
    .data = &slider_row_cfg,
};

pub fn main() !void {
    var widget = lu.Widget{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .freetype = try lu.Widget.Freetype.init(),
    };
    defer widget.freetype.deinit();
    defer widget.arena.deinit();

    widget.fonts[0] = try widget.freetype.createFont(
        "/usr/share/fonts/TTF/IBMPlexSans-Regular.ttf",
        32,
    );
    widget.fonts[1] = try widget.freetype.createFont(
        "/usr/share/fonts/noto/NotoSansArabic-Regular.ttf",
        32,
    );
    widget.font_count = 2;
    defer {
        for (0..widget.font_count) |i| {
            widget.fonts[i].deinit();
        }
    }

    if (!sdl.init(sdl.SDL_INIT_VIDEO))
        return error.SDLInitFailed;
    defer sdl.quit();

    var window = try lu.Window.init(.{
        .min_size = .{ .w = 800, .h = 600 },
        .title = "luxor example",
        .transparent = false,
        .decorated = true,
    });
    defer window.deinit();

    var root = lu.Element{
        .size = .{ .w = 800, .h = 600 },
        .pos = .{ .x = 0, .y = 0 },
        .background = lu.Background.solid(lu.Color.fromU32(0x00000000)),
        .layout = &root_layout,
        .widget = &widget,
        .events = lu.Widget.noEvents,
    };

    // Start with the root as the current parent. Nested containers push the
    // widget onto their own layout with `start` and restore it with `end`.
    root_layout.element = &root;
    root_layout.start();

    _ = try widget.label("Hello, World! adflahflajhlfhjkhdalvjnzn.dv,mneafhdpoapohzl;dfjkhalejkhlajkdhapdoifehwa---", .{
        .border_radius = .all(4),
        .background = .{ .base = .{ .solid = .red }, .effects = &.{} },
    }, .{ .size = 28, .color = .white });
    _ = try widget.label("\u{645}\u{631}\u{62D}\u{628}\u{627} \u{628}\u{644}\u{639}\u{627}\u{644}\u{645}", .{}, .{
        .font_idx = 1,
        .direction = .rtl,
        .size = 28,
    });

    // Toolbar: a flexbox wrap row. It is a child of the root, so it is
    // published while the root is the current parent; its buttons are built
    // against `toolbar_layout`, and `end` restores the root as current.
    var toolbar = lu.Element{
        .size = .{ .w = 0, .h = 0 },
        .pos = .{ .x = 0, .y = 0 },
        .background = lu.Background.solid(.{ .r = 0, .g = 0, .b = 0, .a = 0 }),
        .layout = &toolbar_layout,
        .widget = &widget,
        .events = lu.Widget.noEvents,
    };
    // Stretch the toolbar across the window width (main is fixed), wrap the
    // buttons, and let its height come from the wrapped content.
    _ = widget.publishRequest(&toolbar, .{ .min_size = .{ .w = 0, .h = 0 }, .align_self = .stretch });
    toolbar_layout.start();
    const colors = [_]u32{ 0xFF5555FF, 0xFF55AAFF, 0xFF55FFAA, 0xFFAACCFF, 0xFFCCAAFF, 0xFFAA55FF, 0xFF55FFFF, 0xFFFFAA55 };
    for (colors, 0..) |col, i| {
        _ = try widget.button(
            std.fmt.allocPrint(widget.arena.allocator(), "Button {d}", .{i + 1}) catch "Button",
            .{},
            .{ .color = lu.Color.fromU32(col) },
        );
    }
    toolbar_layout.end();

    var button_field = lu.Element{
        .size = .{ .w = 0, .h = 0 },
        .pos = .{ .x = 0, .y = 0 },
        .background = lu.Background.solid(.{ .r = 0, .g = 0, .b = 0, .a = 0 }),
        .layout = &button_field_layout,
        .widget = &widget,
        .events = lu.Widget.noEvents,
    };
    // Stretch across the window; each row fills the width, and the field's own
    // height comes from however many rows the buttons wrap into.
    _ = widget.publishRequest(&button_field, .{ .min_size = .{ .w = 0, .h = 0 }, .align_self = .stretch });
    button_field_layout.start();
    for (0..32) |i| {
        _ = try widget.button(
            std.fmt.allocPrint(widget.arena.allocator(), "Item {d}", .{i + 1}) catch "Item",
            .{},
            .{
                .min_size = .{ .w = 96, .h = 40 },
                .max_size = .{ .w = 168, .h = 40 },
                .grow = 1,
                .color = lu.Color.fromU32(0x8844CCFF),
            },
        );
    }
    button_field_layout.end();

    // A content-sized grid of boxes nested inside the root.
    _ = widget.box(.{ .w = 0, .h = 0 }, .{ .layout = &grid_layout });
    grid_layout.start();
    const tile_colors = [_]u32{ 0xEE3344, 0xEE8855, 0xEECC33, 0x66CC55, 0x3399EE, 0x7744CC, 0xCC3388, 0x4488AA };
    for (tile_colors) |col| {
        _ = widget.box(.{ .w = 40, .h = 40 }, .{
            .background = .{ .base = .{ .solid = lu.Color.fromU32(col) }, .effects = &.{} },
            .border_radius = .all(6),
        });
    }
    grid_layout.end();

    var slider_row = lu.Element{
        .size = .{ .w = 0, .h = 0 },
        .pos = .{ .x = 0, .y = 0 },
        .background = lu.Background.solid(.{ .r = 0, .g = 0, .b = 0, .a = 0 }),
        .layout = &slider_row_layout,
        .widget = &widget,
        .events = lu.Widget.noEvents,
    };
    _ = widget.publishRequest(&slider_row, .{ .min_size = .{ .w = 0, .h = 0 } });
    slider_row_layout.start();
    _ = widget.checkbox(true, .{}, .{});
    _ = widget.progress_bar(0.4, .{}, .{});
    _ = widget.slider(0.66, .{}, .{});
    slider_row_layout.end();

    // Nothing is building any more; the window lays the tree out on render.
    root_layout.end();

    var event: sdl.SDL_Event = undefined;
    while (true) {
        while (sdl.pollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_QUIT, sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => return,
                sdl.SDL_EVENT_KEY_DOWN => {
                    if (event.key.scancode == sdl.SDL_SCANCODE_ESCAPE) return;
                },
                else => {},
            }
        }

        _ = sdl.renderClear(window.renderer);

        // React to the live window size: override the root, then render.
        root.override(window.overrides());
        window.render(&root);
        _ = sdl.renderPresent(window.renderer);
    }
}
