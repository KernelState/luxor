const lu = @import("luxor");

var mouse_x: f32 = 0;
var mouse_y: f32 = 0;

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

pub fn main() void {
    lu.run(.{ .width = 800, .height = 600, .title = "Luxor" }, .{
        .frame = frame,
        .event = onEvent,
    });
}

fn frame() void {
    const hovered = pointInTriangle(mouse_x, mouse_y);

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
}

fn onEvent(e: lu.Event) void {
    switch (e) {
        .quit => lu.quit(),
        .key_down => |k| {
            if (k == .escape) lu.quit();
        },
        .mouse_move => |m| {
            mouse_x = m.x;
            mouse_y = m.y;
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
