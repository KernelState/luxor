const std = @import("std");
const sapp = @import("sokol").app;
const lu = @import("luxor");

var mouse_x: f32 = 0;
var mouse_y: f32 = 0;
var surface_id: lu.Platform.renderer.ObjectId = undefined;

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

pub fn main() !void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = 800,
        .height = 600,
        .window_title = "Luxor",
    });
}

fn init() callconv(.c) void {
    const ctx = lu.Platform.renderer.current.vtable.init(std.heap.page_allocator) catch return;
    lu.Platform.renderer.current.ctx = ctx;
    surface_id = lu.Platform.renderer.current.vtable.createSurface(ctx, .{ .xlib = .{ .display = undefined, .window = 0 } }) catch return;
}

fn frame() callconv(.c) void {
    lu.Platform.renderer.current.vtable.beginFrame(lu.Platform.renderer.current.ctx, surface_id) catch return;
    defer lu.Platform.renderer.current.vtable.endFrame(lu.Platform.renderer.current.ctx) catch {};

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

    lu.Platform.renderer.current.vtable.drawTriangle(
        lu.Platform.renderer.current.ctx,
        tri[0],
        tri[1],
        tri[2],
        .{ .vertex_colors = colors },
    );
}

fn cleanup() callconv(.c) void {
    lu.Platform.renderer.current.vtable.deinit(lu.Platform.renderer.current.ctx);
}

fn event(e: [*c]const sapp.Event) callconv(.c) void {
    const ev = (e orelse return).*;
    switch (ev.type) {
        .QUIT_REQUESTED => sapp.requestQuit(),
        .KEY_DOWN => {
            if (ev.key_code == .ESCAPE) sapp.requestQuit();
        },
        .MOUSE_MOVE => {
            mouse_x = ev.mouse_x;
            mouse_y = ev.mouse_y;
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
