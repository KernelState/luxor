const std = @import("std");
const lu = @import("luxor.zig");

size: lu.Rect,
pos: lu.Pos,
border: lu.Sides = .all(0),
border_color: lu.Border = .{ .color = .black },
border_radius: lu.Corners = .all(0),
background: lu.Background,
/// Stable identity of this element, derived from its call site's `@src()`
/// (file:line:column). Elements are rebuilt every frame, so the same source
/// position produces the same id, letting caches (textures, CPU buffers) key
/// by "where in the code this element lives" instead of re-hashing each frame.
id: u64 = 0,
/// Disambiguator for elements created in a loop: the loop body is one source
/// position, so every iteration shares the same `id`. Pass the loop index here.
id_extra: u64 = 0,
effects: ?[]const lu.Effect = null,
/// The layout this element is attached to, embedded by value so layouts need
/// no heap allocation. `Layout` breaks the size recursion by storing children
/// and requests as element *pointers* (living in the widget's element pool)
/// instead of by value.
layout: ?lu.Layout = null,
padding: lu.Sides = .all(0),
margin: lu.Sides = .all(0),
/// The `Context` that built this element. Layouts reach the context
/// (for `start`/`end` current-parent routing) through here, so `Layout.start`
/// takes no argument.
ctx: ?*lu.Context = null,
events: Events,
focusable: bool = true,

const Element = @This();

pub const Events = struct {
    hover: lu.Hook(void) = .{},
    click: lu.Hook(void) = .{},
    drag: lu.Hook(u32) = .{},
    render: lu.Hook(void) = .{},
    modify: lu.Hook(void) = .{},
    focus: lu.Hook(void) = .{},
    key: lu.Hook(void) = .{},
};

pub const Overrides = struct {
    size: ?lu.Rect = null,
    pos: ?lu.Pos = null,
    border: ?lu.Sides = null,
    border_color: ?lu.Border = null,
    border_radius: ?lu.Corners = null,
    background: ?lu.Background = null,
    has_effects: bool = false,
    effects: []const lu.Effect = undefined,
    layout: ?lu.Layout = null,
    padding: ?lu.Sides = null,
    margin: ?lu.Sides = null,
    focusable: ?bool = null,
    id_extra: ?u64 = null,
    /// Event hooks to attach to the element. Applied like the other overrides,
    /// so the widget evaluates them against the view's per-frame event state
    /// (`fromId`) *after* this, and the element renders last frame's state.
    events: ?Events = null,
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
    if (o.focusable) |v| self.focusable = v;
    if (o.id_extra) |v| self.id_extra = v;
    if (o.events) |v| self.events = v;
}

/// The element's draw-time shape in the parent's coordinate space: position
/// and size from where it is being drawn, border radius from its settings.
/// The `Geometry` feeds the per-element caches in the Window (shadows, blur,
/// gradients), so a rebuilt element at the same place and shape reuses the
/// previous frame's raster instead of recomputing it.
pub fn geometry(self: *const Element, area: lu.Area) lu.Geometry {
    return .{ .pos = area.pos, .size = area.size, .radius = self.border_radius };
}
