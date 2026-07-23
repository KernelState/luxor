const std = @import("std");
const lu = @import("../luxor.zig");
const sdl = lu.sdl;
const vk = lu.vk;

gpa: std.mem.Allocator,

const Sdl = @This();

pub const vtable = lu.Platform.VTable{
    .init = init,
    .getExtentions = getExtentions,
    .deinit = deinit,
    .getSurface = getSurface,
    .closeWindow = closeWindow,
    .createWindow = createWindow,
};

pub fn init(alloc: std.mem.Allocator) !*anyopaque {
    const self = alloc.create(Sdl);
    self.* = .{
        .gpa = alloc,
    };
    if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO))
        return error.SdlInitFailure;
    return self;
}

pub fn getExtentions() [][*:0]const u8 {
    var size: u32 = 0;
    var arr: [*][*:0]const u8 = sdl.SDL_Vulkan_GetInstanceExtensions(@ptrCast(&size));
    return arr[0 .. size - 1];
}

pub fn getSurface(self_: *anyopaque, win: *anyopaque, instance: *anyopaque) !lu.Renderer.Surface {
    const self: *Sdl = @ptrCast(self_);
    const surface = try self.gpa.create(vk.SurfaceKHR);
    if (!sdl.SDL_Vulkan_CreateSurface(win, @ptrCast(instance), null, surface))
        return error.FailedToCreateSurface;
    return surface;
}

pub fn createWindow(_: *anyopaque, config: lu.Window.Config) anyerror!*anyopaque {
    var flags: usize = 0;
    if (lu.Renderer.current.kind == .vulkan)
        flags |= sdl.SDL_WINDOW_VULKAN;
    if (config.decorated)
        flags |= sdl.SDL_WINDOW_BORDERLESS;
    if (config.transparent)
        flags |= sdl.SDL_WINDOW_TRANSPARENT;
    return sdl.SDL_CreateWindow(
        config.title,
        config.min_size.w,
        config.min_size.h,
        flags,
    ) orelse error.SdlCreateWindowFailure;
}

pub fn closeWindow(_: *anyopaque, win: *anyopaque) void {
    sdl.SDL_DestroyWindow(win);
}

pub fn deinit(self_: *anyopaque, alloc: std.mem.Allocator) void {
    alloc.destroy(self_);
}
