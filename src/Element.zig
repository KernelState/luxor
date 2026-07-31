const std = @import("std");
const lu = @import("luxor.zig");

size: lu.Rect,
pos: lu.Pos,
border: lu.Sides = .all(0),
border_color: lu.Color = .black,
border_radius: lu.Corners = .all(0),
background: lu.Background,
effects: [10]lu.Effect = [_]lu.Effect{.{ .blur = .{} }} ** 10,
layout: *lu.Layout,
padding: lu.Sides = .all(0),
margin: lu.Sides = .all(0),
events: Events,

const Element = @This();

pub const Events = struct {
    hover: lu.Hook(void),
    click: lu.Hook(void),
    drag: lu.Hook(u32),
    render: lu.Hook(void),
    modify: lu.Hook(void),
    focus: lu.Hook(void),
    key: lu.Hook(void),
};
