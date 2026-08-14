const std = @import("std");
const sdl = if (options.sdl) @import("sdl") else @import("std");
const options = @import("options");

pub const Element = @import("Element.zig");
pub const Layout = @import("Layout.zig").Layout;
/// Per-layout capacity: the maximum requests/children a single layout can hold.
pub const LayoutInner = @import("Layout.zig").Inner;
/// Size of the working scratch buffers used while laying out a container.
pub const LayoutMax = @import("Layout.zig").Max;
/// Maximum elements the `Context` element pool (see `Context.PoolN`) can hold
/// before a frame must call `clear`.
pub const PoolN = @import("options").pool;
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

/// A signed point used for element-relative coordinates (the pointer offset from
/// an element's top-left corner, or a drag's current pointer offset from where
/// the drag started). May be negative when the pointer is left/above the origin.
pub const Offset = struct {
    x: i32,
    y: i32,
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

/// The draw-time shape of an element: world position, size and border radius.
/// Per-element caches (shadow rasters, blur backdrops, baked gradient textures)
/// hash the fields that determine the pixels, so a rebuilt element that lands
/// on the same shape reuses the previous frame's texture instead of re-rasterizing
/// and re-uploading. Shadow pixels do not depend on the position (the raster is
/// drawn as-is and SDL clips it), so shadow keys drop `pos`; blur backdrops key
/// on it because their content is anchored to the element's screen location.
pub const Geometry = struct {
    pos: Pos,
    size: Rect,
    radius: Corners,

    pub fn fromElement(e: *const Element, area: Area) Geometry {
        return .{ .pos = area.pos, .size = area.size, .radius = e.border_radius };
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
    shadow: Shadow,
    pub const Blur = struct {
        radius: u32 = 8,
        /// Like CSS `filter: saturate()`. `1.0` keeps colors unchanged, `0.0`
        /// draws the backdrop in grayscale, values above `1.0` oversaturate.
        saturation: f32 = 1.0,
    };
    /// A box shadow: a blurred silhouette of the element's box, drawn with
    /// the given color either behind the element (`out`) or inside it (`in`).
    pub const Shadow = struct {
        /// Where the shadow sits relative to the element:
        /// `out` drops it behind the element (a drop shadow),
        /// `in` draws it on top of the element's background inside its box
        /// (an inner glow / inset shadow).
        mask: ShadowMask = .out,
        /// The color the shadow is painted with. Defaults to black at 50%
        /// opacity.
        color: Color = .{ .r = 0, .g = 0, .b = 0, .a = 128 },
        /// Horizontal shift, in screen pixels, from the element's top-left
        /// corner.
        x_offset: f32 = 0,
        /// Vertical shift, in screen pixels, from the element's top-left
        /// corner.
        y_offset: f32 = 0,
        /// How much the shadow shape is enlarged (positive) or shrunk
        /// (negative) relative to the element's own box.
        spread: f32 = 0,
        /// Blur strength in pixels.
        blur: f32 = 8,

        pub const ShadowMask = enum {
            in,
            out,
        };
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

/// Per-frame event state for the view (the window). The Window's post-draw
/// processing pass rewrites this struct every frame from the SDL events it
/// pumped; widgets read it when they initialize elements, so an element's
/// `active` state reflects last frame while the hook callbacks fire (during the
/// processing pass) and their effects appear next frame.
///
/// Element-specific events live in per-interaction lists of stable element ids
/// (`hovered`, `clicked`, `focused`, `dragged`), each carrying element-relative
/// data; the `is*` methods interrogate them by id. Non-element-specific events
/// carry their data only.
pub const View = struct {
    /// The element under the pointer last frame, with the pointer offset from
    /// the element's own top-left corner.
    hovered: std.ArrayListUnmanaged(Entry.Id) = .empty,
    /// Elements with a click in progress last frame (a press that hasn't
    /// released into them), with the press pointer offset from the element.
    clicked: std.ArrayListUnmanaged(Entry.Id) = .empty,
    /// Elements that owned keyboard focus last frame, tagged by how it was
    /// granted (keyboard vs mouse).
    focused: std.ArrayListUnmanaged(Entry.Focus) = .empty,
    /// Elements being dragged last frame, with the current pointer offset from
    /// where the drag started.
    dragged: std.ArrayListUnmanaged(Entry.Id) = .empty,
    /// Current pointer position in window coordinates.
    pointer: Pos = .{ .x = 0, .y = 0 },
    /// Whether the pointer is inside the window.
    pointer_inside: bool = false,
    /// Whether the pointer moved since the last processed frame.
    mouse_moved: bool = false,
    /// New window size when the window was resized since the last frame.
    resized: ?Rect = null,
    /// The key of the last key edge; `key_down` tells which edge it was.
    key: ?Key = null,
    key_down: bool = false,
    /// Whether the window was asked to close.
    exit: bool = false,

    /// True when `id` was under the pointer last frame; returns the pointer
    /// offset from the element's top-left corner when it was.
    pub fn isHovered(self: *const View, id: u64) ?Offset {
        return lookup(self.hovered.items, id);
    }

    /// True when `id` had a click in progress last frame; returns the press
    /// pointer offset from the element's top-left corner when it did.
    pub fn isClicked(self: *const View, id: u64) ?Offset {
        return lookup(self.clicked.items, id);
    }

    /// True when `id` owned keyboard focus last frame; returns how that focus
    /// was granted (keyboard or mouse) when it did.
    pub fn isFocused(self: *const View, id: u64) ?FocusSource {
        const idx = indexOfId(Entry.Focus, self.focused.items, id) orelse return null;
        return self.focused.items[idx].source;
    }

    /// True when `id` was being dragged last frame; returns the current pointer
    /// offset from where the drag started when it was.
    pub fn isDragged(self: *const View, id: u64) ?Offset {
        const idx = indexOfId(Entry.Id, self.dragged.items, id) orelse return null;
        return self.dragged.items[idx].local;
    }

    /// Clears every per-element interaction list, retaining capacity so the
    /// next frame's processing pass can repopulate them without reallocating.
    pub fn reset(self: *View) void {
        self.hovered.clearRetainingCapacity();
        self.clicked.clearRetainingCapacity();
        self.focused.clearRetainingCapacity();
        self.dragged.clearRetainingCapacity();
    }

    /// Releases the backing buffers of every per-element interaction list.
    /// Called with the allocator they were allocated from.
    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.hovered.deinit(allocator);
        self.clicked.deinit(allocator);
        self.focused.deinit(allocator);
        self.dragged.deinit(allocator);
    }
};

/// Shared shapes of the records the `View` lists hold. All are *unmanaged*
/// (no allocator stored); the processing pass owns their lifetime.
pub const Entry = struct {
    /// An element id plus an element-relative pointer offset: the shape of
    /// `hovered` and `clicked` entries.
    pub const Id = struct {
        id: u64,
        local: Offset = .{ .x = 0, .y = 0 },
    };

    /// How an element came to own keyboard focus.
    pub const Focus = struct {
        id: u64,
        source: FocusSource,
    };
};

/// How an element came to own keyboard focus.
pub const FocusSource = enum {
    keyboard,
    mouse,
};

/// Returns the `local` payload of the entry with id `id`, or null.
fn lookup(entries: []const Entry.Id, id: u64) ?Offset {
    const i = indexOfId(Entry.Id, entries, id) orelse return null;
    return entries[i].local;
}

/// Returns the index of the entry with id `id`, or null.
fn indexOfId(comptime T: type, entries: []const T, id: u64) ?usize {
    for (entries, 0..) |e, i| if (e.id == id) return i;
    return null;
}

pub fn Hook(comptime T: type) type {
    return struct {
        handle: ?Handle = null,
        active: bool = false,

        const Self = @This();
        pub const Handle = union(enum) {
            fptrs: []const Fn,
            pub const Fn = struct {
                data: *anyopaque,
                func: *const fn (*anyopaque, T, bool) void,
            };
        };

        /// Marks the hook active and fires the handlers with `true`. The
        /// processing pass calls this when an event *enters* the element (a
        /// hover enter, a press, a focus grant, a drag start), so the handlers
        /// see the edge, not a per-frame repeat. `active` is the render state
        /// widgets read during their build.
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

        /// Marks the hook inactive and fires the handlers with `false`. The
        /// processing pass calls this when the event *leaves* the element.
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

        /// Sets `active` without firing the handlers. Called by widgets when an
        /// element is initialized (after the user's overrides): `active` is
        /// re-derived every frame from the view's per-element lists (`is*`), so
        /// the element renders last frame's interaction state while the hook
        /// callbacks fired by the processing pass take effect next frame.
        pub fn setActive(self: *Self, active: bool) void {
            self.active = active;
        }

        /// Fires the handlers with the current `active` state, without changing
        /// it. Used for notifications that report progress on an interaction
        /// that is already engaged (a drag start, a finished frame).
        pub fn emit(self: *Self, data: T) void {
            if (self.handle) |h| {
                switch (h) {
                    .fptrs => |ps| {
                        for (ps) |p| p.func(p.data, data, self.active);
                    },
                }
            }
        }

        pub fn isEnabled(self: *Self) bool {
            return if (self.handle) |h| switch (h) {
                .fptrs => |ps| ps.len != 0,
            } else false;
        }
    };
}

test "isHovered/isClicked return the element-relative offset" {
    var view = View{};
    defer view.deinit(std.testing.allocator);

    try view.hovered.append(std.testing.allocator, .{ .id = 7, .local = .{ .x = 3, .y = 5 } });
    try view.clicked.append(std.testing.allocator, .{ .id = 9, .local = .{ .x = -2, .y = 4 } });

    const ho = view.isHovered(7).?;
    try std.testing.expectEqual(@as(i32, 3), ho.x);
    try std.testing.expectEqual(@as(i32, 5), ho.y);
    const cl = view.isClicked(9).?;
    try std.testing.expectEqual(@as(i32, -2), cl.x);
    try std.testing.expectEqual(@as(i32, 4), cl.y);
    try std.testing.expectEqual(@as(?Offset, null), view.isHovered(99));
    try std.testing.expectEqual(@as(?Offset, null), view.isClicked(7));
}

test "isDragged returns the offset from the drag origin" {
    var view = View{};
    defer view.deinit(std.testing.allocator);

    try view.dragged.append(std.testing.allocator, .{ .id = 12, .local = .{ .x = 8, .y = -6 } });
    const off = view.isDragged(12).?;
    try std.testing.expectEqual(@as(i32, 8), off.x);
    try std.testing.expectEqual(@as(i32, -6), off.y);
    try std.testing.expectEqual(@as(?Offset, null), view.isDragged(13));
}

test "isFocused returns the focus source and reset clears every list" {
    var view = View{};
    defer view.deinit(std.testing.allocator);

    try view.hovered.append(std.testing.allocator, .{ .id = 1, .local = .{ .x = 0, .y = 0 } });
    try view.focused.append(std.testing.allocator, .{ .id = 2, .source = .keyboard });
    try view.dragged.append(std.testing.allocator, .{ .id = 3, .local = .{ .x = 0, .y = 0 } });

    try std.testing.expectEqual(@as(?FocusSource, .keyboard), view.isFocused(2));
    try std.testing.expectEqual(@as(?FocusSource, null), view.isFocused(9));

    view.reset();
    try std.testing.expectEqual(@as(?Offset, null), view.isHovered(1));
    try std.testing.expectEqual(@as(?FocusSource, null), view.isFocused(2));
    try std.testing.expectEqual(@as(?Offset, null), view.isDragged(3));
}

test "entry lookup keeps first matching id" {
    var view = View{};
    defer view.deinit(std.testing.allocator);

    try view.clicked.append(std.testing.allocator, .{ .id = 4, .local = .{ .x = 1, .y = 1 } });
    try view.clicked.append(std.testing.allocator, .{ .id = 4, .local = .{ .x = 9, .y = 9 } });
    const off = view.isClicked(4).?;
    try std.testing.expectEqual(@as(i32, 1), off.x);
}

test "hook activate/deactivate set active and fire handlers on the edge only" {
    const HState = struct {
        fired: [4]bool,
        actives: [4]bool,
        i: u8,
    };
    const fired: [4]bool = .{ false } ** 4;
    const actives: [4]bool = .{ false } ** 4;
    var state = HState{ .fired = fired, .actives = actives, .i = 0 };
    const Ctx = struct {
        fn f(data: *anyopaque, _: Offset, active: bool) void {
            const st: *HState = @ptrCast(@alignCast(data));
            st.fired[st.i] = true;
            st.actives[st.i] = active;
            st.i += 1;
        }
    };
    var hook: Hook(Offset) = .{ .handle = .{ .fptrs = &.{.{ .data = &state, .func = &Ctx.f }} } };

    hook.activate(.{ .x = 1, .y = 2 });
    try std.testing.expect(hook.active);
    try std.testing.expectEqual(@as(u8, 1), state.i);
    try std.testing.expect(state.fired[0] and state.actives[0]);

    hook.activate(.{ .x = 3, .y = 4 });
    try std.testing.expect(hook.active);
    try std.testing.expectEqual(@as(u8, 2), state.i);

    hook.setActive(false);
    try std.testing.expect(!hook.active);
    try std.testing.expectEqual(@as(u8, 2), state.i);

    hook.deactivate(.{ .x = 5, .y = 6 });
    try std.testing.expect(!hook.active);
    try std.testing.expectEqual(@as(u8, 3), state.i);
    try std.testing.expect(state.fired[2] and !state.actives[2]);

    hook.deactivate(.{ .x = 7, .y = 8 });
    try std.testing.expectEqual(@as(u8, 4), state.i);
}
