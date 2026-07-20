const std = @import("std");
const lu = @import("luxor.zig");

vtable: VTable,
kind: Kind,

const Renderer = @This();

pub const VTable = struct {
    data: *anyopaque,
    /// initialize `data`
    init: *const fn (std.mem.Allocator) anyerror!*anyopaque,
    /// Deinitialize `data`
    deinit: *const fn (*anyopaque, std.mem.Allocator) void,
    /// Draw a rectangle
    drawRect: *const fn (
        *anyopaque,
        Surface,
        lu.Rect,
        lu.Pos,
        lu.Corners,
        lu.Background,
    ) void,
};

pub const Kind = enum {
    vulkan,
};

pub const Surface = union(Kind) {
    vulkan: void,
};

pub const Texture = union(Kind) {
    vulkan: void,
};

pub fn init(self: *Renderer, alloc: std.mem.Allocator) !void {
    self.vtable.data = try self.vtable.init(alloc);
}

pub fn deinit(self: *Renderer, alloc: std.mem.Allocator) void {
    self.vtable.deinit(self.vtable.data, alloc);
}

pub fn drawRect(
    self: *Renderer,
    s: Surface,
    r: lu.Rect,
    p: lu.Pos,
    c: lu.Corners,
    b: lu.Background,
) void {
    self.vtable.drawRect(self.vtable.data, s, r, p, c, b);
}
