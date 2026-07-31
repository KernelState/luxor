const std = @import("std");
const builtin = @import("builtin");
const lu = @import("luxor.zig");
const sdl = @import("sdl");

title: []const u8,
size: lu.Rect,
transparent: bool,
events: Events = .{},
window: *sdl.SDL_Window,
renderer: *sdl.SDL_Renderer,
textures: [max_textures]Texture = undefined,
clip_stack: [max_clips]lu.Area = undefined,
/// Current index in `textures`
tindex: usize = 0,
/// Current index in `clip_stack`
cindex: usize = 0,

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
    if (!sdl.createWindowAndRenderer(
        config.title,
        config.min_size.w,
        config.min_size.h,
        flags,
        @ptrCast(&self.window),
        @ptrCast(&self.renderer),
    ))
        return error.FailedToCreateWindow;
    if (!sdl.getWindowSize(
        self.window,
        @ptrCast(&self.size.w),
        @ptrCast(&self.size.h),
    ))
        return error.FailedToGetWindowInfo;
}

pub fn deinit(self: *Window) void {
    for (self.textures) |t| {
        if (t == null) break;
        sdl.destroyTexture(@ptrCast(t.?));
    }
    sdl.destroyRenderer(self.renderer);
    sdl.destroyWindow(self.window);
}

pub fn pushClip(self: *Window, area: lu.Area) void {
    if (self.cindex >= self.clip_stack.len) {
        if (builtin.mode == .Debug) {
            @panic("Failed to add clip, clip_stack is full");
        } else {
            std.log.warn("Failed to add clip, clip_stack is full, please contact the developer to fix that", .{});
            return;
        }
    }
    self.clip_stack[self.cindex] = area;
    sdl.setRenderClipRect(self.renderer, &area.toSDL());
    self.cindex += 1;
}

pub fn popClip(self: *Window) void {
    self.clip_stack[self.cindex] = undefined;
    if (self.cindex != 0) {
        self.cindex -= 1;
        sdl.setRenderClipRect(self.renderer, self.clip_stack[self.cindex].toSDL());
    }
}

/// Renders a layout with elements inside, lays out the elements first then then
/// loop over the elements to display then.
pub fn render(self: *Window, root: lu.Element) void {
    self.pushClip(lu.Area.toSDL(&.{ .pos = root.pos, .size = root.size }));
    switch (root.background.base) {
        .solid => |c| {
            sdl.setRenderDrawColor(self.renderer, c.r, c.g, c.b, c.a);
        },
        .gradient => |c| {}
    }
    for (root.layout.items[0..root.layout.iindex+1]) |r| {
        self.render(r);
    }
}
