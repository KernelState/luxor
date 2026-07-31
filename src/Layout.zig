/// A layout is a handler that arranges elements in a certain way based on
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

const Layout = @This();

/// A request from an element get some area/size from the parent.
pub const Request = struct {
    element: lu.Element,
    size: ?lu.Rect = null,
    pos: ?lu.Pos = null,
    margin: ?lu.Margin = null,
};

pub const Item = struct {
    node: lu.Element,
    area: lu.Area,
};

pub fn lay(self: *Layout) ![]Item {
    self.fn_lay(self.data);
}

pub fn request(self: *Layout, req: Request) void {
    if (self.rindex == self.requests.len) {
        if (builtin.mode == .debug) {
            @panic("Reached maximum layout requests");
        } else {
            std.log.warn("Reached maximum layout requests, please contact the developer to fix this");
            return;
        }
    }
    self.requests[self.rindex] = req;
    self.rindex += 1;
}
