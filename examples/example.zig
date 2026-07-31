const std = @import("std");
const lu = @import("luxor");
const sdl = @import("sdl");

var root_layout = lu.Layout{ .fn_lay = &absoluteLayout, .parent = null };
var box_layout = lu.Layout{ .fn_lay = &absoluteLayout, .parent = null };

fn absoluteLayout(layout: *lu.Layout) void {
    layout.iindex = 0;
    for (layout.requests[0..layout.rindex]) |req| {
        layout.items[layout.iindex] = .{
            .node = req.element,
            .area = .{
                .pos = req.pos orelse .{ .x = 0, .y = 0 },
                .size = req.size orelse .{ .w = 0, .h = 0 },
            },
        };
        layout.iindex += 1;
    }
}

pub fn main() !void {
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
        .border_gradient = .{
            .points = &.{
                .{ .x = 0.0, .y = 0.0, .color = lu.Color.fromU32(0xFFFF00FF) },
                .{ .x = 1.0, .y = 1.0, .color = lu.Color.fromU32(0xFF00FFFF) },
            },
            .opacity = 1.0,
        },
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

    root_layout.request(.{
        .element = image_box,
        .size = .{ .w = 200, .h = 120 },
        .pos = .{ .x = 80, .y = 80 },
    });
    root_layout.request(.{
        .element = blur_box,
        .size = .{ .w = 260, .h = 180 },
        .pos = .{ .x = 480, .y = 350 },
    });
    root_layout.request(.{
        .element = gradient_box,
        .size = .{ .w = 220, .h = 140 },
        .pos = .{ .x = 60, .y = 380 },
    });

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

        // Some colorful content behind the UI. This is what the blur effect
        // captures, since the blur is applied to the render output before the
        // element tree is drawn.
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
