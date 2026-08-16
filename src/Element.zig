const std = @import("std");
const lu = @import("luxor.zig");

size: lu.Rect,
pos: lu.Pos,
/// Everything visual about the element: border, background, effects, padding,
/// margin. Widgets populate it via the kind's default style (`Context.base`)
/// and their opts; they and themes/overrides write to it in `Style.Overrides`
/// format.
style: lu.Style = .{},
/// Stable identity of this element, derived from its call site's `@src()`
/// (file:line:column). Elements are rebuilt every frame, so the same source
/// position produces the same id, letting caches (textures, CPU buffers) key
/// by "where in the code this element lives" instead of re-hashing each frame.
id: u64 = 0,
/// Disambiguator for elements created in a loop: the loop body is one source
/// position, so every iteration shares the same `id`. Pass the loop index here.
id_extra: u64 = 0,
/// The layout this element is attached to, embedded by value so layouts need
/// no heap allocation. `Layout` breaks the size recursion by storing children
/// and requests as element *pointers* (living in the widget's element pool)
/// instead of by value.
layout: ?lu.Layout = null,
/// The `Context` that built this element. Layouts reach the context
/// (for `start`/`end` current-parent routing) through here, so `Layout.start`
/// takes no argument.
ctx: ?*lu.Context = null,
events: Events,
focusable: bool = true,

const Element = @This();

pub const Events = struct {
    /// Fires on enter/leave with the pointer offset from the element's origin.
    hover: lu.Hook(lu.Offset) = .{},
    /// Fires on press/release with the press pointer offset from the origin.
    click: lu.Hook(lu.Offset) = .{},
    /// Fires on drag start/end with the pointer offset from the drag origin.
    drag: lu.Hook(lu.Offset) = .{},
    render: lu.Hook(void) = .{},
    modify: lu.Hook(void) = .{},
    /// Fires on focus grant/revoke with how focus was granted.
    focus: lu.Hook(lu.FocusSource) = .{},
    key: lu.Hook(void) = .{},
};

pub const Overrides = struct {
    size: ?lu.Rect = null,
    pos: ?lu.Pos = null,
    /// Element-style overrides (border, background, effects, padding, margin)
    /// in `lu.Style.Overrides` format. Same shape the theme/default-styles
    /// hashmap holds, so the same overrides struct works for both.
    style: ?lu.Style.Overrides = null,
    layout: ?lu.Layout = null,
    focusable: ?bool = null,
    id_extra: ?u64 = null,
    /// Event hooks to attach to the element. Applied like the other overrides,
    /// so the widget evaluates them against the view's per-frame event state
    /// *after* this, and the element renders last frame's state.
    events: ?Events = null,
};

pub fn override(self: *Element, o: Overrides) void {
    if (o.size) |v| self.size = v;
    if (o.pos) |v| self.pos = v;
    if (o.style) |s| s.apply(&self.style);
    if (o.layout) |v| self.layout = v;
    if (o.focusable) |v| self.focusable = v;
    if (o.id_extra) |v| self.id_extra = v;
    if (o.events) |v| self.events = v;
}

/// The element's draw-time shape in the parent's coordinate space: position
/// and size from where it is being drawn, border radius from its style.
/// The `Geometry` feeds the per-element caches in the Window (shadows, blur,
/// gradients), so a rebuilt element at the same place and shape reuses the
/// previous frame's raster instead of recomputing it.
pub fn geometry(self: *const Element, area: lu.Area) lu.Geometry {
    return .{ .pos = area.pos, .size = area.size, .radius = self.style.border_radius };
}
