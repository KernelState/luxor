/// A platform is not necessarily a single OS/Compositor platform but instead a
/// window creation system (like SDL, GLFW and DRM/KMS). It does not manage
/// rendering it only communicates with the OS/Compositor to make windows and
/// handle them.

const std = @import("std");
const lu = @import("luxor.zig");

vtable: VTable,
events: Events,

const Platform = @This();

pub const Events = struct {
    resize: lu.Hook(lu.Rect),
    draw: lu.Hook(void),
    cursor_move: lu.Hook(lu.Pos),
    click: lu.Hook(lu.MouseButton),
    key: lu.Hook(lu.Key),
    exit: lu.Hook(void),
};

pub const VTable = struct {
    /// Should be initialized later by `init`.
    data: *anyopaque = undefined,
    /// Load library, create `data` and initialize it.
    /// The return value here is `data`.
    init: *const fn (std.mem.Allocator) anyerror!*anyopaque,
    /// Deinitialize all platform state and libraries.
    /// The `data` here is the platform data.
    deinit: *const fn (*anyopaque, std.mem.Allocator) void,
    /// Create a window (or some surface creating object)
    /// The `data` here is the platform data
    createWindow: *const fn (*anyopaque, lu.Window.Config) anyerror!void,
    /// Get a surface that can be used by the renderer
    /// The first `data` here is the platform data.
    /// The second `data` here is the window handler.
    getSurface: *const fn (*anyopaque, *anyopaque, lu.Renderer.Kind) lu.Renderer.Surface,
    /// Close a window.
    /// The first `data` here is the platform data.
    /// The second `data` here is the window handler.
    closeWindow: *const fn (*anyopaque, *anyopaque) void,
};

pub fn init(self: *Platform, alloc: std.mem.Allocator) !void {
    self.vtable.data = try self.vtable.init(alloc);
}

pub fn deinit(self: *Platform, alloc: std.mem.Allocator) void {
    self.vtable.deinit(self.vtable.data, alloc);
}

pub fn createWindow(self: *Platform, config: lu.Window.Config) !void {
    try self.vtable.createWindow(self.vtable.data, config);
}

pub fn closeWindow(self: *Platform, handle: *anyopaque) void {
    self.vtable.closeWindow(self.vtable.data, handle);
}

pub fn getSurface(self: *Platform, handle: *anyopaque, kind: lu.Renderer.Kind) lu.Renderer.Surface {
    return self.vtable.getSurface(self.vtable.data, handle, kind);
}
