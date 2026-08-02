const std = @import("std");
const lu = @import("luxor.zig");

size: lu.Rect,
pos: lu.Pos,
border: lu.Sides = .all(0),
border_color: lu.Border = .{ .color = .black },
border_radius: lu.Corners = .all(0),
background: lu.Background,
effects: ?[]lu.Effect = null,
layout: *lu.Layout,
padding: lu.Sides = .all(0),
margin: lu.Sides = .all(0),
events: Events,
focusable: bool = true,

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

pub const Overrides = struct {
    size: ?lu.Rect = null,
    pos: ?lu.Pos = null,
    border: ?lu.Sides = null,
    border_color: ?lu.Border = null,
    border_radius: ?lu.Corners = null,
    background: ?lu.Background = null,
    has_effects: bool = false,
    effects: []lu.Effect = undefined,
    layout: ?*lu.Layout = null,
    padding: ?lu.Sides = null,
    margin: ?lu.Sides = null,
    events: ?Events = null,
    focusable: ?bool = null,
};

pub fn override(self: *Element, o: Overrides) void {
    if (o.size) |v| self.size = v;
    if (o.pos) |v| self.pos = v;
    if (o.border) |v| self.border = v;
    if (o.border_color) |v| self.border_color = v;
    if (o.border_radius) |v| self.border_radius = v;
    if (o.background) |v| self.background = v;
    if (o.has_effects) self.effects = o.effects;
    if (o.layout) |v| self.layout = v;
    if (o.padding) |v| self.padding = v;
    if (o.margin) |v| self.margin = v;
    if (o.events) |v| self.events = v;
    if (o.focusable) |v| self.focusable = v;
}
