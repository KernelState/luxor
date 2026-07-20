/// A layout is a handler that arranges elements in a certain way based on
/// their request of size or position or both. Layouts are usually long lasting
/// objects that are maintained externally, this struct only makes it so you can
/// layout any externally initialized and handled layout handler.
const std = @import("std");
const lu = @import("luxor.zig");

data: *anyopaque,
/// add a request with a size and a prefered position.
fn_request: *const fn (*anyopaque, Request) anyerror!void,
/// Layout all the saved requests for taking up some size.
fn_lay: *const fn (*anyopaque) anyerror![]Item,
/// A layout can have a parent, this is important for the flow inside of the tree
/// and important for the layout itself to request.
parent: ?*Layout,

const Layout = @This();

/// A request from an element get some area/size from the parent.
pub const Request = struct {
    size: ?lu.Rect = null,
    pos: ?lu.Pos = null,
    margin: ?lu.Margin = null,
};

pub const Item = struct {
    size: lu.Rect,
    pos: lu.Pos,
};

pub fn lay(self: *Layout) ![]Item {
    return self.fn_lay(self.data);
}

pub fn request(self: *Layout, req: Request) !void {
    return self.fn_request(self, req);
}
