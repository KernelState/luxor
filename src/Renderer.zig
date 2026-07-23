const std = @import("std");
const lu = @import("luxor.zig");
const builtin = @import("builtin");
const vk =
if (!builtin.target.cpu.arch.isWasm())
    @import("renderers/vulkan.zig")
else
    @compileError("unimplemented platform wasi");

const Renderer = @This();

pub const VTable = struct {
    // Lifecycle
    init: *const fn (alloc: std.mem.Allocator) anyerror!*anyopaque,
    deinit: *const fn (ctx: *anyopaque) void,

    // Surface management (windows/targets to draw to)
    createSurface: *const fn (ctx: *anyopaque, native_surface: Surface) anyerror!ObjectId,
    destroySurface: *const fn (ctx: *anyopaque, id: ObjectId) void,
    getSurfaceInfo: *const fn (ctx: *anyopaque, id: ObjectId) SurfaceInfo,
    resizeSurface: *const fn (ctx: *anyopaque, id: ObjectId, width: u32, height: u32) anyerror!void,

    uploadTexture: *const fn (ctx: *anyopaque, data: []const u8, width: u32, height: u32, format: TextureFormat) anyerror!ObjectId,
    destroyTexture: *const fn (ctx: *anyopaque, id: ObjectId) void,
    getTextureInfo: *const fn (ctx: *anyopaque, id: ObjectId) TextureInfo,

    beginFrame: *const fn (ctx: *anyopaque, surface: ObjectId) anyerror!void,
    endFrame: *const fn (ctx: *anyopaque) anyerror!void,

    drawRect: *const fn (ctx: *anyopaque, rect: Rect, pos: Pos, corners: Corners, bg: Background) void,
    drawCircle: *const fn (ctx: *anyopaque, radius: f32, pos: Pos, bg: Background) void,
    drawTriangle: *const fn (ctx: *anyopaque, a: Pos, b: Pos, c: Pos, bg: Background) void,
    drawSvg: *const fn (ctx: *anyopaque, svg_id: ObjectId, pos: Pos, size: Size) void,
    drawMask: *const fn (ctx: *anyopaque, mask: Mask, pos: Pos, bg: Background) void,

    // Clipping/Scissoring
    pushClip: *const fn (ctx: *anyopaque, rect: Rect) void,
    popClip: *const fn (ctx: *anyopaque) void,
};

pub const ObjectId = u64;

pub const vulkan = vk.vtable;

pub var current: Renderer = .{
    .kind = .vulkan,
    .vtable = vulkan,
};

pub const Kind = enum {
    vulkan,
};
pub const Surface = union(enum) {
    win32: struct { hwnd: *anyopaque, hinstance: *anyopaque },
    xlib: struct { display: *anyopaque, window: u64 },
    wayland: struct { display: *anyopaque, surface: *anyopaque },
    android: struct { window: *anyopaque },
    metal: struct { layer: *anyopaque },
};

pub const SurfaceInfo = struct {
    width: u32,
    height: u32,
    format: TextureFormat,
    vsync: bool,
};

pub const TextureInfo = struct {
    width: u32,
    height: u32,
    format: TextureFormat,
};

pub const TextureFormat = enum {
    rgba8,
    bgra8,
    rgb8,
    rgba16f,
    r8, // grayscale
};

pub const Rect = lu.Rect;
pub const Pos = lu.Pos;
pub const Size = lu.Rect;
pub const Corners = lu.Corners;

pub const Background = union(enum) {
    solid: Color,
    texture: struct { id: ObjectId, uv: UVRect = .{} },
    gradient: Gradient,
};

pub const Color = struct { r: f32, g: f32, b: f32, a: f32 = 1.0 };

pub const UVRect = struct {
    x: f32 = 0, y: f32 = 0,
    w: f32 = 1, h: f32 = 1,
};

pub const Gradient = struct {
    start: Pos,
    end: Pos,
    stops: []const ColorStop, // renderer manages this, you pass static data
};

pub const ColorStop = struct { t: f32, color: Color };

pub const Mask = union(enum) {
    rect: struct { rect: Rect, corners: Corners },
    circle: struct { radius: f32 },
    triangle: struct { a: Pos, b: Pos, c: Pos },
    svg: []Pos,
};

// Convenience wrapper so you don't deal with *anyopaque
const Self = @This();
vtable: VTable,
ctx: *anyopaque,

pub inline fn createSurface(self: Self, native: Surface) !ObjectId {
    return self.vtable.createSurface(self.ctx, native);
}
pub inline fn destroySurface(self: Self, id: ObjectId) void {
    self.vtable.destroySurface(self.ctx, id);
}
pub inline fn getSurfaceInfo(self: Self, id: ObjectId) SurfaceInfo {
    return self.vtable.getSurfaceInfo(self.ctx, id);
}
pub inline fn resizeSurface(self: Self, id: ObjectId, w: u32, h: u32) !void {
    return self.vtable.resizeSurface(self.ctx, id, w, h);
}

pub inline fn uploadTexture(self: Self, data: []const u8, w: u32, h: u32, fmt: TextureFormat) !ObjectId {
    return self.vtable.uploadTexture(self.ctx, data, w, h, fmt);
}
pub inline fn destroyTexture(self: Self, id: ObjectId) void {
    self.vtable.destroyTexture(self.ctx, id);
}

pub inline fn beginFrame(self: Self, surface: ObjectId) !void {
    return self.vtable.beginFrame(self.ctx, surface);
}
pub inline fn endFrame(self: Self) !void {
    return self.vtable.endFrame(self.ctx);
}

pub inline fn drawRect(self: Self, rect: Rect, pos: Pos, corners: Corners, bg: Background) void {
    self.vtable.drawRect(self.ctx, rect, pos, corners, bg);
}
pub inline fn drawCircle(self: Self, radius: f32, pos: Pos, bg: Background) void {
    self.vtable.drawCircle(self.ctx, radius, pos, bg);
}
pub inline fn drawTriangle(self: Self, a: Pos, b: Pos, c: Pos, bg: Background) void {
    self.vtable.drawTriangle(self.ctx, a, b, c, bg);
}
pub inline fn drawSvg(self: Self, svg_id: ObjectId, pos: Pos, size: Size) void {
    self.vtable.drawSvg(self.ctx, svg_id, pos, size);
}
pub inline fn drawMask(self: Self, mask: Mask, pos: Pos, bg: Background) void {
    self.vtable.drawMask(self.ctx, mask, pos, bg);
}

pub inline fn pushClip(self: Self, rect: Rect) void {
    self.vtable.pushClip(self.ctx, rect);
}
pub inline fn popClip(self: Self) void {
    self.vtable.popClip(self.ctx);
}
