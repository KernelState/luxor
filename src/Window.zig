const std = @import("std");
const lu = @import("luxor.zig");

title: []const u8,
size: lu.Rect,
transparent: bool,
/// This is a handle for the current renderer to use for stroing their data.
handle: *anyopaque,
events: Events,

pub const Config = struct {
    min_size: lu.Rect,
    pos: ?lu.Pos,
    title: []const u8,
    decorated: bool,
    transparent: bool,
};

pub const Events = struct {
    resize: lu.Hook(lu.Rect),
    draw: lu.Hook(void),
    cursor_move: lu.Hook(lu.Pos),
    click: lu.Hook(lu.MouseButton),
    key: lu.Hook(lu.Key),
    exit: lu.Hook(void),
};
