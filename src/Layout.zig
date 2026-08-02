/// A layout is a handler that arrangers elements in a certain way based on
/// their request of size or position or both. Layouts are usually long lasting
/// objects that are maintained externally, this struct only makes it so you can
/// layout any externally initialized and handled layout handler.
const std = @import("std");
const builtin = @import("builtin");
const lu = @import("luxor.zig");

/// index for the last item in requests
rindex: usize = 0,
/// index for the last item in items
iindex: usize = 0,
requests: [1000]Request = undefined,
/// The actual things getting space, the layout doesn't care about them but them
/// but they're important for the window getting the layout.
items: [1000]Item = undefined,
/// Layout all the saved requests for taking up some size.
fn_lay: *const fn (*Layout) void,
/// A layout can have a parent, this is important for the flow inside of the tree
/// and important for the layout itself to request.
parent: ?*Layout,
/// Index of a request that is waiting for an element to be assigned via addElement.
/// null means no request is pending.
pending: ?usize = null,
/// Opaque pointer for layout-specific data, accessible from the fn_lay callback.
data: ?*anyopaque = null,

const Layout = @This();

/// A request from an element to get some area/size from the parent.
/// The element is null until addElement is called.
pub const Request = struct {
    element: ?lu.Element = null,
    min_size: lu.Rect,
    size: ?lu.Rect = null,
    pos: ?lu.Pos = null,
    margin: ?lu.Sides = null,
};

pub const Item = struct {
    node: lu.Element,
    area: lu.Area,
};

/// Layout all the saved requests for taking up some size, returning the
/// resulting items to render.
pub fn lay(self: *Layout) []Item {
    self.fn_lay(self);
    return self.items[0..self.iindex];
}

/// Request space from the layout. Asserts that no request is already pending.
/// After calling this, call addElement to assign the element to this slot.
pub fn request(self: *Layout, min_size: lu.Rect, size: ?lu.Rect, pos: ?lu.Pos, margin: ?lu.Sides) void {
    if (self.pending != null) {
        if (builtin.mode == .Debug) {
            @panic("layout.request called while a pending request exists; call addElement first");
        } else {
            std.log.warn("layout.request called while a pending request exists, ignoring", .{});
            return;
        }
    }
    if (self.rindex == self.requests.len) {
        if (builtin.mode == .Debug) {
            @panic("Reached maximum layout requests");
        } else {
            std.log.warn("Reached maximum layout requests, please contact the developer to fix this");
            return;
        }
    }
    self.requests[self.rindex] = .{
        .element = null,
        .min_size = min_size,
        .size = size,
        .pos = pos,
        .margin = margin,
    };
    self.pending = self.rindex;
    self.rindex += 1;
}

/// Assign an element to the last pending request. Asserts that a pending request exists.
pub fn addElement(self: *Layout, element: lu.Element) void {
    const idx = self.pending orelse {
        if (builtin.mode == .Debug) {
            @panic("layout.addElement called with no pending request; call request first");
        } else {
            std.log.warn("layout.addElement called with no pending request, ignoring", .{});
            return;
        }
    };
    self.requests[idx].element = element;
    self.pending = null;
}
