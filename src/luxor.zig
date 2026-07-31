const std = @import("std");
const sdl = @import("sdl");
const options = @import("options");

pub const Element = @import("Element.zig");
pub const Layout = @import("Layout.zig");
pub const Window = if (options.vulkan)
    @import("Window.zig")
else
    @compileError("Window.zig does not exist");

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
};

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
    kp_decimal, kp_add, kp_subtract, kp_multiply, kp_divide, kp_enter,
    left, right, up, down,
    left_shift, right_shift, left_ctrl, right_ctrl,
    left_alt, right_alt, left_super, right_super,
    caps_lock, num_lock, scroll_lock,
    insert, delete, home, end, page_up, page_down,
    backspace, enter, tab, escape, space,
    grave, minus, equal, left_bracket, right_bracket,
    backslash, semicolon, apostrophe, comma, period, slash,
    print_screen, pause, menu,
    unknown,
};
// zig fmt: on

pub const Rect = struct {
    w: u32,
    h: u32,
};

pub const Pos = struct {
    x: u32,
    y: u32,
};

pub const Area = struct {
    size: Rect,
    pos: Pos,

    pub fn toSDL(self: *Area) sdl.SDL_Rect {
        return .{
            .x = self.pos.x,
            .y = self.pos.y,
            .w = self.size.w,
            .h = self.size.h,
        };
    }
};

pub const Sides = struct {
    top: u32,
    bottom: u32,
    left: u32,
    right: u32,

    pub fn all(n: u32) Sides {
        return .{ .top = n, .bottom = n, .left = n, .right = n };
    }
};

pub const Corners = struct {
    top_left: u32,
    top_right: u32,
    bottom_left: u32,
    bottom_right: u32,

    pub fn all(n: u32) Corners {
        return .{ .top_left = n, .top_right = n, .bottom_left = n, .bottom_right = n };
    }
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn fromU32(n: u32) Color {
        return .{
            .r = @truncate(n >> 24),
            .g = @truncate(n >> 16),
            .b = @truncate(n >> 8),
            .a = @truncate(n),
        };
    }

    pub const black = Color.fromU32(0x000000FF);
    pub const white = Color.fromU32(0xFFFFFF);
    pub const red = Color.fromU32(0xFF0000);
    pub const green = Color.fromU32(0x00FF00);
    pub const blue = Color.fromU32(0x0000FF);
    pub const gray = Color.fromU32(0x808080);
    pub const dark_gray = Color.fromU32(0x333333FF);
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
        return .{ .base = .{ .solid = c }, .effects = &.{} };
    }
};

pub fn Hook(comptime T: type) type {
    return struct {
        handle: ?Handle,
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
                    for (ps) |p| p.func(p.data, data);
                },
            }
        }
        pub fn isEnabled(self: *Self) bool {
            return blk: switch (self.handle) {
                .fptrs => |ps| break :blk ps.len != 0,
            };
        }
    };
}
