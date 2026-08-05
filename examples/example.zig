const std = @import("std");
const lu = @import("luxor");
const sdl = @import("sdl");

var root_layout = lu.Layout{ .fn_lay = &absoluteLayout, .parent = null };
var box_layout = lu.Layout{ .fn_lay = &absoluteLayout, .parent = null };

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

    const surface = sdl.loadPNG("examples/test.png") orelse return error.LoadPNGFailed;
    defer sdl.destroySurface(surface);
    const texture = sdl.createTextureFromSurface(window.renderer, surface) orelse return error.CreateTextureFailed;
    const img_id = try window.addTexture(texture);

    const events = lu.Element.Events{
        .hover = .{ .handle = null },
        .click = .{ .handle = null },
        .drag = .{ .handle = null },
        .render = .{ .handle = null },
        .modify = .{ .handle = null },
        .focus = .{ .handle = null },
        .key = .{ .handle = null },
    };

    const image_box = lu.Element{
        .size = .{ .w = 200, .h = 120 },
        .pos = .{ .x = 80, .y = 80 },
        .border = .all(6),
        .border_color = .{ .gradient = .{
            .points = &.{
                .{ .x = 0.0, .y = 0.0, .color = lu.Color.fromU32(0xFFFF00FF) },
                .{ .x = 1.0, .y = 1.0, .color = lu.Color.fromU32(0xFF00FFFF) },
            },
            .opacity = 1.0,
        } },
        .border_radius = .all(24),
        .background = lu.Background.image(.{ .id = img_id }),
        .layout = &box_layout,
        .events = events,
    };

    const blur_box = lu.Element{
        .size = .{ .w = 260, .h = 180 },
        .pos = .{ .x = 480, .y = 350 },
        .border_radius = .all(24),
        .background = .{
            .base = .{ .solid = lu.Color.fromU32(0xFFFFFF22) },
            .effects = &.{.{ .blur = .{ .radius = 16 } }},
        },
        .layout = &box_layout,
        .events = events,
    };

    const gradient_box = lu.Element{
        .size = .{ .w = 220, .h = 140 },
        .pos = .{ .x = 60, .y = 380 },
        .border_radius = .all(12),
        .background = lu.Background.gradient(.{
            .points = &.{
                .{ .x = 0.0, .y = 0.0, .color = lu.Color.fromU32(0xFF3355FF) },
                .{ .x = 1.0, .y = 0.0, .color = lu.Color.fromU32(0x33FF55FF) },
                .{ .x = 0.5, .y = 1.0, .color = lu.Color.fromU32(0xFF5533FF) },
            },
            .opacity = 0.9,
        }),
        .layout = &box_layout,
        .events = events,
    };

    var pixel_data: [160 * 80 * 4]u8 = undefined;
    for (0..80) |y| {
        for (0..160) |x| {
            const idx = (y * 160 + x) * 4;
            const checker = ((x / 16) + (y / 16)) % 2 == 0;
            if (checker) {
                pixel_data[idx] = 0xFF;
                pixel_data[idx + 1] = 0x88;
                pixel_data[idx + 2] = 0x00;
                pixel_data[idx + 3] = 0xFF;
            } else {
                pixel_data[idx] = 0x00;
                pixel_data[idx + 1] = 0x44;
                pixel_data[idx + 2] = 0xFF;
                pixel_data[idx + 3] = 0xFF;
            }
        }
    }
    const buffer_box = lu.Element{
        .size = .{ .w = 160, .h = 80 },
        .pos = .{ .x = 340, .y = 80 },
        .border_radius = .all(8),
        .background = lu.Background.buffer(.{
            .pixels = &pixel_data,
            .width = 160,
            .height = 80,
        }),
        .layout = &box_layout,
        .events = events,
    };

    try widget.label(&root_layout, "Hello, World!", .{ .x = 80, .y = 220 }, .{}, .{
        .border_radius = .all(4),
        .background = .{ .base = .{ .solid = .red }, .effects = &.{} },
    });
    try widget.label(&root_layout, "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627} \u{0628}\u{0627}\u{0644}\u{0639}\u{0627}\u{0644}\u{0645}", .{ .x = 500, .y = 220 }, .{
        .direction = .rtl,
        .font_idx = 1,
    }, .{
        .border_radius = .all(4),
    });

    root_layout.request(.{ .w = 200, .h = 120 }, null, .{ .x = 80, .y = 80 }, null);
    root_layout.addElement(image_box);
    root_layout.request(.{ .w = 260, .h = 180 }, null, .{ .x = 480, .y = 350 }, null);
    root_layout.addElement(blur_box);
    root_layout.request(.{ .w = 220, .h = 140 }, null, .{ .x = 60, .y = 380 }, null);
    root_layout.addElement(gradient_box);
    root_layout.request(.{ .w = 160, .h = 80 }, null, .{ .x = 340, .y = 80 }, null);
    root_layout.addElement(buffer_box);

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

        const root = lu.Element{
            .size = .{ .w = 800, .h = 600 },
            .pos = .{ .x = 0, .y = 0 },
            .background = lu.Background.solid(lu.Color.fromU32(0x00000000)),
            .layout = &root_layout,
            .events = events,
        };

        window.render(root);
        _ = sdl.renderPresent(window.renderer);
    }
}
