/// This is just a simple collection of widgets that you can easily replace
/// and make your own `Element` generators
///
/// This is not the widget itself, the name might be misleading because this is
/// just a simple collection of data that the widgets will use, you need only
/// one of these per application, it's more like a piece of context.
const std = @import("std");
const lu = @import("luxor.zig");
const c = @cImport({
    @cInclude("freetype2/freetype/freetype.h");
    @cInclude("harfbuzz/hb.h");
    @cInclude("harfbuzz/hb-ft.h");
});

arena: std.heap.ArenaAllocator,
freetype: Freetype,
fonts: [10]Font = undefined,
font_count: u8 = 0,
/// Empty layout for leaf elements that have no children.
leaf_layout: lu.Layout = .{ .fn_lay = &leafLayout, .parent = null },
/// Memoizes decoded images across frames; buffers live in `arena`.
image_cache: lu.images.Cache = .{},

fn leafLayout(_: *lu.Layout) void {}

const Widget = @This();

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
fn base(self: *Widget, size: lu.Rect) lu.Element {
    return .{
        .size = size,
        .pos = .{ .x = 0, .y = 0 },
        .border_radius = .all(0),
        .background = lu.Background.solid(.{ .r = 0, .g = 0, .b = 0, .a = 0 }),
        .layout = &self.leaf_layout,
        .events = noEvents,
        .focusable = false,
    };
}

/// Requests `e`'s size and position from `parent`'s layout and places `e`
/// there. This is the only place a widget talks to a layout.
fn publish(self: *Widget, parent: *lu.Element, e: *const lu.Element) void {
    _ = self;
    parent.layout.request(.{ .min_size = e.size, .pos = e.pos, .margin = e.margin });
    parent.layout.addElement(e.*);
}

/// A layout that places each child at exactly its requested position and size.
fn absoluteLayout(layout: *lu.Layout) void {
    layout.iindex = 0;
    for (layout.requests[0..layout.rindex]) |req| {
        const element = req.element orelse continue;
        layout.items[layout.iindex] = .{
            .node = element,
            .area = .{
                .pos = req.pos orelse .{ .x = 0, .y = 0 },
                .size = req.size orelse req.min_size,
            },
        };
        layout.iindex += 1;
    }
}

fn makeAbsolute(self: *Widget, parent: *lu.Layout) *lu.Layout {
    const layout = self.arena.allocator().create(lu.Layout) catch unreachable;
    layout.* = .{ .fn_lay = &absoluteLayout, .parent = parent };
    return layout;
}

fn makeMono(self: *Widget, parent: *lu.Layout, pad: lu.Sides, child_size: lu.Rect) *lu.Layout {
    const data = self.arena.allocator().create(MonoData) catch unreachable;
    data.* = .{ .child_size = child_size };
    const layout = self.arena.allocator().create(lu.Layout) catch unreachable;
    layout.* = .{ .fn_lay = &monoLayout, .parent = parent, .padding = pad, .data = data };
    return layout;
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

    /// Get the bounding box of text without rendering.
    pub fn textSize(self: *Font, alloc: std.mem.Allocator, text: []const u8, size: u32, direction: Direction) !lu.Rect {
        try self.setCharSize(size);
        const shaped = try self.shapeText(alloc, text, direction);
        return .{
            .w = @intCast(@max(0, shaped.width)),
            .h = @intCast(@max(0, shaped.height)),
        };
    }

    /// Render shaped text into a pixel buffer. The returned buffer is RGBA8888.
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
    ) !lu.PixelBuffer {
        try self.setCharSize(size);
        const shaped = try self.shapeText(alloc, text, direction);
        defer alloc.free(shaped.glyphs);

        const buf_w = area.w;
        const buf_h = area.h;
        var pixels = try alloc.alloc(u8, buf_w * buf_h * 4);
        @memset(pixels, 0);

        var pen_x: i32 = 0;
        var pen_y: i32 = shaped.ascender;
        const line_start_x: i32 = 0;
        const line_height: i32 = @intCast(self.pixel_size + spacing.h);

        for (shaped.glyphs) |glyph| {
            const adv_x: i32 = @intCast(@divTrunc(glyph.x_advance, 64));
            const off_x: i32 = @intCast(@divTrunc(glyph.x_offset, 64));
            const off_y: i32 = @intCast(@divTrunc(glyph.y_offset, 64));

            if (opts.overflow_w == .newline and pen_x - line_start_x + adv_x > @as(i32, @intCast(area.w))) {
                pen_x = line_start_x;
                pen_y += line_height;
                if (opts.overflow_h == .skip and pen_y > @as(i32, @intCast(area.h))) break;
            }

            const draw_x = pen_x + off_x;
            const draw_y = pen_y + off_y - glyph.bitmap_top;

            _ = c.FT_Load_Glyph(self.face, glyph.glyph_index, c.FT_LOAD_DEFAULT);
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

            pen_x += adv_x;
        }

        return .{
            .pixels = pixels,
            .width = buf_w,
            .height = buf_h,
        };
    }
};

pub const MonoData = struct {
    child_size: lu.Rect,
};

fn monoLayout(layout: *lu.Layout) void {
    layout.iindex = 0;
    if (layout.rindex == 0) return;
    const req = layout.requests[0];
    const element = req.element orelse return;
    const data: *const MonoData = @ptrCast(@alignCast(layout.data orelse {
        layout.items[0] = .{
            .node = element,
            .area = .{
                .pos = req.pos orelse .{ .x = 0, .y = 0 },
                .size = req.size orelse req.min_size,
            },
        };
        layout.iindex = 1;
        return;
    }));
    const outer_w = layout.container.w;
    const outer_h = layout.container.h;
    const cw = outer_w -| data.child_size.w;
    const ch = outer_h -| data.child_size.h;
    layout.items[0] = .{
        .node = element,
        .area = .{
            .pos = .{
                .x = @divTrunc(cw, 2),
                .y = @divTrunc(ch, 2),
            },
            .size = data.child_size,
        },
    };
    layout.iindex = 1;
}

/// Widgets are functions that spit out an element. They take the parent to
/// place themselves in, their main input (text, a value, an image source...),
/// the user `Overrides`, and a widget-specific `Opts` struct. Every widget
/// builds on `box`, sets its own contents, applies the user `Overrides` last
/// (so the user always wins), then requests space from `parent`'s layout and
/// returns the element. Nothing holds state: the caller owns the returned
/// element and re-creates it every time the tree is rebuilt.

/// The simplest widget: requests `size` from `parent`'s layout, applies
/// `overrides`, and returns a plain element. No contents, no opts.
pub fn box(self: *Widget, parent: *lu.Element, size: lu.Rect, overrides: lu.Element.Overrides) lu.Element {
    var e = self.base(size);
    e.override(overrides);
    self.publish(parent, &e);
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
};

/// Renders `text` into a leaf element (a pixel-buffer background). Used by
/// `label` and reused by anything that puts text in a box (`button`).
fn textElement(self: *Widget, text: []const u8, opts: LabelOpts) !lu.Element {
    const font = &self.fonts[opts.font_idx];
    const text_size = try font.textSize(self.arena.allocator(), text, opts.size, opts.direction);
    const pixel_buf = try font.renderText(
        self.arena.allocator(),
        text,
        text_size,
        opts.spacing,
        opts.size,
        opts.direction,
        opts.color,
        opts.render,
    );
    return .{
        .size = text_size,
        .pos = .{ .x = 0, .y = 0 },
        .background = lu.Background.buffer(pixel_buf),
        .layout = &self.leaf_layout,
        .focusable = false,
        .events = noEvents,
    };
}

/// A box of text, padded and centered.
pub fn label(self: *Widget, parent: *lu.Element, text: []const u8, overrides: lu.Element.Overrides, opts: LabelOpts) !lu.Element {
    const inner = try self.textElement(text, opts);
    const pad = opts.padding;
    var e = self.base(.{ .w = 0, .h = 0 });
    e.override(overrides);
    const border = e.border;
    e.size = .{
        .w = inner.size.w + pad.left + pad.right + border.left + border.right,
        .h = inner.size.h + pad.top + pad.bottom + border.top + border.bottom,
    };
    e.layout = self.makeMono(parent.layout, pad, inner.size);
    e.layout.request(.{ .min_size = inner.size, .pos = .{ .x = 0, .y = 0 } });
    e.layout.addElement(inner);
    self.publish(parent, &e);
    return e;
}

/// Fine-tunable knobs for buttons.
pub const ButtonOpts = struct {
    label: LabelOpts = .{},
    padding: lu.Sides = .all(8),
    color: lu.Color = .gray,
    radius: lu.Corners = .all(4),
};

/// A tappable box with a centered label.
pub fn button(self: *Widget, parent: *lu.Element, text: []const u8, overrides: lu.Element.Overrides, opts: ButtonOpts) !lu.Element {
    const inner = try self.textElement(text, opts.label);
    const pad = opts.padding;
    var e = self.base(.{ .w = 0, .h = 0 });
    e.background = lu.Background.solid(opts.color);
    e.border_radius = opts.radius;
    e.override(overrides);
    const border = e.border;
    e.size = .{
        .w = inner.size.w + pad.left + pad.right + border.left + border.right,
        .h = inner.size.h + pad.top + pad.bottom + border.top + border.bottom,
    };
    e.layout = self.makeMono(parent.layout, pad, inner.size);
    e.layout.request(.{ .min_size = inner.size, .pos = .{ .x = 0, .y = 0 } });
    e.layout.addElement(inner);
    self.publish(parent, &e);
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
pub fn checkbox(self: *Widget, parent: *lu.Element, checked: bool, overrides: lu.Element.Overrides, opts: CheckboxOpts) lu.Element {
    var e = self.base(opts.size);
    e.border = opts.border;
    e.border_color = .{ .color = opts.border_color };
    e.border_radius = opts.radius;
    if (checked) e.background = lu.Background.solid(opts.checked_color);
    e.override(overrides);
    self.publish(parent, &e);
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
pub fn progress_bar(self: *Widget, parent: *lu.Element, value: f32, overrides: lu.Element.Overrides, opts: ProgressBarOpts) lu.Element {
    const v = std.math.clamp(value, 0.0, 1.0);
    var e = self.base(opts.size);
    e.background = lu.Background.solid(opts.track_color);
    e.border_radius = opts.radius;
    e.layout = self.makeAbsolute(parent.layout);

    const fill_w: u32 = @intFromFloat(@as(f32, @floatFromInt(opts.size.w)) * v);
    if (fill_w > 0) {
        var fill = self.base(.{ .w = fill_w, .h = opts.size.h });
        fill.background = lu.Background.solid(opts.fill_color);
        const r = opts.radius;
        fill.border_radius = if (fill_w >= opts.size.w)
            r
        else
            .{ .top_left = r.top_left, .bottom_left = r.bottom_left, .top_right = 0, .bottom_right = 0 };
        e.layout.request(.{ .min_size = fill.size, .pos = .{ .x = 0, .y = 0 } });
        e.layout.addElement(fill);
    }

    e.override(overrides);
    self.publish(parent, &e);
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
pub fn slider(self: *Widget, parent: *lu.Element, value: f32, overrides: lu.Element.Overrides, opts: SliderOpts) lu.Element {
    const v = std.math.clamp(value, 0.0, 1.0);
    var e = self.base(opts.size);
    e.background = lu.Background.solid(opts.track_color);
    e.border_radius = opts.radius;
    e.layout = self.makeAbsolute(parent.layout);

    const fill_w: u32 = @intFromFloat(@as(f32, @floatFromInt(opts.size.w)) * v);
    if (fill_w > 0) {
        var fill = self.base(.{ .w = fill_w, .h = opts.size.h });
        fill.background = lu.Background.solid(opts.fill_color);
        const r = opts.radius;
        fill.border_radius = if (fill_w >= opts.size.w)
            r
        else
            .{ .top_left = r.top_left, .bottom_left = r.bottom_left, .top_right = 0, .bottom_right = 0 };
        e.layout.request(.{ .min_size = fill.size, .pos = .{ .x = 0, .y = 0 } });
        e.layout.addElement(fill);
    }

    const knob_size = if (opts.knob_size == 0) opts.size.h else opts.knob_size;
    const travel = opts.size.w -| knob_size;
    const kx: u32 = @intFromFloat(@as(f32, @floatFromInt(travel)) * v);
    const ky = (opts.size.h -| knob_size) / 2;
    var knob = self.base(.{ .w = knob_size, .h = knob_size });
    knob.background = lu.Background.solid(opts.knob_color);
    knob.border_radius = .all(knob_size / 2);
    e.layout.request(.{ .min_size = knob.size, .pos = .{ .x = kx, .y = ky } });
    e.layout.addElement(knob);

    e.override(overrides);
    self.publish(parent, &e);
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
pub fn image(self: *Widget, parent: *lu.Element, source: lu.ImageSource, overrides: lu.Element.Overrides, opts: ImageOpts) !lu.Element {
    const decoded = try self.image_cache.decode(self.arena.allocator(), source, .{
        .svg_width = opts.svg_width,
        .svg_height = opts.svg_height,
        .scale = opts.svg_scale,
    });
    const natural = lu.Rect{ .w = decoded.width, .h = decoded.height };
    var e = self.base(natural);
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
    self.publish(parent, &e);
    return e;
}
