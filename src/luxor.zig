const std = @import("std");
const sdl = @import("sdl");
pub const Platform = @import("Platform.zig");

pub const Element = @import("Element.zig");
pub const Layout = @import("Layout.zig");
pub const Window = @import("Window.zig");

// SDL event type constants (u32 to match ev.type)
const SDL_EVENT_QUIT: u32 = 256;
const SDL_EVENT_KEY_DOWN: u32 = 768;
const SDL_EVENT_KEY_UP: u32 = 769;
const SDL_EVENT_MOUSE_MOTION: u32 = 1024;
const SDL_EVENT_MOUSE_BUTTON_DOWN: u32 = 1025;
const SDL_EVENT_MOUSE_BUTTON_UP: u32 = 1026;
const SDL_EVENT_WINDOW_RESIZED: u32 = 518;
const SDL_EVENT_WINDOW_CLOSE_REQUESTED: u32 = 528;

const SDL_INIT_VIDEO: u32 = 0x20;
const SDL_WINDOW_OPENGL: u64 = 0x2;
const SDL_WINDOW_RESIZABLE: u64 = 0x20;
const SDL_WINDOW_TOOLTIP: u64 = 0x40000;
const SDL_WINDOW_POPUP_MENU: u64 = 0x80000;

pub const RunConfig = struct {
    width: u32 = 800,
    height: u32 = 600,
    title: [*:0]const u8 = "Luxor",
};

pub const PopupConfig = struct {
    w: u32 = 800,
    h: u32 = 600,
    title: [*:0]const u8 = "Popup",
};

pub const Callbacks = struct {
    init: *const fn (?*anyopaque) void = struct {
        fn noop(_: ?*anyopaque) void {}
    }.noop,
    frame: *const fn (?*anyopaque) void = struct {
        fn noop(_: ?*anyopaque) void {}
    }.noop,
    event: *const fn (?*anyopaque, Event) void = struct {
        fn noop(_: ?*anyopaque, _: Event) void {}
    }.noop,
    cleanup: *const fn (?*anyopaque) void = struct {
        fn noop(_: ?*anyopaque) void {}
    }.noop,
    user_data: ?*anyopaque = null,
};

pub const Event = union(enum) {
    quit,
    key_down: Key,
    key_up: Key,
    char_input: u21,
    mouse_move: struct { x: f32, y: f32 },
    mouse_down: MouseButton,
    mouse_up: MouseButton,
    mouse_scroll: struct { x: f32, y: f32 },
    resized: struct { width: u32, height: u32 },
    focused: void,
    unfocused: void,
    suspended: void,
    resumed: void,
};

const max_popups = 16;

const PopupState = struct {
    window: ?*sdl.SDL_Window = null,
    gl_ctx: sdl.SDL_GLContext = null,
    window_id: u32 = 0,
    surface_id: Platform.renderer.ObjectId = 0,
    frame_fn: *const fn (?*anyopaque) void = undefined,
    event_fn: *const fn (?*anyopaque, Event) void = undefined,
    user_data: ?*anyopaque = null,
    active: bool = false,
};

var g_main_window: ?*sdl.SDL_Window = null;
var g_main_gl_ctx: sdl.SDL_GLContext = null;
var g_main_window_id: u32 = 0;
var g_main_surface_id: Platform.renderer.ObjectId = 0;
var g_callbacks: Callbacks = .{};
var g_running: bool = false;
var g_popups: [max_popups]PopupState = [_]PopupState{.{}} ** max_popups;

pub fn run(config: RunConfig, callbacks: Callbacks) void {
    g_callbacks = callbacks;
    g_running = true;

    if (!sdl.SDL_Init(SDL_INIT_VIDEO)) return;

    g_main_window = sdl.SDL_CreateWindow(
        config.title,
        @intCast(config.width),
        @intCast(config.height),
        SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE,
    ) orelse return;

    g_main_gl_ctx = sdl.SDL_GL_CreateContext(g_main_window);
    _ = sdl.SDL_GL_MakeCurrent(g_main_window, g_main_gl_ctx);

    const ctx = Platform.renderer.current.vtable.init(std.heap.page_allocator) catch return;
    Platform.renderer.current.ctx = ctx;
    g_main_surface_id = Platform.renderer.current.vtable.createSurface(
        ctx,
        .{ .xlib = .{ .display = undefined, .window = 0 } },
    ) catch return;
    Platform.renderer.current.vtable.resizeSurface(
        ctx,
        g_main_surface_id,
        config.width,
        config.height,
    ) catch {};

    var w: c_int = 0;
    var h: c_int = 0;
    _ = sdl.SDL_GetWindowSize(g_main_window, &w, &h);
    g_main_window_id = sdl.SDL_GetWindowID(g_main_window);

    g_callbacks.init(g_callbacks.user_data);

    var ev: sdl.SDL_Event = undefined;
    while (g_running) {
        while (sdl.SDL_PollEvent(&ev)) {
            handleEvent(&ev);
        }

        // Render main window
        _ = sdl.SDL_GL_MakeCurrent(g_main_window, g_main_gl_ctx);
        Platform.renderer.current.beginFrame(g_main_surface_id) catch continue;
        g_callbacks.frame(g_callbacks.user_data);
        Platform.renderer.current.endFrame() catch continue;
        _ = sdl.SDL_GL_SwapWindow(g_main_window);

        // Render popup windows
        for (&g_popups) |*popup| {
            if (popup.active and popup.window != null) {
                _ = sdl.SDL_GL_MakeCurrent(popup.window, popup.gl_ctx);
                Platform.renderer.current.beginFrame(popup.surface_id) catch continue;
                popup.frame_fn(popup.user_data);
                Platform.renderer.current.endFrame() catch continue;
                _ = sdl.SDL_GL_SwapWindow(popup.window);
            }
        }
    }

    // Cleanup popups
    for (&g_popups) |*popup| {
        if (popup.active) {
            popup.event_fn(popup.user_data, .quit);
            Platform.renderer.current.vtable.destroySurface(
                Platform.renderer.current.ctx,
                popup.surface_id,
            );
            if (popup.gl_ctx) |gl| _ = sdl.SDL_GL_DestroyContext(gl);
            if (popup.window) |win| sdl.SDL_DestroyWindow(win);
            popup.active = false;
        }
    }

    g_callbacks.cleanup(g_callbacks.user_data);
    Platform.renderer.current.deinit();
    if (g_main_gl_ctx) |gl| _ = sdl.SDL_GL_DestroyContext(gl);
    if (g_main_window) |win| sdl.SDL_DestroyWindow(win);
    sdl.SDL_Quit();
}

pub fn quit() void {
    g_running = false;
}

pub fn pushOverlay() void {
    Platform.renderer.current.pushOverlay();
}

pub fn popOverlay() void {
    Platform.renderer.current.popOverlay();
}

pub fn openPopupWindow(
    ctx: ?*anyopaque,
    config: PopupConfig,
    frame_fn: *const fn (?*anyopaque) void,
    event_fn: *const fn (?*anyopaque, Event) void,
) void {
    for (&g_popups) |*popup| {
        if (!popup.active) {
            popup.window = sdl.SDL_CreatePopupWindow(
                g_main_window,
                0,
                0,
                @intCast(config.w),
                @intCast(config.h),
                SDL_WINDOW_OPENGL | SDL_WINDOW_TOOLTIP,
            ) orelse return;

            popup.gl_ctx = sdl.SDL_GL_CreateContext(popup.window);

            popup.surface_id = Platform.renderer.current.vtable.createSurface(
                Platform.renderer.current.ctx,
                .{ .xlib = .{ .display = undefined, .window = 0 } },
            ) catch return;
            Platform.renderer.current.vtable.resizeSurface(
                Platform.renderer.current.ctx,
                popup.surface_id,
                config.w,
                config.h,
            ) catch {};

            popup.frame_fn = frame_fn;
            popup.event_fn = event_fn;
            popup.user_data = ctx;
            popup.window_id = sdl.SDL_GetWindowID(popup.window);
            popup.active = true;
            return;
        }
    }
}

fn handleEvent(ev: *sdl.SDL_Event) void {
    const event_type: u32 = @intCast(ev.type);

    switch (event_type) {
        SDL_EVENT_QUIT => {
            g_running = false;
            g_callbacks.event(g_callbacks.user_data, .quit);
        },
        SDL_EVENT_KEY_DOWN => {
            const key = translateKey(ev.key.key);
            if (getEventWindowID(ev) == g_main_window_id) {
                g_callbacks.event(g_callbacks.user_data, .{ .key_down = key });
            } else {
                dispatchToPopup(ev, .{ .key_down = key });
            }
        },
        SDL_EVENT_KEY_UP => {
            const key = translateKey(ev.key.key);
            if (getEventWindowID(ev) == g_main_window_id) {
                g_callbacks.event(g_callbacks.user_data, .{ .key_up = key });
            } else {
                dispatchToPopup(ev, .{ .key_up = key });
            }
        },
        SDL_EVENT_MOUSE_MOTION => {
            const lu_ev = Event{ .mouse_move = .{ .x = ev.motion.x, .y = ev.motion.y } };
            if (getEventWindowID(ev) == g_main_window_id) {
                g_callbacks.event(g_callbacks.user_data, lu_ev);
            } else {
                dispatchToPopup(ev, lu_ev);
            }
        },
        SDL_EVENT_MOUSE_BUTTON_DOWN => {
            const btn = translateMouseButton(ev.button.button);
            const lu_ev = Event{ .mouse_down = btn };
            if (getEventWindowID(ev) == g_main_window_id) {
                g_callbacks.event(g_callbacks.user_data, lu_ev);
            } else {
                dispatchToPopup(ev, lu_ev);
            }
        },
        SDL_EVENT_MOUSE_BUTTON_UP => {
            const btn = translateMouseButton(ev.button.button);
            const lu_ev = Event{ .mouse_up = btn };
            if (getEventWindowID(ev) == g_main_window_id) {
                g_callbacks.event(g_callbacks.user_data, lu_ev);
            } else {
                dispatchToPopup(ev, lu_ev);
            }
        },
        SDL_EVENT_WINDOW_RESIZED => {
            const wid = ev.window.windowID;
            const new_w: u32 = @intCast(ev.window.data1);
            const new_h: u32 = @intCast(ev.window.data2);
            if (wid == g_main_window_id) {
                Platform.renderer.current.vtable.resizeSurface(
                    Platform.renderer.current.ctx,
                    g_main_surface_id,
                    new_w,
                    new_h,
                ) catch {};
                g_callbacks.event(g_callbacks.user_data, .{ .resized = .{ .width = new_w, .height = new_h } });
            } else {
                for (&g_popups) |*popup| {
                    if (popup.active and popup.window_id == wid) {
                        Platform.renderer.current.vtable.resizeSurface(
                            Platform.renderer.current.ctx,
                            popup.surface_id,
                            new_w,
                            new_h,
                        ) catch {};
                        break;
                    }
                }
            }
        },
        SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
            const wid = ev.window.windowID;
            if (wid != g_main_window_id) {
                for (&g_popups) |*popup| {
                    if (popup.active and popup.window_id == wid) {
                        popup.event_fn(popup.user_data, .quit);
                        Platform.renderer.current.vtable.destroySurface(
                            Platform.renderer.current.ctx,
                            popup.surface_id,
                        );
                        if (popup.gl_ctx) |gl| _ = sdl.SDL_GL_DestroyContext(gl);
                        if (popup.window) |win| sdl.SDL_DestroyWindow(win);
                        popup.active = false;
                        break;
                    }
                }
            }
        },
        else => {},
    }
}

fn dispatchToPopup(ev: *sdl.SDL_Event, lu_ev: Event) void {
    const wid = getEventWindowID(ev);
    for (&g_popups) |*popup| {
        if (popup.active and popup.window_id == wid) {
            popup.event_fn(popup.user_data, lu_ev);
            break;
        }
    }
}

fn getEventWindowID(ev: *sdl.SDL_Event) u32 {
    const event_type: u32 = @intCast(ev.type);
    return switch (event_type) {
        SDL_EVENT_KEY_DOWN, SDL_EVENT_KEY_UP => ev.key.windowID,
        SDL_EVENT_MOUSE_MOTION => ev.motion.windowID,
        SDL_EVENT_MOUSE_BUTTON_DOWN, SDL_EVENT_MOUSE_BUTTON_UP => ev.button.windowID,
        SDL_EVENT_WINDOW_RESIZED, SDL_EVENT_WINDOW_CLOSE_REQUESTED => ev.window.windowID,
        else => 0,
    };
}

fn translateKey(key: u32) Key {
    if (key >= 0x61 and key <= 0x7a) {
        return @enumFromInt(@intFromEnum(Key.a) + @as(u8, @intCast(key - 0x61)));
    }
    if (key >= 0x30 and key <= 0x39) {
        return @enumFromInt(@intFromEnum(Key.num0) + @as(u8, @intCast(key - 0x30)));
    }
    return switch (key) {
        0x1b => .escape,
        0x0d => .enter,
        0x08 => .backspace,
        0x09 => .tab,
        0x20 => .space,
        0x7f => .delete,
        0x2d => .minus,
        0x3d => .equal,
        0x5b => .left_bracket,
        0x5d => .right_bracket,
        0x5c => .backslash,
        0x3b => .semicolon,
        0x27 => .apostrophe,
        0x2c => .comma,
        0x2e => .period,
        0x2f => .slash,
        0x60 => .grave,
        0x4000004f => .right,
        0x40000050 => .left,
        0x40000051 => .down,
        0x40000052 => .up,
        0x40000049 => .insert,
        0x4000004a => .home,
        0x4000004b => .page_up,
        0x4000004d => .end,
        0x4000004e => .page_down,
        0x400000e0 => .left_ctrl,
        0x400000e1 => .left_shift,
        0x400000e2 => .left_alt,
        0x400000e3 => .left_super,
        0x400000e4 => .right_ctrl,
        0x400000e5 => .right_shift,
        0x400000e6 => .right_alt,
        0x400000e7 => .right_super,
        0x40000039 => .caps_lock,
        0x40000053 => .num_lock,
        0x40000047 => .scroll_lock,
        0x4000003a => .f1,
        0x4000003b => .f2,
        0x4000003c => .f3,
        0x4000003d => .f4,
        0x4000003e => .f5,
        0x4000003f => .f6,
        0x40000040 => .f7,
        0x40000041 => .f8,
        0x40000042 => .f9,
        0x40000043 => .f10,
        0x40000044 => .f11,
        0x40000045 => .f12,
        0x40000046 => .print_screen,
        0x40000048 => .pause,
        0x40000076 => .menu,
        else => .unknown,
    };
}

fn translateMouseButton(button: u8) MouseButton {
    return switch (button) {
        1 => .left,
        3 => .right,
        2 => .scroll,
        else => .left,
    };
}

pub const Rect = struct {
    w: u32,
    h: u32,
};

pub const Pos = struct {
    x: u32,
    y: u32,
};

pub const Sides = struct {
    top: u32,
    bottom: u32,
    left: u32,
    right: u32,

    pub fn all(n: u32) Corners {
        return .{
            .top = n,
            .bottom = n,
            .left = n,
            .right = n,
        };
    }
};

pub const Corners = struct {
    top_left: u32,
    top_right: u32,
    bottom_left: u32,
    bottom_right: u32,

    pub fn all(n: u32) Corners {
        return .{
            .top_left = n,
            .top_right = n,
            .bottom_left = n,
            .bottom_right = n,
        };
    }
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const alice_blue: Color = .fromU32(0xF0F8FF);
    pub const antique_white: Color = .fromU32(0xFAEBD7);
    pub const aqua: Color = .fromU32(0x00FFFF);
    pub const aquamarine: Color = .fromU32(0x7FFFD4);
    pub const azure: Color = .fromU32(0xF0FFFF);
    pub const beige: Color = .fromU32(0xF5F5DC);
    pub const bisque: Color = .fromU32(0xFFE4C4);
    pub const black: Color = .fromU32(0x000000);
    pub const blanched_almond: Color = .fromU32(0xFFEBCD);
    pub const blue: Color = .fromU32(0x0000FF);
    pub const blue_violet: Color = .fromU32(0x8A2BE2);
    pub const brown: Color = .fromU32(0xA52A2A);
    pub const burlywood: Color = .fromU32(0xDEB887);
    pub const cadet_blue: Color = .fromU32(0x5F9EA0);
    pub const chartreuse: Color = .fromU32(0x7FFF00);
    pub const chocolate: Color = .fromU32(0xD2691E);
    pub const coral: Color = .fromU32(0xFF7F50);
    pub const cornflower_blue: Color = .fromU32(0x6495ED);
    pub const cornsilk: Color = .fromU32(0xFFF8DC);
    pub const crimson: Color = .fromU32(0xDC143C);
    pub const cyan: Color = .fromU32(0x00FFFF);
    pub const dark_blue: Color = .fromU32(0x00008B);
    pub const dark_cyan: Color = .fromU32(0x008B8B);
    pub const dark_goldenrod: Color = .fromU32(0xB8860B);
    pub const dark_gray: Color = .fromU32(0xA9A9A9);
    pub const dark_green: Color = .fromU32(0x006400);
    pub const dark_khaki: Color = .fromU32(0xBDB76B);
    pub const dark_magenta: Color = .fromU32(0x8B008B);
    pub const dark_olive_green: Color = .fromU32(0x556B2F);
    pub const dark_orange: Color = .fromU32(0xFF8C00);
    pub const dark_orchid: Color = .fromU32(0x9932CC);
    pub const dark_red: Color = .fromU32(0x8B0000);
    pub const dark_salmon: Color = .fromU32(0xE9967A);
    pub const dark_sea_green: Color = .fromU32(0x8FBC8F);
    pub const dark_slate_blue: Color = .fromU32(0x483D8B);
    pub const dark_slate_gray: Color = .fromU32(0x2F4F4F);
    pub const dark_turquoise: Color = .fromU32(0x00CED1);
    pub const dark_violet: Color = .fromU32(0x9400D3);
    pub const deep_pink: Color = .fromU32(0xFF1493);
    pub const deep_sky_blue: Color = .fromU32(0x00BFFF);
    pub const dim_gray: Color = .fromU32(0x696969);
    pub const dodger_blue: Color = .fromU32(0x1E90FF);
    pub const firebrick: Color = .fromU32(0xB22222);
    pub const floral_white: Color = .fromU32(0xFFFAF0);
    pub const forest_green: Color = .fromU32(0x228B22);
    pub const fuchsia: Color = .fromU32(0xFF00FF);
    pub const gainsboro: Color = .fromU32(0xDCDCDC);
    pub const ghost_white: Color = .fromU32(0xF8F8FF);
    pub const gold: Color = .fromU32(0xFFD700);
    pub const goldenrod: Color = .fromU32(0xDAA520);
    pub const gray: Color = .fromU32(0x808080);
    pub const green: Color = .fromU32(0x008000);
    pub const green_yellow: Color = .fromU32(0xADFF2F);
    pub const honeydew: Color = .fromU32(0xF0FFF0);
    pub const hot_pink: Color = .fromU32(0xFF69B4);
    pub const indian_red: Color = .fromU32(0xCD5C5C);
    pub const indigo: Color = .fromU32(0x4B0082);
    pub const ivory: Color = .fromU32(0xFFFFF0);
    pub const khaki: Color = .fromU32(0xF0E68C);
    pub const lavender: Color = .fromU32(0xE6E6FA);
    pub const lavender_blush: Color = .fromU32(0xFFF0F5);
    pub const lawn_green: Color = .fromU32(0x7CFC00);
    pub const lemon_chiffon: Color = .fromU32(0xFFFACD);
    pub const light_blue: Color = .fromU32(0xADD8E6);
    pub const light_coral: Color = .fromU32(0xF08080);
    pub const light_cyan: Color = .fromU32(0xE0FFFF);
    pub const light_goldenrod_yellow: Color = .fromU32(0xFAFAD2);
    pub const light_gray: Color = .fromU32(0xD3D3D3);
    pub const light_green: Color = .fromU32(0x90EE90);
    pub const light_pink: Color = .fromU32(0xFFB6C1);
    pub const light_salmon: Color = .fromU32(0xFFA07A);
    pub const light_sea_green: Color = .fromU32(0x20B2AA);
    pub const light_sky_blue: Color = .fromU32(0x87CEFA);
    pub const light_slate_gray: Color = .fromU32(0x778899);
    pub const light_steel_blue: Color = .fromU32(0xB0C4DE);
    pub const light_yellow: Color = .fromU32(0xFFFFE0);
    pub const lime: Color = .fromU32(0x00FF00);
    pub const lime_green: Color = .fromU32(0x32CD32);
    pub const linen: Color = .fromU32(0xFAF0E6);
    pub const magenta: Color = .fromU32(0xFF00FF);
    pub const maroon: Color = .fromU32(0x800000);
    pub const medium_aquamarine: Color = .fromU32(0x66CDAA);
    pub const medium_blue: Color = .fromU32(0x0000CD);
    pub const medium_orchid: Color = .fromU32(0xBA55D3);
    pub const medium_purple: Color = .fromU32(0x9370DB);
    pub const medium_sea_green: Color = .fromU32(0x3CB371);
    pub const medium_slate_blue: Color = .fromU32(0x7B68EE);
    pub const medium_spring_green: Color = .fromU32(0x00FA9A);
    pub const medium_turquoise: Color = .fromU32(0x48D1CC);
    pub const medium_violet_red: Color = .fromU32(0xC71585);
    pub const midnight_blue: Color = .fromU32(0x191970);
    pub const mint_cream: Color = .fromU32(0xF5FFFA);
    pub const misty_rose: Color = .fromU32(0xFFE4E1);
    pub const moccasin: Color = .fromU32(0xFFE4B5);
    pub const navajo_white: Color = .fromU32(0xFFDEAD);
    pub const navy: Color = .fromU32(0x000080);
    pub const old_lace: Color = .fromU32(0xFDF5E6);
    pub const olive: Color = .fromU32(0x808000);
    pub const olive_drab: Color = .fromU32(0x6B8E23);
    pub const orange: Color = .fromU32(0xFFA500);
    pub const orange_red: Color = .fromU32(0xFF4500);
    pub const orchid: Color = .fromU32(0xDA70D6);
    pub const pale_goldenrod: Color = .fromU32(0xEEE8AA);
    pub const pale_green: Color = .fromU32(0x98FB98);
    pub const pale_turquoise: Color = .fromU32(0xAFEEEE);
    pub const pale_violet_red: Color = .fromU32(0xDB7093);
    pub const papaya_whip: Color = .fromU32(0xFFEFD5);
    pub const peach_puff: Color = .fromU32(0xFFDAB9);
    pub const peru: Color = .fromU32(0xCD853F);
    pub const pink: Color = .fromU32(0xFFC0CB);
    pub const plum: Color = .fromU32(0xDDA0DD);
    pub const powder_blue: Color = .fromU32(0xB0E0E6);
    pub const purple: Color = .fromU32(0x800080);
    pub const red: Color = .fromU32(0xFF0000);
    pub const rosy_brown: Color = .fromU32(0xBC8F8F);
    pub const royal_blue: Color = .fromU32(0x4169E1);
    pub const saddle_brown: Color = .fromU32(0x8B4513);
    pub const salmon: Color = .fromU32(0xFA8072);
    pub const sandy_brown: Color = .fromU32(0xF4A460);
    pub const sea_green: Color = .fromU32(0x2E8B57);
    pub const seashell: Color = .fromU32(0xFFF5EE);
    pub const sienna: Color = .fromU32(0xA0522D);
    pub const silver: Color = .fromU32(0xC0C0C0);
    pub const sky_blue: Color = .fromU32(0x87CEEB);
    pub const slate_blue: Color = .fromU32(0x6A5ACD);
    pub const slate_gray: Color = .fromU32(0x708090);
    pub const snow: Color = .fromU32(0xFFFAFA);
    pub const spring_green: Color = .fromU32(0x00FF7F);
    pub const steel_blue: Color = .fromU32(0x4682B4);
    pub const tan: Color = .fromU32(0xD2B48C);
    pub const teal: Color = .fromU32(0x008080);
    pub const thistle: Color = .fromU32(0xD8BFD8);
    pub const tomato: Color = .fromU32(0xFF6347);
    pub const turquoise: Color = .fromU32(0x40E0D0);
    pub const violet: Color = .fromU32(0xEE82EE);
    pub const wheat: Color = .fromU32(0xF5DEB3);
    pub const white: Color = .fromU32(0xFFFFFF);
    pub const white_smoke: Color = .fromU32(0xF5F5F5);
    pub const yellow: Color = .fromU32(0xFFFF00);
    pub const yellow_green: Color = .fromU32(0x9ACD32);

    pub fn toU32(self: *Color) void {
        return (@as(u32, @intCast(self.r)) << 24) |
            (@as(u32, @intCast(self.g)) << 16) |
            (@as(u32, @intCast(self.b)) << 8) |
            (@as(u32, @intCast(self.a)));
    }

    pub fn fromU32(n: u32) Color {
        return .{
            .r = @truncate(n >> 24),
            .g = @truncate(n >> 16),
            .b = @truncate(n >> 8),
            .a = @truncate(n),
        };
    }
};

pub const Image = struct {};

pub const Gradient = struct {};

pub const Effect = union(enum) {
    blur: Blur,
    opacity: f64,

    pub const Blur = struct {};
};

pub const Background = struct {
    base: Base,
    effects: []Effect,

    pub const Base = union(enum) {
        image: Image,
        gradient: Gradient,
        solid: Color,
    };

    pub fn solid(c: Color) Background {
        return .{
            .base = .{ .solid = c },
            .effects = &.{},
        };
    }
};

pub fn Hook(comptime T: type) type {
    return struct {
        handle: Handle,

        const Self = @This();

        pub const Handle = union(enum) {
            fptrs: []Fn,

            pub const Fn = struct {
                data: *anyopaque,
                func: *const fn (*anyopaque, T) void,
            };
        };

        pub fn run(self: *Self, data: T) void {
            switch (self.handle) {
                .fptrs => |ps| {
                    for (ps) |p| {
                        p.func(p.data, data);
                    }
                },
            }
        }

        pub fn isEnabled(self: *Self) bool {
            return blk: switch (self.handle) {
                .fptrs => |ps| {
                    break :blk ps.len != 0;
                },
            };
        }
    };
}

pub const MouseButton = enum {
    scroll,
    left,
    right,
};

// zig fmt: off
pub const Key = enum {
    a, b, c, d, e, f, g, h, i, j, k, l, m,
    n, o, p, q, r, s, t, u, v, w, x, y, z,

    num0, num1, num2, num3, num4,
    num5, num6, num7, num8, num9,

    f1, f2, f3, f4, f5, f6,
    f7, f8, f9, f10, f11, f12,

    kp0, kp1, kp2, kp3, kp4,
    kp5, kp6, kp7, kp8, kp9,

    kp_decimal,
    kp_add,
    kp_subtract,
    kp_multiply,
    kp_divide,
    kp_enter,

    left,
    right,
    up,
    down,

    left_shift,
    right_shift,
    left_ctrl,
    right_ctrl,
    left_alt,
    right_alt,
    left_super,
    right_super,

    caps_lock,
    num_lock,
    scroll_lock,

    insert,
    delete,
    home,
    end,
    page_up,
    page_down,

    backspace,
    enter,
    tab,
    escape,
    space,

    grave,
    minus,
    equal,
    left_bracket,
    right_bracket,
    backslash,
    semicolon,
    apostrophe,
    comma,
    period,
    slash,

    print_screen,
    pause,
    menu,

    unknown,
};
// zig fmt: on
