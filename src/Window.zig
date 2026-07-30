const std = @import("std");
const lu = @import("luxor.zig");
const sdl = @import("sdl");

title: []const u8,
size: lu.Rect,
transparent: bool,
events: Events = .{},
window: *sdl.SDL_Window,
renderer: *sdl.SDL_Renderer,
textures: [max_textures]?Texture = [_]?Texture{null} ** max_textures,
clip_stack: [max_clips]?lu.Rect = [_]?lu.Rect{.{}} ** max_clips,

const max_textures = 1024;
const max_clips = 64;

const Window = @This();

pub const Config = struct {
    min_size: lu.Rect,
    max_size: ?lu.Rect = null,
    pos: ?lu.Pos = null,
    title: []const u8,
    decorated: bool = true,
    transparent: bool = true,
    /// The window manager can still resize even when false,
    /// this is just a guide not a requirement.
    resizable: bool = true,
};

pub const Events = struct {
    resize: lu.Hook(lu.Rect) = .{ .handle = null },
    draw: lu.Hook(void) = .{ .handle = null },
    cursor_move: lu.Hook(lu.Pos) = .{ .handle = null },
    click: lu.Hook(lu.MouseButton) = .{ .handle = null },
    key: lu.Hook(lu.Key) = .{ .handle = null },
    exit: lu.Hook(void) = .{ .handle = null },
};

pub const ObjectId = u64;

pub const Texture = struct {
    texture: *sdl.SDL_Texture,
    id: ObjectId,

    pub const Format = enum {
        rgba8,
        bgra8,
        rgb8,
        rgba16f,
        r8, // grayscale

        pub fn toSDLPixelFormat(self: Format) sdl.SDL_PixelFormat {
            return switch (self) {
                .rgba8 => sdl.SDL_PIXELFORMAT_RGBA8888,
                .bgra8 => sdl.SDL_PIXELFORMAT_BGRA8888,
                .rgb8 => sdl.SDL_PIXELFORMAT_RGB24,
                .rgba16f => sdl.SDL_PIXELFORMAT_RGBA64_FLOAT,
                .r8 => sdl.SDL_PIXELFORMAT_R8,
            };
        }
    };
};

pub fn init(config: Config) !Window {
    var flags = 0;
    if (config.resizable)
        flags |= sdl.SDL_WINDOW_RESIZABLE;
    if (config.decorated)
        flags |= sdl.SDL_WINDOW_BORDERLESS;
    if (config.transparent)
        flags |= sdl.SDL_WINDOW_TRANSPARENT;
    var self = Window{
        .transparent = (flags ^ sdl.SDL_WINDOW_TRANSPARENT != 0),
        .renderer = undefined,
        .window = undefined,
        .size = undefined,
        .title = config.title,
    };
    if (!sdl.SDL_CreateWindowAndRenderer(
        config.title,
        config.min_size.w,
        config.min_size.h,
        flags,
        @ptrCast(&self.window),
        @ptrCast(&self.renderer),
    ))
        return error.FailedToCreateWindow;
    if (!sdl.SDL_GetWindowSize(
        self.window,
        @ptrCast(&self.size.w),
        @ptrCast(&self.size.h),
    ))
        return error.FailedToGetWindowInfo;
}

pub fn deinit(self: *Window) void {
    for (self.textures) |t| {
        if (t == null) break;
        sdl.SDL_DestroyTexture(@ptrCast(t.?));
    }
    sdl.SDL_DestroyRenderer(self.renderer);
    sdl.SDL_DestroyWindow(self.window);
}

pub fn pushClip(self: *Window, pos: lu.Pos, rect: lu.Rect) void {
    for (&self.clip_stack) |*c| {
        if (c.* == null) {
            c.* = rect;
            if (!sdl.SDL_SetRenderClipRect(self.renderer, sdl.SDL_Rect{
                .x = pos.x,
                .y = pos.y,
                .w = rect.w,
                .h = rect.h,
            }))
                return error.FailedToAssignClipRect;
        }
        return;
    }
    return error.TooManyClipRects;
}

pub fn popClip(self: *Window) !void {
    for (self.clip_stack, 0..) |c, i| {
        if (c == null) {
            if (i == 0)
                return error.NoClipToPop;
            self.clip_stack[i - 1] = null;
            return;
        }
        if (i == self.clip_stack - 1) {
            self.clip_stack[i - 1] = null;
            return;
        }
    }
    unreachable;
}

pub fn beginFrame(self: *Window) !void {
    if (!sdl.SDL_RenderClear(self.renderer))
        return error.FailedToBeginFrame;
}

pub fn endFrame(self: *Window) !void {
    if (!sdl.SDL_RenderPresent(self.renderer))
        return error.FailedToBeginFrame;
}

pub fn drawImage(
    self: *Window,
    data: []const u8,
    size: lu.Rect,
    pos: lu.Pos,
    format: Texture.Format,
) void {
    for (&self.textures) |*t| {
        if (t.* == null) {
            t.* = .{
                .id = std.crypto.random.int(u64),
                .texture = sdl.SDL_CreateTexture(
                    self.renderer,
                    format.toSDLPixelFormat(),
                    sdl.SDL_TEXTUREACCESS_STATIC,
                    size.width,
                    size.height,
                ) orelse return error.FailedToCreateTexture,
            };
            if (!sdl.SDL_UpdateTexture(t.?.texture, .{
                .x = pos.x,
                .y = pos.y,
                .w = size.width,
                .h = size.height,
            }, data.ptr, 0))
                return error.FailedToUpload;
        }
    }
}
