pub const sokol = @import("sokol");
const std = @import("std");

pub const Element = @import("Element.zig");
pub const Layout = @import("Layout.zig");
pub const Window = @import("Window.zig");
pub const Platform = @import("Platform.zig");

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
