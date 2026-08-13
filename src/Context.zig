/// This is just a simple collection of widgets that you can easily replace
/// and make your own `Element` generators
///
/// This is not the widget itself, the name might be misleading because this is
/// just a simple collection of data that the widgets will use, you need only
/// one of these per application, it's more like a piece of context.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const lu = @import("luxor.zig");
const c = @cImport({
    @cInclude("freetype2/freetype/freetype.h");
    @cInclude("freetype2/freetype/ftoutln.h");
    @cInclude("harfbuzz/hb.h");
    @cInclude("harfbuzz/hb-ft.h");
});

/// Bytes of `fba_buf` dedicated to long-lived allocations: the window's batch
/// render buffers, its per-frame scratch pool, and text/image cache raster
/// buffers. The per-frame `frame_arena` gets the remaining (high) bytes. The
/// regions are separate because the frame side is reset wholesale every frame
/// and the persistent side must survive those resets: `FixedBufferAllocator.free`
/// only reclaims the last allocation, so interleaving the two on one bump would
/// make the frame reset discard persistent buffers (or silently no-op and
/// slowly leak). Tune the total with `-Dfba-bytes`.
const pers_bytes = options.fba_bytes * 5 / 8;

/// Long-lived allocations for the process lifetime: the window's batch render
/// buffers, its per-frame scratch pool, and text/image raster cache buffers.
/// Set to `arena_fba.allocator()` (the low region of `fba_buf`) by `initAlloc`.
/// Never reset, so cached buffers stay valid across frames and the region only
/// grows as caches churn; on exhaustion the failing allocation degrades
/// gracefully (a cache entry is skipped, an image is not decoded).
arena: std.mem.Allocator = undefined,
/// Per-frame scratch: shaping glyph arrays, layout request/child lists, and
/// `TextConfig` structs created while the tree is rebuilt every frame. A
/// fixed-buffer allocator over the remaining (high) region of `fba_buf`,
/// reset wholesale at the top of each frame (see `clear`), so a frame reuses
/// exactly the same backing memory. It is reset as a whole (not via arena chunk
/// frees) because `FixedBufferAllocator.free` only reclaims the last
/// allocation; a wholesale `reset` avoids that constraint entirely.
frame_arena: std.heap.FixedBufferAllocator = undefined,
/// The default allocator for frame-lifetime storage: the embedded `frame_arena`.
/// Elements allocate their layout request/child lists from it (`Layout` embeds
/// `std.ArrayList`s instead of huge fixed arrays, so copying an `Element` no
/// longer drags a 1500-slot array with it), and the Window draws per-frame
/// scratch overflow from it too. Swap it out with `setAlloc`; the buffer is
/// reclaimed at the top of each frame (see `clear`).
allocator: std.mem.Allocator = undefined,
/// Root of the persistent region: caches and the window batch keep their
/// buffers here for the process lifetime. Sized by the `-Dfba-bytes` build
/// option (default 8MB), of which `pers_bytes` feeds `arena` and the rest
/// feeds `frame_arena`.
arena_fba: std.heap.FixedBufferAllocator = undefined,
/// The fixed buffer backing the two regions, sized by the `-Dfba-bytes` build
/// option (default 8MB): `[0 .. pers_bytes]` feeds `arena` and the rest feeds
/// `frame_arena`. 0 bytes disables the embedded buffer entirely.
fba_buf: [options.fba_bytes]u8 align(@alignOf(usize)) = undefined,
/// True while `allocator` is the built-in embedded arena (i.e. the app has not
/// called `setAlloc`). The Window's scratch code uses this to decide whether an
/// allocation lives in `fba_buf` (freeing a no-op, reclaimed on reset).
fba_active: bool = true,
freetype: Freetype,
fonts: [10]Font = undefined,
font_count: u8 = 0,
/// The layout widget builders register their children into. Set with a
/// layout's `start(&widget)`; null means the app is not currently building a
/// container, so widgets build their element but do not place it.
current: ?*lu.Layout = null,
/// Empty layout for leaf elements that have no children.
leaf_layout: lu.Layout = .{ .vtable = &lu.Layout.leaf, .parent = null },
/// Memoizes decoded images across frames; buffers live in `arena`.
image_cache: lu.images.Cache = .{},
/// Memoizes rasterized label/button text across frames. Keyed by the element's
/// stable id (call-site position + loop `id_extra`), never by the pixel bytes.
/// A `TextEntry` stores the input fingerprint next to the buffer so a changed
/// label re-rasterizes but a repeated one is reused. Buffers live in `arena`.
text_cache: lu.Cache.Cache(u64, TextEntry, 65536) = .{},
/// Memoizes `Font.textSize` for stable strings. Every label/button re-measures
/// its text every frame with identical inputs; the HarfBuzz shaping that powers
/// that measurement is the hottest per-frame cost outside the GPU. Keyed by the
/// shaping inputs (font, text slice, size, direction, weight), values are just a
/// measured rect, and the table intentionally survives `clear()` so the build
/// and layout phases skip shaping entirely on repeat frames.
textsize_memo: TextSizeMemo = .{},
wrap_memo: WrapMemo = .{},
gpu_cache: ?GpuCache = null,
/// A Window-provided layout-results cache (installed by `Window.plugCache`).
/// `Layout.lay` consults it for elements with a stable id: when the same
/// container is laid out into the same box, the cached child positions/sizes
/// are replayed onto the freshly rebuilt children and the layout math (including
/// every child's text measurement) is skipped. Containers without a stable id
/// skip the cache entirely.
layout_cache: ?LayoutCacheSink = null,
/// Runtime switches that turn caching on or off. Setting a cache flag `false`
/// makes that cache a no-op: the rasterization/decode runs fresh every frame,
/// so you can measure the real cost of text/images side by side. Default all-on.
flags: Flags = .{},
/// The frame profiler + plugin host, embedded so any widget can record
/// sections, custom-trace spans and announced steps without an `if (dbg)`
/// dance at the call sites. Zero-initialized `Context`s get `active = false`,
/// so everything above is a no-op until the app calls `ctx.dbg.enable(true)`.
dbg: lu.Debug.DebugInfo = .{},
/// Per-frame event state for the view (the window). The Window's post-draw
/// processing pass rewrites it every frame from the SDL events it pumped;
/// widgets read it in `evalEvents` when they initialize elements, so an
/// element's `active` state always reflects last frame while the hook callbacks
/// (fired by that same pass) have effects visible next frame. Survives
/// `clear()`.
events: lu.View = .{},

/// Static pool of `Element`s the builds allocate from. Layouts reference their
/// children by pointer into this pool (never by value), so `Element` can embed
/// a `Layout` by value without a size-recursion loop, and no element is ever
/// heap-allocated. Reset by calling `clear()` at the top of each frame.
pool: [PoolN]lu.Element = undefined,
/// Next free slot in `pool`. Grows until `clear()` resets it.
plen: usize = 0,

/// Maximum elements a widget can build before the pool must be cleared. The
/// example's screen (dozens of boxes, buttons and labels) fits comfortably.
/// Configurable at build time with `-Delement-pool=<n>`.
pub const PoolN = options.pool;

/// A Window-provided uploader for persistent per-element textures. The cache
/// is looked up *before* Context decides to cache on CPU: if `lookup` returns a
/// key the pixels are already on the GPU for that fingerprint, so nothing is
/// re-rasterized; if not, `upload` receives freshly rasterized pixels and the
/// Window stores them under the returned key.
pub const GpuCache = struct {
    ptr: *anyopaque,
    /// Returns the cached texture key if `key`'s pixels match `fingerprint`.
    lookup: *const fn (ptr: *anyopaque, key: u64, fingerprint: u64) ?u64,
    /// Uploads `buf` for `key`/`fingerprint`, returning the key to reference.
    upload: *const fn (ptr: *anyopaque, key: u64, fingerprint: u64, buf: lu.PixelBuffer) ?u64,
};

/// Runtime switches that turn the Context's caches on or off. Set a flag to
/// `false` to make that cache a no-op (fresh rasterization/decode every frame)
/// so the profiler can measure the real cost of text and images.
pub const Flags = struct {
    /// Use the per-element GPU texture cache (`Window.plugCache`).
    gpu_cache: bool = true,
    /// Use the CPU `text_cache` of rasterized label/button pixel buffers.
    text_cache: bool = true,
    /// Use the `image_cache` that memoizes decoded images.
    image_cache: bool = true,
};

/// Cached result of laying out a container: the box it was laid into plus one
/// `Child` per laid-out child (world position and size, plus the child's stable
/// id so a changed tree shape is detected and the cache is dropped). Values own
/// no textures, so eviction just drops them.
pub const LayoutEntry = struct {
    /// The content box the layout laid its children into. A different box (the
    /// window resized and reallocated the container) is a miss, not a stale hit.
    container: lu.Rect,
    n: usize,
    kids: [lu.LayoutInner]Child,
    /// Last frame this layout was consulted or stored; idle entries are evicted.
    last_seen: u64,

    pub const Child = struct {
        id: u64,
        extra: u64,
        pos: lu.Pos,
        size: lu.Rect,
    };
};

/// A Window-provided hook so `Layout.lay` can reach the layout-results cache
/// without importing SDL. `Layout.lay` calls `consult` for an element with a
/// stable id before running the layout math and `store` after computing it; the
/// Window reads/writes `lu.Layout` fields through the pointer.
pub const LayoutCacheSink = struct {
    ptr: *anyopaque,
    consult: *const fn (ptr: *anyopaque, key: u64) ?*LayoutEntry,
    store: *const fn (ptr: *anyopaque, key: u64, layout: *lu.Layout) void,
};

/// A small direct-map memo of `Font.textSize` results, keyed by the shaping
/// inputs. Full-directory (the example has ~40 stable text widgets) the table
/// stops growing and just never hits for a brand-new string.
const TextSizeMemo = struct {
    const N = 96;
    keys: [N]Key = undefined,
    vals: [N]lu.Rect = undefined,
    count: usize = 0,

    const Key = struct {
        font: usize,
        text: [*]const u8,
        len: usize,
        size: u32,
        direction: Font.Direction,
        weight: u16,
    };

    fn get(m: *TextSizeMemo, font: *Font, text: []const u8, size: u32, direction: Font.Direction, weight: u16) ?lu.Rect {
        for (0..m.count) |i| {
            const k = m.keys[i];
            if (k.font == @intFromPtr(font) and
                k.len == text.len and
                k.size == size and
                k.weight == weight and
                k.direction == direction and
                k.text == text.ptr)
            {
                return m.vals[i];
            }
        }
        return null;
    }

    fn put(m: *TextSizeMemo, font: *Font, text: []const u8, size: u32, direction: Font.Direction, weight: u16, r: lu.Rect) void {
        if (m.count >= m.keys.len) return;
        m.keys[m.count] = .{
            .font = @intFromPtr(font),
            .text = text.ptr,
            .len = text.len,
            .size = size,
            .direction = direction,
            .weight = weight,
        };
        m.vals[m.count] = r;
        m.count += 1;
    }
};

/// Memoizes `wrapLines`, the word-wrap line count of a wrapped label. The
/// example's long English label re-measures its wrap every frame during the
/// layout phase; stable inputs make that shaping skippable after frame one.
const WrapMemo = struct {
    const N = 48;
    keys: [N]Key = undefined,
    vals: [N]u32 = undefined,
    count: usize = 0,

    const Key = struct {
        font: usize,
        text: [*]const u8,
        len: usize,
        size: u32,
        direction: Font.Direction,
        spacing_w: u32,
        spacing_h: u32,
        wrap_w: u32,
        weight: u16,
    };

    fn get(m: *WrapMemo, font: *Font, text: []const u8, size: u32, direction: Font.Direction, spacing: lu.Rect, wrap_w: u32, weight: u16) ?u32 {
        for (0..m.count) |i| {
            const k = m.keys[i];
            if (k.font == @intFromPtr(font) and
                k.len == text.len and
                k.size == size and
                k.weight == weight and
                k.direction == direction and
                k.spacing_w == spacing.w and
                k.spacing_h == spacing.h and
                k.wrap_w == wrap_w and
                k.text == text.ptr)
            {
                return m.vals[i];
            }
        }
        return null;
    }

    fn put(m: *WrapMemo, font: *Font, text: []const u8, size: u32, direction: Font.Direction, spacing: lu.Rect, wrap_w: u32, weight: u16, lines: u32) void {
        if (m.count >= m.keys.len) return;
        m.keys[m.count] = .{
            .font = @intFromPtr(font),
            .text = text.ptr,
            .len = text.len,
            .size = size,
            .direction = direction,
            .spacing_w = spacing.w,
            .spacing_h = spacing.h,
            .wrap_w = wrap_w,
            .weight = weight,
        };
        m.vals[m.count] = lines;
        m.count += 1;
    }
};

const Context = @This();

/// Returns the next free element slot. Elements live in the pool so their
/// addresses stay stable while layouts hold pointers to them. Raise `PoolN` if
/// a frame ever needs more elements than the pool holds.
pub fn allocElement(self: *Context) *lu.Element {
    if (self.plen == self.pool.len) {
        @panic("element pool full: call Context.clear() between frames or raise PoolN");
    }
    const e = &self.pool[self.plen];
    self.plen += 1;
    return e;
}

/// Wire the two embedded regions of `fba_buf`: the persistent `arena` (raster
/// caches, window batch buffers) over the low bytes, `frame_arena` over the
/// remaining (high) bytes, and make `frame_arena` the default allocator. Both
/// regions are sized at compile time (see `pers_bytes`). An app that wants to
/// override the built-in frame allocator can call `setAlloc` afterwards with
/// its own. Call `zeroInit` first (e.g. `std.mem.zeroInit(lu.Context, .{})`) or
/// use `std.heap.page_allocator.create` + `@memset` as the examples do, then
/// this fills in the allocator-dependent fields.
pub fn initAlloc(self: *Context) void {
    self.arena_fba = std.heap.FixedBufferAllocator.init(self.fba_buf[0..pers_bytes]);
    self.frame_arena = std.heap.FixedBufferAllocator.init(self.fba_buf[pers_bytes..]);
    self.arena = self.arena_fba.allocator();
    self.allocator = self.frame_arena.allocator();
    self.fba_active = true;
}

/// Swap the allocator frame-lifetime storage (Layout arrays, Window scratch
/// overflow) uses. The user's allocator takes over; the embedded `frame_arena`
/// still serves internal shaping buffers and is reset by `clear`, and the
/// persistent `arena` (caches, batch) stays over the embedded buffer. `clear`
/// no longer touches frame-lifetime allocations made through this allocator.
pub fn setAlloc(self: *Context, alloc: std.mem.Allocator) void {
    self.allocator = alloc;
    self.fba_active = false;
}

/// Reset the element pool and frame scratch for a fresh frame. Old element
/// pointers and layout pointers must not be used afterwards; the tree and its
/// layouts are rebuilt every frame anyway. Returns every per-frame allocation
/// to `frame_arena` (a wholesale bump reset, so the same backing memory is
/// reused every frame). The persistent `arena` is untouched: cached raster
/// buffers from previous frames stay live here.
pub fn clear(self: *Context) void {
    self.plen = 0;
    self.frame_arena.reset();
}

/// A fully-wired, inert set of events used by every generated element. Widgets
/// are immediate mode: the caller receives the element and can attach hooks.
pub const noEvents = lu.Element.Events{
    .hover = .{ .handle = null },
    .click = .{ .handle = null },
    .drag = .{ .handle = null },
    .render = .{ .handle = null },
    .modify = .{ .handle = null },
    .focus = .{ .handle = null },
    .key = .{ .handle = null },
};

/// The bare element every widget starts from: transparent background, leaf
/// layout, no events, not focusable. Widgets build on top of this, set their
/// contents, then apply the user's `Overrides` last.
fn base(self: *Context, size: lu.Rect) lu.Element {
    return .{
        .size = size,
        .pos = .{ .x = 0, .y = 0 },
        .border_radius = .all(0),
        .background = lu.Background.solid(.{ .r = 0, .g = 0, .b = 0, .a = 0 }),
        .layout = self.leaf_layout,
        .events = noEvents,
        .ctx = self,
        .focusable = false,
    };
}

/// Evaluates an element's interaction hooks against the view's per-frame event
/// state, setting each hook's `active` from the element it targeted last frame.
/// Must run after the user's `Overrides` (which wire the handlers and may set
/// `id_extra`) so `active` reflects the element exactly as built. Elements
/// render last frame's state: a button pressed this frame lights up next frame,
/// and the hook callbacks fired by the view's processing pass take effect then.
fn evalEvents(self: *Context, e: *lu.Element) void {
    e.events.hover.fromId(e.id, self.events.hovered);
    e.events.click.fromId(e.id, self.events.clicked);
    e.events.focus.fromId(e.id, self.events.focused);
    e.events.drag.fromId(e.id, self.events.dragged);
}

/// Requests `e`'s size and position from the current parent layout (set with a
/// layout's `start`) and places `e` there. Returns the request id the element
/// got, or null when there is no current parent. This is the only place a
/// widget talks to a layout.
fn publish(self: *Context, e: *lu.Element) ?u32 {
    return self.publishRequest(e, .{ .min_size = e.size, .pos = e.pos, .margin = e.margin });
}

/// Like `publish`, but with a hand-written `Request` so callers control
/// `min_size`/`max_size`, growth and alignment for the element. `e` must live
/// in the element pool so the parent's request can hold a stable pointer.
pub fn publishRequest(self: *Context, e: *lu.Element, req: lu.Layout.Request) ?u32 {
    self.dbg.announce("publish");
    const parent = self.current orelse return null;
    const id = parent.request(req);
    parent.addElement(id, e);
    return id;
}

/// An absolute layout value for a child that composes its own children
/// (progress bar fill, slider fill/knob). Embedded by value in the element's
/// `.layout`; `parent` is the current parent so `end` restores it.
fn makeAbsolute(self: *Context) lu.Layout {
    return .{ .vtable = &lu.Layout.absolute, .parent = self.current, .allocator = self.allocator };
}

/// A mono layout value for centering a single child (button label).
fn makeMono(self: *Context, pad: lu.Sides) lu.Layout {
    return .{ .vtable = &lu.Layout.mono, .parent = self.current, .padding = pad, .allocator = self.allocator };
}

pub const Freetype = struct {
    lib: c.FT_Library,

    pub fn init() !Freetype {
        var self = Freetype{
            .lib = undefined,
        };
        const err = c.FT_Init_FreeType(@ptrCast(&self.lib));
        if (err != 0) {
            std.log.err("Got freetype error code {}", .{@as(i64, err)});
            return error.FailedToInitializeFreetype;
        }
        return self;
    }

    pub fn deinit(self: *Freetype) void {
        _ = c.FT_Done_FreeType(self.lib);
    }

    pub fn createFont(self: *Freetype, path: [:0]const u8, pixel_size: u32) !Font {
        var face: c.FT_Face = undefined;
        const err = c.FT_New_Face(self.lib, @ptrCast(path.ptr), 0, @ptrCast(&face));
        if (err != 0) {
            std.log.err("Got freetype error code {}", .{@as(i64, err)});
            return error.FailedToInitializeFontFace;
        }
        const size_err = c.FT_Set_Pixel_Sizes(face, 0, @intCast(pixel_size));
        if (size_err != 0) {
            _ = c.FT_Done_Face(face);
            std.log.err("Got freetype error code {}", .{@as(i64, size_err)});
            return error.FailedToSetPixelSizeFreetype;
        }
        const hb_font = c.hb_ft_font_create_referenced(face) orelse {
            _ = c.FT_Done_Face(face);
            return error.FailedToCreateHarfbuzzFont;
        };
        return .{
            .face = face,
            .hb_font = hb_font,
            .pixel_size = pixel_size,
        };
    }
};

pub const Font = struct {
    face: c.FT_Face,
    hb_font: *c.hb_font_t,
    pixel_size: u32,

    pub const Bitmap = struct {
        buffer: []const u8,
        size: lu.Rect,
    };

    pub const RenderOpts = struct {
        overflow_w: Overflow = .newline,
        overflow_h: Overflow = .skip,

        pub const Overflow = enum {
            skip,
            draw,
            /// Does not work in horizontal
            newline,
        };
    };

    pub const GlyphInfo = struct {
        glyph_index: u32,
        x_advance: i32,
        y_advance: i32,
        x_offset: i32,
        y_offset: i32,
        width: u32,
        height: u32,
        bitmap_left: i32,
        bitmap_top: i32,
        cluster: u32,
    };

    pub const ShapedText = struct {
        glyphs: []const GlyphInfo,
        width: i32,
        height: i32,
        ascender: i32,
        direction: Direction,
    };

    pub const Direction = enum {
        ltr,
        rtl,

        fn toHb(self: Direction) c.hb_direction_t {
            return switch (self) {
                .ltr => c.HB_DIRECTION_LTR,
                .rtl => c.HB_DIRECTION_RTL,
            };
        }
    };

    pub fn deinit(self: *Font) void {
        c.hb_font_destroy(self.hb_font);
        _ = c.FT_Done_Face(self.face);
    }

    pub fn setCharSize(self: *Font, height: u32) !void {
        const err = c.FT_Set_Pixel_Sizes(self.face, 0, @intCast(height));
        if (err != 0) {
            std.log.err("Got freetype error code {}", .{@as(i64, err)});
            return error.FailedToSetPixelSizeFreetype;
        }
        c.hb_ft_font_changed(self.hb_font);
        self.pixel_size = height;
    }

    /// Shape text using HarfBuzz and return glyph positions.
    pub fn shapeText(self: *Font, alloc: std.mem.Allocator, text: []const u8, direction: Direction) !ShapedText {
        const buf = c.hb_buffer_create() orelse return error.FailedToCreateHarfbuzzBuffer;
        defer c.hb_buffer_destroy(buf);

        c.hb_buffer_add_utf8(buf, @ptrCast(text.ptr), @intCast(text.len), 0, @intCast(text.len));
        c.hb_buffer_guess_segment_properties(buf);
        c.hb_buffer_set_direction(buf, direction.toHb());

        c.hb_shape(self.hb_font, buf, null, 0);

        var glyphs_len: c_uint = 0;
        const glyphs = c.hb_buffer_get_glyph_infos(buf, &glyphs_len);
        const positions = c.hb_buffer_get_glyph_positions(buf, &glyphs_len);

        const glyph_infos = try alloc.alloc(GlyphInfo, glyphs_len);
        var total_width: i32 = 0;
        var max_ascend: i32 = 0;
        var max_descend: i32 = 0;

        for (0..glyphs_len) |i| {
            const g = glyphs[i];
            const p = positions[i];

            _ = c.FT_Load_Glyph(self.face, g.codepoint, c.FT_LOAD_DEFAULT);
            const metrics = self.face.*.glyph.*.metrics;

            const btop: i32 = @intCast(@divTrunc(metrics.horiBearingY, 64));
            const brows: i32 = @intCast(@divTrunc(metrics.height, 64));

            glyph_infos[i] = .{
                .glyph_index = g.codepoint,
                .x_advance = p.x_advance,
                .y_advance = p.y_advance,
                .x_offset = p.x_offset,
                .y_offset = p.y_offset,
                .width = @intCast(@max(0, @divTrunc(metrics.width, 64))),
                .height = @intCast(@max(0, brows)),
                .bitmap_left = @intCast(@divTrunc(metrics.horiBearingX, 64)),
                .bitmap_top = @intCast(btop),
                .cluster = g.cluster,
            };

            total_width += @intCast(@divTrunc(p.x_advance, 64));

            const ascend = @divTrunc(p.y_offset, 64) + btop;
            const descend = brows - btop - @divTrunc(p.y_offset, 64);
            if (ascend > max_ascend) max_ascend = ascend;
            if (descend > max_descend) max_descend = descend;
        }

        return .{
            .glyphs = glyph_infos,
            .width = total_width,
            .height = max_ascend + max_descend,
            .ascender = max_ascend,
            .direction = direction,
        };
    }

    /// Get the bounding box of text without rendering. A weight above the
    /// regular 400 is measured with the same per-glyph embolden bump that
    /// `renderText` applies, so a bold label wraps where it actually wraps.
    pub fn textSize(self: *Font, alloc: std.mem.Allocator, text: []const u8, size: u32, direction: Direction, weight: u16) !lu.Rect {
        try self.setCharSize(size);
        const shaped = try self.shapeText(alloc, text, direction);
        const strength: i64 = boldStrength26(weight);
        var w_26: i64 = 0;
        for (shaped.glyphs) |g| {
            w_26 += @as(i64, g.x_advance) + strength;
        }
        return .{
            .w = @intCast(@max(0, @divTrunc(w_26, 64))),
            .h = @intCast(@max(0, shaped.height)),
        };
    }

    /// Render shaped text into a pixel buffer. The returned buffer is RGBA8888.
    ///
    /// `area` is the size of the buffer (usually the full element box). Glyphs
    /// are drawn offset by `origin` (the padded content origin). When `wrap` is
    /// given and `opts.overflow_w` is `.newline`, text longer than `wrap`
    /// pixels breaks onto a new line.
    pub fn renderText(
        self: *Font,
        alloc: std.mem.Allocator,
        text: []const u8,
        area: lu.Rect,
        spacing: lu.Rect,
        size: u32,
        direction: Direction,
        color: lu.Color,
        opts: RenderOpts,
        origin: lu.Pos,
        wrap: ?u32,
        weight: u16,
    ) !lu.PixelBuffer {
        try self.setCharSize(size);
        const shaped = try self.shapeText(alloc, text, direction);
        defer alloc.free(shaped.glyphs);
        const strength: i64 = boldStrength26(weight);

        const buf_w = area.w;
        const buf_h = area.h;
        var pixels = try alloc.alloc(u8, buf_w * buf_h * 4);
        @memset(pixels, 0);

        var pen_x: i64 = 0;
        var pen_y: i32 = shaped.ascender;
        const line_start_x: i32 = 0;
        const line_height: i32 = @intCast(self.pixel_size + spacing.h);
        const wrap_26: i64 = if (wrap) |w| @as(i64, @intCast(w)) * 64 else -1;

        for (shaped.glyphs) |glyph| {
            const adv_26: i32 = glyph.x_advance;
            const off_x: i32 = @intCast(@divTrunc(glyph.x_offset, 64));
            const off_y: i32 = @intCast(@divTrunc(glyph.y_offset, 64));

            if (opts.overflow_w == .newline and wrap_26 > 0 and
                pen_x - line_start_x + adv_26 + @as(i32, @intCast(strength)) > wrap_26)
            {
                pen_x = line_start_x;
                pen_y += line_height;
                if (opts.overflow_h == .skip and pen_y > @as(i32, @intCast(buf_h))) break;
            }

            const draw_x = @as(i32, @intCast(origin.x)) + @divTrunc(pen_x, 64) + off_x;
            const draw_y = @as(i32, @intCast(origin.y)) + pen_y + off_y - glyph.bitmap_top;

            _ = c.FT_Load_Glyph(self.face, glyph.glyph_index, c.FT_LOAD_DEFAULT);
            if (strength > 0 and self.face.*.glyph.*.format == c.FT_GLYPH_FORMAT_OUTLINE) {
                _ = c.FT_Outline_Embolden(&self.face.*.glyph.*.outline, @intCast(strength));
            }
            _ = c.FT_Render_Glyph(self.face.*.glyph, c.FT_RENDER_MODE_NORMAL);

            const bitmap = self.face.*.glyph.*.bitmap;
            for (0..@intCast(bitmap.rows)) |row| {
                for (0..@intCast(bitmap.width)) |col| {
                    const px = draw_x + @as(i32, @intCast(col));
                    const py = draw_y + @as(i32, @intCast(row));

                    if (px < 0 or py < 0) continue;
                    if (px >= @as(i32, @intCast(buf_w))) continue;
                    if (py >= @as(i32, @intCast(buf_h))) continue;

                    const alpha = bitmap.buffer[row * @as(usize, @intCast(bitmap.pitch)) + col];
                    if (alpha == 0) continue;

                    const idx = (@as(usize, @intCast(py)) * buf_w + @as(usize, @intCast(px))) * 4;
                    pixels[idx] = color.r;
                    pixels[idx + 1] = color.g;
                    pixels[idx + 2] = color.b;
                    pixels[idx + 3] = @intFromFloat(@as(f64, @floatFromInt(color.a)) * @as(f64, @floatFromInt(alpha)) / 255.0);
                }
            }

            pen_x += adv_26 + @as(i32, @intCast(strength));
        }

        return .{
            .pixels = pixels,
            .width = buf_w,
            .height = buf_h,
        };
    }
};

/// Measure a string's natural size, memoizing by shaping inputs so stable
/// label/button strings skip HarfBuzz entirely after their first frame.
fn textSizeCached(self: *Context, font: *Font, text: []const u8, size: u32, direction: Font.Direction, weight: u16) !lu.Rect {
    // Keep the face's live pixel size in sync even on a memo hit: the shared
    // face is reused at several sizes, and `wrapLines`/line-height math reads
    // `font.pixel_size` after measuring. `setCharSize` no-ops when unchanged.
    try font.setCharSize(size);
    if (self.textsize_memo.get(font, text, size, direction, weight)) |r| {
        self.dbg.announce("measure hit");
        return r;
    }
    const r = try font.textSize(self.frame_arena.allocator(), text, size, direction, weight);
    self.dbg.announce("measure miss");
    self.textsize_memo.put(font, text, size, direction, weight, r);
    return r;
}

/// Configuration for a `text` layout. Holds the font, the string and how to
/// draw it; the layout reads it during `lay`, so rendering is deferred until
/// the label has been given its box.
pub const TextConfig = struct {    font: *Font,
    text: []const u8,
    /// Pixel size of the font.
    size: u32 = 24,
    /// Extra space between glyphs / lines.
    spacing: lu.Rect = .{ .w = 2, .h = 4 },
    /// Text direction; RTL is shaped by HarfBuzz.
    direction: Font.Direction = .ltr,
    color: lu.Color = .white,
    render: Font.RenderOpts = .{},
    /// Wrap the text onto extra lines when it does not fit the width it is
    /// given. On by default.
    wrap: bool = true,
    /// Typeface weight. 400 is regular; higher values are rendered bold by
    /// thickening each glyph and adding a matching per-glyph advance, so a
    /// bold label also measures and wraps slightly wider.
    weight: u16 = 400,
};

/// A layout that renders its text when `lay` runs: it shapes and rasterizes
/// the string into the box it is actually given (wrapping to any number of
/// lines), then sets the element's `.background` to that bitmap. This is like
/// `mono` but defers rendering until layout time, so the text can adapt.
pub const textVTable = lu.Layout.VTable{ .lay = textLay, .content = textContent };

/// A cached text fragment: the input fingerprint (hash of the string + every
/// setting that changes the raster) plus the resulting pixel buffer. The
/// fingerprint is compared on a cache hit so a changed label is re-rasterized.
pub const TextEntry = struct {
    fingerprint: u64,
    buffer: lu.PixelBuffer,
};

/// A stable id derived from a call site's `@src()` (file:line:column). The tree
/// is rebuilt every frame, so the same source position yields the same id;
/// caches key on this instead of re-hashing each frame.
pub fn idOf(comptime src: std.builtin.SourceLocation) u64 {
    var h = std.hash.Wyhash.init(0x9e3779b97f4a7c15);
    h.update(src.file);
    h.update(std.mem.asBytes(&src.line));
    h.update(std.mem.asBytes(&src.column));
    return h.final();
}

/// The combined cache key for an element: its source-id plus the loop
/// `id_extra`. Two wrappers in the same loop body share the same `id` but have
/// different id_extra, so each distinct instance gets its own cache entry.
pub fn cacheKey(id: u64, extra: u64) u64 {
    return id ^ (extra *% 0x9e3779b97f4a7c15);
}

fn textCfg(layout: *const lu.Layout) ?*const TextConfig {
    return @ptrCast(@alignCast(layout.data orelse return null));
}

/// Per-glyph embolden amount (in FreeType 26.6 fixed-point) for a CSS-style
/// `weight`. Regular is 400; each weight unit above that adds 0.001px of stroke
/// on every side (and an equal pen advance, so bold glyphs do not overlap).
/// Capped at 900 so absurd weights cannot balloon the glyphs.
fn boldStrength26(weight: u16) i32 {
    const above: i32 = @as(i32, @min(weight, 900)) - 400;
    if (above <= 0) return 0;
    return @intFromFloat(@as(f32, @floatFromInt(above)) * 0.064);
}

/// How many lines `text` occupies once word-wrapped to `wrap_w`px. Counts the
/// same line breaks the renderer produces (see `renderText`): a line breaks
/// the moment the running pen would cross `wrap_w`, so even a single word wider
/// than the box spans multiple lines. A word never breaks mid-run horizontally
/// carries over, matching how glyphs are pushed line-by-line when rendered.
fn wrapLines(
    font: *Font,
    alloc: std.mem.Allocator,
    text: []const u8,
    size: u32,
    direction: Font.Direction,
    spacing: lu.Rect,
    wrap_w: u32,
    weight: u16,
) !u32 {
    _ = spacing;
    if (text.len == 0) return 1;
    try font.setCharSize(size);
    const shaped = try font.shapeText(alloc, text, direction);
    const strength: i64 = boldStrength26(weight);
    var lines: u32 = 1;
    var cur: i64 = 0;
    const ww: i64 = @intCast(wrap_w * 64);
    for (shaped.glyphs) |g| {
        const w: i64 = @as(i64, g.x_advance) + strength;
        if (ww > 0 and cur + w > ww) {
            lines += 1;
            cur = 0;
        }
        cur += w;
    }
    return lines;
}

/// The world size a label wants given the box `avail`. A fixed wrap controls
/// the width, so the reported size is the wrapped block; otherwise it is the
/// single-line size. When the parent can only offer a narrow box it recomputes
/// the wrapped block that fits that width (main parent axis) plus the extra
/// height the wrapped lines need (the expansion axis).
fn textContent(layout: *const lu.Layout, avail: lu.Rect) ?lu.Rect {
    const cfg = textCfg(layout) orelse return null;
    const ctx = (layout.element orelse return null).ctx orelse return null;
    const natural = ctx.textSizeCached(cfg.font, cfg.text, cfg.size, cfg.direction, cfg.weight) catch return null;
    if (!cfg.wrap) return natural;
    if (avail.w == 0 or natural.w <= avail.w) return natural;
    const line_h: u32 = cfg.font.pixel_size + cfg.spacing.h;
    const lines = ctx.wrapLinesCached(cfg.font, cfg.text, cfg.size, cfg.direction, cfg.spacing, avail.w, cfg.weight) catch return natural;
    return .{ .w = avail.w, .h = lines * line_h };
}

/// Rasterizes `text` and returns the element's background for it. It looks for
/// a plugged-in GPU cache *first*: if the Window can serve (or upload) the
/// pixels under the element's id, the result is a persistent `Background.cached`
/// texture and no CPU buffer survives the frame. Only when no GPU cache is
/// plugged (or it declines) does the CPU `text_cache` store the pixel buffer.
fn renderTextCached(self: *Context, fnSelf: *Font, text: []const u8, area: lu.Rect, spacing: lu.Rect, size: u32, direction: Font.Direction, color: lu.Color, render: Font.RenderOpts, wrap: ?u32, weight: u16, eid: u64, extra: u64) !lu.Background {
    const key = cacheKey(eid, extra);
    const fingerprint = textLayKey(fnSelf, text, area, spacing, size, direction, color, render, wrap, weight);
    if (self.flags.gpu_cache) {
        if (self.gpu_cache) |gc| {
            if (gc.lookup(gc.ptr, key, fingerprint) != null) {
                self.dbg.announce("gpu cache hit");
                return lu.Background.cached(key);
            }
            // Miss on the GPU: rasterize transiently and let the Window upload.
            self.dbg.announce("gpu cache miss");
            const buf = try fnSelf.renderText(
                self.frame_arena.allocator(),
                text,
                area,
                spacing,
                size,
                direction,
                color,
                render,
                .{ .x = 0, .y = 0 },
                wrap,
                weight,
            );
            if (gc.upload(gc.ptr, key, fingerprint, buf) != null) {
                self.dbg.announce("gpu upload");
                return lu.Background.cached(key);
            }
            // The Window declined the upload; fall through to CPU.
        }
    }
    if (self.flags.text_cache) {
        if (self.text_cache.get(key)) |entry| {
            if (entry.fingerprint == fingerprint) {
                self.dbg.announce("text cache hit");
                return lu.Background.buffer(entry.buffer);
            }
        }
    }
    self.dbg.announce("text rasterize");
    const buf = try fnSelf.renderText(
        self.arena,
        text,
        area,
        spacing,
        size,
        direction,
        color,
        render,
        .{ .x = 0, .y = 0 },
        wrap,
        weight,
    );
    if (self.flags.text_cache)
        self.text_cache.put(key, .{ .fingerprint = fingerprint, .buffer = buf });
    return lu.Background.buffer(buf);
}

/// Hash of every input that changes the raster of `renderText`. The text bytes
/// and the compact settings — never pixel data.
fn textLayKey(
    font: *Font,
    text: []const u8,
    area: lu.Rect,
    spacing: lu.Rect,
    size: u32,
    direction: Font.Direction,
    color: lu.Color,
    render: Font.RenderOpts,
    wrap: ?u32,
    weight: u16,
) u64 {
    var h = std.hash.Wyhash.init(0x51a7e15);
    h.update(std.mem.asBytes(&@intFromPtr(font)));
    h.update(text);
    h.update(std.mem.asBytes(&area.w));
    h.update(std.mem.asBytes(&area.h));
    h.update(std.mem.asBytes(&spacing.w));
    h.update(std.mem.asBytes(&spacing.h));
    h.update(std.mem.asBytes(&size));
    h.update(std.mem.asBytes(&direction));
    h.update(std.mem.asBytes(&color));
    h.update(std.mem.asBytes(&render.overflow_w));
    h.update(std.mem.asBytes(&render.overflow_h));
    const w: u32 = wrap orelse 0;
    h.update(std.mem.asBytes(&w));
    h.update(std.mem.asBytes(&weight));
    return h.final();
}

/// Renders the text into a bitmap child element and centers it in the box the
/// element was given (mono behavior). The element itself keeps its own
/// `background`/`border`/settings; only the child carries the text image.
/// This is where the string is actually turned into a bitmap.
fn textLay(layout: *lu.Layout) void {
    const el = layout.element orelse return;
    const ctx = el.ctx orelse return;
    const cfg = textCfg(layout) orelse return;
    const box_w = layout.container.w;
    const box_h = layout.container.h;

    const nat = ctx.textSizeCached(cfg.font, cfg.text, cfg.size, cfg.direction, cfg.weight) catch return;
    var block_h: u32 = nat.h;
    const wrap_w: ?u32 = if (cfg.wrap and box_w > 0) box_w else null;
    if (cfg.wrap and box_w > 0 and nat.w > box_w) {
        const lines = ctx.wrapLinesCached(cfg.font, cfg.text, cfg.size, cfg.direction, cfg.spacing, box_w, cfg.weight) catch block_h;
        const line_h: u32 = cfg.font.pixel_size + cfg.spacing.h;
        block_h = lines * line_h;
    }
    const bg = ctx.renderTextCached(
        cfg.font,
        cfg.text,
        .{ .w = box_w, .h = block_h },
        cfg.spacing,
        cfg.size,
        cfg.direction,
        cfg.color,
        cfg.render,
        wrap_w,
        cfg.weight,
        el.id,
        el.id_extra,
    ) catch return;

    const child = ctx.allocElement();
    child.* = .{
        .size = .{ .w = box_w, .h = block_h },
        .pos = .{
            .x = 0,
            .y = @divTrunc(box_h -| block_h, 2),
        },
        .background = bg,
        .layout = ctx.leaf_layout,
        .ctx = ctx,
        .events = noEvents,
        .focusable = false,
        .id = el.id,
        .id_extra = el.id_extra,
    };
    layout.children.clearRetainingCapacity();
    layout.children.append(ctx.allocator, child) catch {
        if (builtin.mode == .Debug) @panic("layout children allocation failed: raise -Dfba-bytes (or use Context.setAlloc)");
        std.log.warn("layout children allocation failed; increase -Dfba-bytes", .{});
        layout.cindex = 0;
        return;
    };
    layout.cindex = 1;
}

/// How many lines a wrapped label occupies, memoized by wrap inputs so stable
/// wrapped strings (the example's long label) skip shaping after frame one.
fn wrapLinesCached(self: *Context, font: *Font, text: []const u8, size: u32, direction: Font.Direction, spacing: lu.Rect, wrap_w: u32, weight: u16) !u32 {
    try font.setCharSize(size);
    if (self.wrap_memo.get(font, text, size, direction, spacing, wrap_w, weight)) |lines| {
        self.dbg.announce("wrap hit");
        return lines;
    }
    const lines = try wrapLines(font, self.frame_arena.allocator(), text, size, direction, spacing, wrap_w, weight);
    self.dbg.announce("wrap miss");
    self.wrap_memo.put(font, text, size, direction, spacing, wrap_w, weight, lines);
    return lines;
}

/// A box of text, padded and centered inside its own box. The text is not
/// rasterized here: the `text` layout renders it when the box is laid out,
/// so it can wrap to the width it is actually given.
pub fn label(self: *Context, text: []const u8, overrides: lu.Element.Overrides, opts: LabelOpts, comptime src: std.builtin.SourceLocation) !*lu.Element {
    self.dbg.announce("label");
    const cfg = self.frame_arena.allocator().create(TextConfig) catch unreachable;
    cfg.* = .{
        .font = &self.fonts[opts.font_idx],
        .text = text,
        .size = opts.size,
        .spacing = opts.spacing,
        .direction = opts.direction,
        .color = opts.color,
        .render = opts.render,
        .wrap = opts.wrap,
        .weight = opts.weight,
    };
    const natural = try self.textSizeCached(&self.fonts[opts.font_idx], text, opts.size, opts.direction, opts.weight);
    const e = self.allocElement();
    e.* = self.base(.{ .w = 0, .h = 0 });
    e.id = idOf(src);
    e.override(overrides);
    self.evalEvents(e);
    const border = e.border;
    const pad = opts.padding;
    e.size = .{
        .w = natural.w + pad.left + pad.right + border.left + border.right,
        .h = natural.h + pad.top + pad.bottom + border.top + border.bottom,
    };
    e.layout = .{ .vtable = &textVTable, .parent = self.current, .padding = pad, .data = @ptrCast(cfg), .allocator = self.allocator };
    _ = self.publish(e);
    return e;
}

/// Widgets are functions that spit out an element. They take their main input
/// (text, a value, an image source...), the user `Overrides`, and a
/// widget-specific `Opts` struct. Every widget builds on `box`, sets its own
/// contents, applies the user `Overrides` last (so the user always wins), then
/// requests space from the current parent layout and returns the element.
/// Nothing holds state: the caller owns the returned element and re-creates it
/// every time the tree is rebuilt.
/// The simplest widget: requests `size` from the current parent's layout,
/// applies `overrides`, and returns a plain element. No contents, no opts. The
/// element is owned by the widget's pool (stable address, no heap).
pub fn box(self: *Context, size: lu.Rect, overrides: lu.Element.Overrides, comptime src: std.builtin.SourceLocation) *lu.Element {
        self.dbg.announce("box");
    const e = self.allocElement();
    e.* = self.base(size);
    e.id = idOf(src);
    e.override(overrides);
    self.evalEvents(e);
    _ = self.publish(e);
    return e;
}

/// Fine-tunable knobs for text. Every decision is a separate field so changing
/// one thing never flips a bunch of others.
pub const LabelOpts = struct {
    /// Index into `fonts`.
    font_idx: usize = 0,
    /// Pixel size of the font.
    size: u32 = 24,
    /// Extra space between glyphs / lines.
    spacing: lu.Rect = .{ .w = 2, .h = 4 },
    /// Text direction; RTL is shaped by HarfBuzz.
    direction: Font.Direction = .ltr,
    color: lu.Color = .white,
    /// Overflow behavior when the text is larger than its box.
    render: Font.RenderOpts = .{},
    /// Space around the text inside the label's box.
    padding: lu.Sides = .all(0),
    /// Allow the text to wrap onto extra lines when it does not fit the width
    /// it is given. Wrapping is on by default.
    wrap: bool = true,
    /// Typeface weight: 400 (regular) to ~900 (heavy). Above 400 the text is
    /// emboldened synthetically and its glyphs are advanced a little further so
    /// they do not overlap. Weight also widens the measured label, so wrapping
    /// matches what is drawn.
    weight: u16 = 400,
};

/// Renders `text` into a leaf element (a pixel-buffer background). Used by
/// `label` and reused by anything that puts text in a box (`button`). The leaf
/// reuses the parent element's id so its cached texture keys match the element
/// that owns the text.
fn textElement(self: *Context, text: []const u8, opts: LabelOpts, eid: u64, extra: u64) !*lu.Element {
    const font = &self.fonts[opts.font_idx];
    const text_size = try self.textSizeCached(font, text, opts.size, opts.direction, opts.weight);
    const bg = try self.renderTextCached(
        font,
        text,
        text_size,
        opts.spacing,
        opts.size,
        opts.direction,
        opts.color,
        opts.render,
        null,
        opts.weight,
        eid,
        extra,
    );
    const e = self.allocElement();
    e.* = .{
        .size = text_size,
        .pos = .{ .x = 0, .y = 0 },
        .background = bg,
        .layout = self.leaf_layout,
        .focusable = false,
        .ctx = self,
        .events = noEvents,
        .id = eid,
        .id_extra = extra,
    };
    return e;
}

/// Fine-tunable knobs for buttons.
pub const ButtonOpts = struct {
    label: LabelOpts = .{},
    padding: lu.Sides = .all(8),
    color: lu.Color = .gray,
    radius: lu.Corners = .all(4),
    /// Floor for the button's size. The button is never smaller than this.
    min_size: ?lu.Rect = null,
    /// Cap for the button's size. The button never grows past this.
    max_size: ?lu.Rect = null,
    /// Extra main-axis space this button claims when its row has room to give.
    grow: u32 = 0,
};

/// A tappable box with a centered label.
pub fn button(self: *Context, text: []const u8, overrides: lu.Element.Overrides, opts: ButtonOpts, comptime src: std.builtin.SourceLocation) !*lu.Element {
    self.dbg.announce("button");
    const eid = idOf(src);
    const inner = try self.textElement(text, opts.label, eid, overrides.id_extra orelse 0);
    const pad = opts.padding;
    const e = self.allocElement();
    e.* = self.base(.{ .w = 0, .h = 0 });
    e.id = eid;
    e.background = lu.Background.solid(opts.color);
    e.border_radius = opts.radius;
    e.override(overrides);
    self.evalEvents(e);
    const border = e.border;
    e.size = .{
        .w = inner.size.w + pad.left + pad.right + border.left + border.right,
        .h = inner.size.h + pad.top + pad.bottom + border.top + border.bottom,
    };
    e.layout = self.makeMono(pad);
    const inner_id = e.layout.?.request(.{ .min_size = inner.size, .pos = .{ .x = 0, .y = 0 } });
    e.layout.?.addElement(inner_id, inner);
    _ = self.publishRequest(e, .{
        .min_size = opts.min_size orelse e.size,
        .pos = e.pos,
        .margin = e.margin,
        .max_size = opts.max_size,
        .grow = opts.grow,
    });
    return e;
}

/// Fine-tunable knobs for checkboxes.
pub const CheckboxOpts = struct {
    size: lu.Rect = .{ .w = 18, .h = 18 },
    radius: lu.Corners = .all(4),
    /// Fill when checked; empty (transparent) when not.
    checked_color: lu.Color = .green,
    /// Border color in both states.
    border_color: lu.Color = .gray,
    border: lu.Sides = .all(2),
};

/// A box that reports whether it is checked. Immediate mode: the caller owns
/// the boolean and rebuilds the widget when it changes.
pub fn checkbox(self: *Context, checked: bool, overrides: lu.Element.Overrides, opts: CheckboxOpts, comptime src: std.builtin.SourceLocation) *lu.Element {
    const e = self.allocElement();
    e.* = self.base(opts.size);
    e.id = idOf(src);
    e.border = opts.border;
    e.border_color = .{ .color = opts.border_color };
    e.border_radius = opts.radius;
    if (checked) e.background = lu.Background.solid(opts.checked_color);
    e.override(overrides);
    self.evalEvents(e);
    _ = self.publish(e);
    return e;
}

/// Fine-tunable knobs for progress bars.
pub const ProgressBarOpts = struct {
    size: lu.Rect = .{ .w = 160, .h = 18 },
    radius: lu.Corners = .all(6),
    track_color: lu.Color = .dark_gray,
    fill_color: lu.Color = .blue,
};

/// A track with a fill that reflects `value` (clamped to 0.0-1.0). The fill is
/// a child element sized `value` wide, so rounding/effects on the fill remain
/// independent from the track.
pub fn progress_bar(self: *Context, value: f32, overrides: lu.Element.Overrides, opts: ProgressBarOpts, comptime src: std.builtin.SourceLocation) *lu.Element {
    const v = std.math.clamp(value, 0.0, 1.0);
    const e = self.allocElement();
    e.* = self.base(opts.size);
    e.id = idOf(src);
    e.background = lu.Background.solid(opts.track_color);
    e.border_radius = opts.radius;
    e.layout = self.makeAbsolute();

    const fill_w: u32 = @intFromFloat(@as(f32, @floatFromInt(opts.size.w)) * v);
    if (fill_w > 0) {
        const fill = self.allocElement();
        fill.* = self.base(.{ .w = fill_w, .h = opts.size.h });
        fill.background = lu.Background.solid(opts.fill_color);
        const r = opts.radius;
        fill.border_radius = if (fill_w >= opts.size.w)
            r
        else
            .{ .top_left = r.top_left, .bottom_left = r.bottom_left, .top_right = 0, .bottom_right = 0 };
        const fill_id = e.layout.?.request(.{ .min_size = fill.size, .pos = .{ .x = 0, .y = 0 } });
        e.layout.?.addElement(fill_id, fill);
    }

    e.override(overrides);
    self.evalEvents(e);
    _ = self.publish(e);
    return e;
}

/// Fine-tunable knobs for sliders.
pub const SliderOpts = struct {
    size: lu.Rect = .{ .w = 160, .h = 12 },
    radius: lu.Corners = .all(6),
    track_color: lu.Color = .dark_gray,
    fill_color: lu.Color = .blue,
    /// Knob diameter; 0 means the track height.
    knob_size: u32 = 0,
    knob_color: lu.Color = .white,
};

/// A track + fill + knob that reflect `value` (clamped to 0.0-1.0). The knob
/// travels the width of the track; keep `knob_size` <= the track height so it
/// is not clipped to the track's box.
pub fn slider(self: *Context, value: f32, overrides: lu.Element.Overrides, opts: SliderOpts, comptime src: std.builtin.SourceLocation) *lu.Element {
    const v = std.math.clamp(value, 0.0, 1.0);
    const e = self.allocElement();
    e.* = self.base(opts.size);
    e.id = idOf(src);
    e.background = lu.Background.solid(opts.track_color);
    e.border_radius = opts.radius;
    e.layout = self.makeAbsolute();

    const fill_w: u32 = @intFromFloat(@as(f32, @floatFromInt(opts.size.w)) * v);
    if (fill_w > 0) {
        const fill = self.allocElement();
        fill.* = self.base(.{ .w = fill_w, .h = opts.size.h });
        fill.background = lu.Background.solid(opts.fill_color);
        const r = opts.radius;
        fill.border_radius = if (fill_w >= opts.size.w)
            r
        else
            .{ .top_left = r.top_left, .bottom_left = r.bottom_left, .top_right = 0, .bottom_right = 0 };
        const fill_id = e.layout.?.request(.{ .min_size = fill.size, .pos = .{ .x = 0, .y = 0 } });
        e.layout.?.addElement(fill_id, fill);
    }

    const knob_size = if (opts.knob_size == 0) opts.size.h else opts.knob_size;
    const travel = opts.size.w -| knob_size;
    const kx: u32 = @intFromFloat(@as(f32, @floatFromInt(travel)) * v);
    const ky = (opts.size.h -| knob_size) / 2;
    const knob = self.allocElement();
    knob.* = self.base(.{ .w = knob_size, .h = knob_size });
    knob.background = lu.Background.solid(opts.knob_color);
    knob.border_radius = .all(knob_size / 2);
    const knob_id = e.layout.?.request(.{ .min_size = knob.size, .pos = .{ .x = kx, .y = ky } });
    e.layout.?.addElement(knob_id, knob);

    e.override(overrides);
    self.evalEvents(e);
    _ = self.publish(e);
    return e;
}

/// Fine-tunable knobs for image widgets.
pub const ImageOpts = struct {
    /// How the decoded image is scaled into the element's box.
    fit: lu.ImageFit = .stretch,
    /// Sampling filter used when the image is scaled.
    filter: lu.Filter = .linear,
    /// Raster width for SVG sources; 0 = natural width.
    svg_width: u32 = 0,
    /// Raster height for SVG sources; 0 = natural height.
    svg_height: u32 = 0,
    /// Multiplies the natural SVG size when no explicit raster size is given.
    svg_scale: f32 = 1.0,
};

/// Decodes `source` (once, cached) and shows it in a box the size of the
/// decoded image (or the `overrides.size`). SVG is rasterized at the size
/// requested through `opts`.
pub fn image(self: *Context, source: lu.ImageSource, overrides: lu.Element.Overrides, opts: ImageOpts, comptime src: std.builtin.SourceLocation) !*lu.Element {
    const decoded = if (self.flags.image_cache)
        try self.image_cache.decode(self.arena, source, .{
            .svg_width = opts.svg_width,
            .svg_height = opts.svg_height,
            .scale = opts.svg_scale,
        })
    else
        try self.image_cache.decodeNoCache(self.arena, source, .{
            .svg_width = opts.svg_width,
            .svg_height = opts.svg_height,
            .scale = opts.svg_scale,
        });
    const natural = lu.Rect{ .w = decoded.width, .h = decoded.height };
    const e = self.allocElement();
    e.* = self.base(natural);
    e.id = idOf(src);
    e.background = lu.Background.imageBuffer(.{
        .buffer = .{
            .pixels = decoded.pixels,
            .width = decoded.width,
            .height = decoded.height,
        },
        .fit = opts.fit,
        .filter = opts.filter,
    });
    e.override(overrides);
    self.evalEvents(e);
    _ = self.publish(e);
    return e;
}
