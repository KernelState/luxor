const std = @import("std");
const sdl = if (options.sdl) @import("sdl") else @import("std");
const options = @import("options");

pub const Element = @import("Element.zig");
pub const Layout = @import("Layout.zig").Layout;
pub const Window = if (options.sdl)
    @import("Window.zig")
else
    @compileError("Window.zig does not exist");
pub const Context = if (options.widgets)
    @import("Context.zig")
else
    @compileError("Context.zig does not exist");
/// A fixed-buffer hash-map cache for memoizing expensive work (rasterized text,
/// decoded images) keyed by a hash of its input.
pub const Cache = @import("Cache.zig");
/// A self-contained frame profiler (FPS + per-phase timings). The Window owns
/// one of these via `Window.debug` and reference-counts it.
pub const Debug = @import("Debug.zig");
/// Image decoding + caching (PNG/JPEG/WebP/SVG). `images` is the decode module;
/// `Image` is the registered-texture reference type.
pub const images = if (options.images)
    @import("Image.zig")
else
    @compileError("Image.zig requires the 'images' build option");

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

    pub fn toSDL(self: *const Area) sdl.SDL_Rect {
        if (!options.sdl) @compileError("SDL support is disabled");
        return .{
            .x = @intCast(self.pos.x),
            .y = @intCast(self.pos.y),
            .w = @intCast(self.size.w),
            .h = @intCast(self.size.h),
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
    pub const white = Color.fromU32(0xFFFFFFFF);
    pub const red = Color.fromU32(0xFF0000FF);
    pub const green = Color.fromU32(0x00FF00FF);
    pub const blue = Color.fromU32(0x0000FFFF);
    pub const gray = Color.fromU32(0x808080FF);
    pub const dark_gray = Color.fromU32(0x333333FF);
};

/// An image background, referencing a texture registered on the window.
pub const Image = struct {
    id: usize,
    /// Optional source region inside the texture, in texture pixels.
    src: ?Area = null,
};

/// A CPU-side pixel buffer (RGBA8888). The Window uploads this to a texture
/// when drawing the element.
pub const PixelBuffer = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
};
/// A color stop of a `Gradient`. Positions are floats in the 0.0 to 1.0 space
/// of the drawing area; the actual pixel position is
/// `floor(pos * drawing area size) + drawing area position`.
pub const GradientPoint = struct {
    x: f32,
    y: f32,
    color: Color,
};

/// A multi-point gradient. The background or border transitions smoothly
/// between every `points` color, weighted by the distance to each point.
pub const Gradient = struct {
    points: []const GradientPoint,
    /// Multiplies the alpha of every point color.
    opacity: f32 = 1.0,
};

/// What the border is painted with: a flat color or a gradient.
/// The gradient coordinates are relative to the element's full area, the
/// smallest rectangle that contains all of the border shapes.
pub const Border = union(enum) {
    color: Color,
    gradient: Gradient,
};

pub const Effect = union(enum) {
    blur: Blur,
    opacity: f64,
    pub const Blur = struct {
        radius: u32 = 8,
    };
};

/// How an image buffer is scaled into its drawing area.
pub const ImageFit = enum {
    /// Stretch to fill the area, ignoring the aspect ratio.
    stretch,
    /// Scale to fit inside the area, preserving the aspect ratio. Some of the
    /// area may be uncovered (transparent) on the longer dimension.
    contain,
    /// Scale to fill the area, preserving the aspect ratio. The image is
    /// centered and cropped on the longer dimension.
    cover,
};

/// How a texture is sampled when it is scaled.
pub const Filter = enum {
    linear,
    nearest,
};

/// An image background that scales a decoded RGBA buffer with an `ImageFit`.
pub const Buffer8 = struct {
    buffer: PixelBuffer,
    fit: ImageFit = .stretch,
    filter: Filter = .linear,
};

/// The raw data of an image before decoding. `buffer` is already-decoded
/// RGBA8888 pixels; the others are encoded bytes produced by an image-widget
/// function and are decoded (once, cached) into a pixel buffer.
pub const ImageSource = union(enum) {
    buffer: PixelBuffer,
    png: []const u8,
    jpeg: []const u8,
    webp: []const u8,
    svg: []const u8,
};

pub const Background = struct {
    base: Base,
    effects: []const Effect,

    pub const Base = union(enum) {
        image: Image,
        gradient: Gradient,
        solid: Color,
        buffer: PixelBuffer,
        image_buffer: Buffer8,
        /// A texture that the host Window owns and persists across frames, looked
        /// up by the element's stable id. Avoids re-uploading (and for text,
        /// re-rasterizing) the same element every frame.
        cached: Cached,
    };

    pub const Cached = struct {
        key: u64,
    };

    pub fn solid(c: Color) Background {
        return .{ .base = .{ .solid = c }, .effects = &.{} };
    }

    pub fn gradient(g: Gradient) Background {
        return .{ .base = .{ .gradient = g }, .effects = &.{} };
    }

    pub fn image(img: Image) Background {
        return .{ .base = .{ .image = img }, .effects = &.{} };
    }

    pub fn buffer(pb: PixelBuffer) Background {
        return .{ .base = .{ .buffer = pb }, .effects = &.{} };
    }

    pub fn imageBuffer(img: Buffer8) Background {
        return .{ .base = .{ .image_buffer = img }, .effects = &.{} };
    }

    pub fn cached(key: u64) Background {
        return .{ .base = .{ .cached = .{ .key = key } }, .effects = &.{} };
    }
};

pub fn Hook(comptime T: type) type {
    return struct {
        handle: ?Handle = null,
        active: bool = false,

        const Self = @This();
        pub const Handle = union(enum) {
            fptrs: []Fn,
            pub const Fn = struct {
                data: *anyopaque,
                func: *const fn (*anyopaque, T, bool) void,
            };
        };

        pub fn activate(self: *Self, data: T) void {
            self.active = true;
            if (self.handle) |h| {
                switch (h) {
                    .fptrs => |ps| {
                        for (ps) |p| p.func(p.data, data, true);
                    },
                }
            }
        }

        pub fn deactivate(self: *Self, data: T) void {
            self.active = false;
            if (self.handle) |h| {
                switch (h) {
                    .fptrs => |ps| {
                        for (ps) |p| p.func(p.data, data, false);
                    },
                }
            }
        }

        pub fn isEnabled(self: *Self) bool {
            return blk: switch (self.handle) {
                .fptrs => |ps| break :blk ps.len != 0,
            };
        }
    };
}
