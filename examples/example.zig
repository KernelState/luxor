const std = @import("std");
const lu = @import("luxor");
const sdl = @import("sdl");

var root_layout = lu.Layout{ .fn_lay = &absoluteLayout, .parent = null };

fn absoluteLayout(layout: *lu.Layout) void {
    layout.iindex = 0;
    for (layout.requests[0..layout.rindex]) |req| {
        const element = req.element orelse continue;
        layout.items[layout.iindex] = .{
            .node = element,
            .area = .{
                .pos = req.pos orelse .{ .x = 0, .y = 0 },
                .size = req.size orelse req.min_size,
            },
        };
        layout.iindex += 1;
    }
}

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

    // Widgets are immediate-mode functions: each one spits out an element and
    // places it inside `parent`. The tree is built once here and re-rendered
    // each frame.
    var root = lu.Element{
        .size = .{ .w = 800, .h = 600 },
        .pos = .{ .x = 0, .y = 0 },
        .background = lu.Background.solid(lu.Color.fromU32(0x00000000)),
        .layout = &root_layout,
        .events = lu.Widget.noEvents,
    };

    _ = widget.box(&root, .{ .w = 300, .h = 120 }, .{
        .pos = .{ .x = 60, .y = 60 },
        .border_radius = .all(12),
        .background = .{
            .base = .{ .gradient = .{
                .points = &.{
                    .{ .x = 0.0, .y = 0.0, .color = lu.Color.fromU32(0xFF3355FF) },
                    .{ .x = 1.0, .y = 0.0, .color = lu.Color.fromU32(0x33FF55FF) },
                },
                .opacity = 0.9,
            } },
            .effects = &.{},
        },
    });

    _ = try widget.label(&root, "Hello, World!", .{
        .pos = .{ .x = 60, .y = 220 },
        .border_radius = .all(4),
        .background = .{ .base = .{ .solid = .red }, .effects = &.{} },
    }, .{ .size = 28, .color = .white });
    _ = try widget.label(&root, "\u{645}\u{631}\u{62D}\u{628}\u{627} \u{628}\u{627}\u{644}\u{639}\u{627}\u{644}\u{645}", .{
        .pos = .{ .x = 300, .y = 220 },
    }, .{ .font_idx = 1, .direction = .rtl, .size = 28 });

    _ = try widget.button(&root, "Click me", .{
        .pos = .{ .x = 60, .y = 320 },
        .border = .all(2),
        .border_color = .{ .color = .white },
    }, .{ .color = lu.Color.fromU32(0x2255AAFF) });

    _ = widget.checkbox(&root, true, .{ .pos = .{ .x = 60, .y = 380 } }, .{});
    _ = widget.checkbox(&root, false, .{ .pos = .{ .x = 100, .y = 380 } }, .{});

    _ = widget.progress_bar(&root, 0.4, .{ .pos = .{ .x = 60, .y = 430 } }, .{});
    _ = widget.slider(&root, 0.66, .{ .pos = .{ .x = 60, .y = 480 } }, .{});

    // SVG image: decoded once and cached; rasterized at 160x160.
    const svg_src =
        "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200' viewBox='0 0 200 200'>" ++
        "<circle cx='100' cy='100' r='90' fill='#ffcc00'/>" ++
        "<rect x='60' y='60' width='80' height='80' rx='12' fill='#2222ff'/>" ++
        "</svg>";
    _ = try widget.image(&root, .{ .svg = svg_src }, .{
        .pos = .{ .x = 500, .y = 60 },
        .border = .all(4),
        .border_color = .{ .color = .white },
    }, .{ .svg_width = 160, .svg_height = 160 });

    // PNG image decoded from embedded bytes (cached after the first call).
    _ = try widget.image(&root, .{ .png = @embedFile("test.png") }, .{
        .pos = .{ .x = 500, .y = 260 },
        .border_radius = .all(8),
    }, .{ .fit = .contain, .filter = .nearest });

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
        _ = sdl.setRenderDrawColor(window.renderer, 230, 60, 60, 255);
        _ = sdl.renderFillRect(window.renderer, &.{ .x = 100, .y = 80, .w = 300, .h = 220 });
        _ = sdl.setRenderDrawColor(window.renderer, 60, 220, 90, 255);
        _ = sdl.renderFillRect(window.renderer, &.{ .x = 420, .y = 300, .w = 280, .h = 180 });
        _ = sdl.setRenderDrawColor(window.renderer, 70, 120, 240, 255);
        _ = sdl.renderFillRect(window.renderer, &.{ .x = 200, .y = 380, .w = 320, .h = 120 });

        const root2 = lu.Element{
            .size = .{ .w = 800, .h = 600 },
            .pos = .{ .x = 0, .y = 0 },
            .background = lu.Background.solid(lu.Color.fromU32(0x00000000)),
            .layout = &root_layout,
            .events = lu.Widget.noEvents,
        };

        window.render(root2);
        _ = sdl.renderPresent(window.renderer);
    }
}
