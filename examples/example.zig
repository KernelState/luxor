const lu = @import("luxor");

const Context = struct {
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    tooltip_visible: bool = false,
    tooltip_x: f32 = 0,
    tooltip_y: f32 = 0,
};

const tri = [3]lu.Pos{
    .{ .x = 400, .y = 100 },
    .{ .x = 150, .y = 500 },
    .{ .x = 650, .y = 500 },
};

const tri_colors = [3]lu.Platform.renderer.Color{
    .{ .r = 1.0, .g = 0.0, .b = 0.0 },
    .{ .r = 0.0, .g = 1.0, .b = 0.0 },
    .{ .r = 0.0, .g = 0.0, .b = 1.0 },
};

var g_ctx = Context{};

pub fn main() void {
    lu.run(.{ .width = 800, .height = 600, .title = "Luxor" }, .{
        .init = init,
        .frame = frame,
        .event = onEvent,
        .cleanup = cleanup,
        .user_data = &g_ctx,
    });
}

fn init(user_data: ?*anyopaque) void {
    _ = user_data;
}

fn frame(user_data: ?*anyopaque) void {
    const ctx: *Context = @alignCast(@ptrCast(user_data.?));
    const hovered = pointInTriangle(ctx.mouse_x, ctx.mouse_y);

    var colors: [3]lu.Platform.renderer.Color = undefined;
    for (0..3) |i| {
        if (hovered) {
            const lum = 0.2126 * tri_colors[i].r + 0.7152 * tri_colors[i].g + 0.0722 * tri_colors[i].b;
            colors[i] = .{ .r = lum, .g = lum, .b = lum };
        } else {
            colors[i] = tri_colors[i];
        }
    }

    lu.Platform.renderer.current.drawTriangle(
        tri[0],
        tri[1],
        tri[2],
        .{ .vertex_colors = colors },
    );

    // Tooltip on overlay layer
    if (ctx.tooltip_visible) {
        lu.Platform.renderer.current.pushOverlay();
        lu.Platform.renderer.current.drawRect(
            .{ .w = 120, .h = 24 },
            .{ .x = @intFromFloat(ctx.tooltip_x + 10), .y = @intFromFloat(ctx.tooltip_y - 30) },
            .{ .top_left = 4, .top_right = 4, .bottom_left = 4, .bottom_right = 4 },
            .{ .solid = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 0.9 } },
        );
        lu.Platform.renderer.current.drawText(
            "Hovering triangle",
            ctx.tooltip_x + 14,
            ctx.tooltip_y - 22,
        );
        lu.Platform.renderer.current.popOverlay();
    }
}

fn onEvent(user_data: ?*anyopaque, e: lu.Event) void {
    const ctx: *Context = @alignCast(@ptrCast(user_data.?));
    switch (e) {
        .quit => lu.quit(),
        .key_down => |k| {
            if (k == .escape) lu.quit();
            if (k == .p) {
                lu.openPopupWindow(
                    ctx,
                    .{ .w = 400, .h = 300, .title = "Popup" },
                    popupFrame,
                    popupEvent,
                );
            }
        },
        .mouse_move => |m| {
            ctx.mouse_x = m.x;
            ctx.mouse_y = m.y;
            const hovered = pointInTriangle(m.x, m.y);
            if (hovered) {
                ctx.tooltip_visible = true;
                ctx.tooltip_x = m.x;
                ctx.tooltip_y = m.y;
            } else {
                ctx.tooltip_visible = false;
            }
        },
        else => {},
    }
}

fn cleanup(user_data: ?*anyopaque) void {
    _ = user_data;
}

fn popupFrame(user_data: ?*anyopaque) void {
    _ = user_data;
    lu.Platform.renderer.current.drawRect(
        .{ .w = 380, .h = 280 },
        .{ .x = 10, .y = 10 },
        .{ .top_left = 8, .top_right = 8, .bottom_left = 8, .bottom_right = 8 },
        .{ .solid = .{ .r = 0.2, .g = 0.2, .b = 0.3, .a = 1.0 } },
    );
    lu.Platform.renderer.current.drawText("Popup Window", 20, 20);
}

fn popupEvent(user_data: ?*anyopaque, e: lu.Event) void {
    _ = user_data;
    switch (e) {
        .quit => {},
        .key_down => |k| {
            if (k == .escape) lu.quit();
        },
        else => {},
    }
}

fn pointInTriangle(px: f32, py: f32) bool {
    const v0 = [2]f32{ @as(f32, @floatFromInt(tri[1].x)) - @as(f32, @floatFromInt(tri[0].x)), @as(f32, @floatFromInt(tri[1].y)) - @as(f32, @floatFromInt(tri[0].y)) };
    const v1 = [2]f32{ @as(f32, @floatFromInt(tri[2].x)) - @as(f32, @floatFromInt(tri[0].x)), @as(f32, @floatFromInt(tri[2].y)) - @as(f32, @floatFromInt(tri[0].y)) };
    const v2 = [2]f32{ px - @as(f32, @floatFromInt(tri[0].x)), py - @as(f32, @floatFromInt(tri[0].y)) };

    const dot00 = v0[0] * v0[0] + v0[1] * v0[1];
    const dot01 = v0[0] * v1[0] + v0[1] * v1[1];
    const dot02 = v0[0] * v2[0] + v0[1] * v2[1];
    const dot11 = v1[0] * v1[0] + v1[1] * v1[1];
    const dot12 = v1[0] * v2[0] + v1[1] * v2[1];

    const inv = 1.0 / (dot00 * dot11 - dot01 * dot01);
    const u = (dot11 * dot02 - dot01 * dot12) * inv;
    const v = (dot00 * dot12 - dot01 * dot02) * inv;

    return (u >= 0) and (v >= 0) and (u + v <= 1);
}
