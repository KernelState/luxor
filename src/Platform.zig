/// A platform is not necessarily a single OS/Compositor platform but instead a
/// window creation system (like SDL, GLFW and DRM/KMS). It does not manage
/// rendering it only communicates with the OS/Compositor to make windows and
/// handle them.

const std = @import("std");
const lu = @import("luxor.zig");
const sokol_renderer = @import("renderers/sokol.zig");

vtable: VTable,

const Platform = @This();

pub const VTable = struct {
    /// Should be initialized later by `init`.
    data: *anyopaque = undefined,
    getExtentions: *const fn () [][*:0]const u8,
    /// Load library, create `data` and initialize it.
    /// The return value here is `data`.
    init: *const fn (std.mem.Allocator) anyerror!*anyopaque,
    /// Deinitialize all platform state and libraries.
    /// The `data` here is the platform data.
    deinit: *const fn (*anyopaque, std.mem.Allocator) void,
    /// Create a window (or some surface creating object)
    /// The `data` here is the platform data
    createWindow: *const fn (*anyopaque, lu.Window.Config) anyerror!*anyopaque,
    /// Get a surface that can be used by the renderer
    /// The first `data` here is the platform data.
    /// The second `data` here is the window handler.
    getSurface: *const fn (*anyopaque, *anyopaque) anyerror!renderer.Surface,
    /// Close a window.
    /// The first `data` here is the platform data.
    /// The second `data` here is the window handler.
    closeWindow: *const fn (*anyopaque, *anyopaque) void,
};

pub var current: Platform = undefined;

pub fn init(self: *Platform, alloc: std.mem.Allocator) !void {
    self.vtable.data = try self.vtable.init(alloc);
}

pub fn getExtentions(self: *Platform) [][*:0]const u8 {
    return self.vtable.getExtentions();
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

pub fn getSurface(self: *Platform, handle: *anyopaque, kind: renderer.Kind) renderer.Surface {
    _ = kind;
    return self.vtable.getSurface(self.vtable.data, handle);
}

// --- Renderer ---

pub const renderer = struct {
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

    pub const sokol_vtable = sokol_renderer.vtable;

    pub const Kind = enum {
        sokol,
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
        vertex_colors: [3]Color,
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

    pub const Instance = struct {
        kind: Kind,
        vtable: renderer.VTable,
        ctx: *anyopaque,

        pub inline fn createSurface(self: Instance, native: Surface) !ObjectId {
            return self.vtable.createSurface(self.ctx, native);
        }
        pub inline fn destroySurface(self: Instance, id: ObjectId) void {
            self.vtable.destroySurface(self.ctx, id);
        }
        pub inline fn getSurfaceInfo(self: Instance, id: ObjectId) SurfaceInfo {
            return self.vtable.getSurfaceInfo(self.ctx, id);
        }
        pub inline fn resizeSurface(self: Instance, id: ObjectId, w: u32, h: u32) !void {
            return self.vtable.resizeSurface(self.ctx, id, w, h);
        }

        pub inline fn uploadTexture(self: Instance, data: []const u8, w: u32, h: u32, fmt: TextureFormat) !ObjectId {
            return self.vtable.uploadTexture(self.ctx, data, w, h, fmt);
        }
        pub inline fn destroyTexture(self: Instance, id: ObjectId) void {
            self.vtable.destroyTexture(self.ctx, id);
        }

        pub inline fn beginFrame(self: Instance, surface: ObjectId) !void {
            return self.vtable.beginFrame(self.ctx, surface);
        }
        pub inline fn endFrame(self: Instance) !void {
            return self.vtable.endFrame(self.ctx);
        }

        pub inline fn drawRect(self: Instance, rect: Rect, pos: Pos, corners: Corners, bg: Background) void {
            self.vtable.drawRect(self.ctx, rect, pos, corners, bg);
        }
        pub inline fn drawCircle(self: Instance, radius: f32, pos: Pos, bg: Background) void {
            self.vtable.drawCircle(self.ctx, radius, pos, bg);
        }
        pub inline fn drawTriangle(self: Instance, a: Pos, b: Pos, c: Pos, bg: Background) void {
            self.vtable.drawTriangle(self.ctx, a, b, c, bg);
        }
        pub inline fn drawSvg(self: Instance, svg_id: ObjectId, pos: Pos, size: Size) void {
            self.vtable.drawSvg(self.ctx, svg_id, pos, size);
        }
        pub inline fn drawMask(self: Instance, mask: Mask, pos: Pos, bg: Background) void {
            self.vtable.drawMask(self.ctx, mask, pos, bg);
        }

        pub inline fn pushClip(self: Instance, rect: Rect) void {
            self.vtable.pushClip(self.ctx, rect);
        }
        pub inline fn popClip(self: Instance) void {
            self.vtable.popClip(self.ctx);
        }
    };

    pub var current: Instance = .{
        .kind = .sokol,
        .vtable = sokol_vtable,
        .ctx = undefined,
    };
};
