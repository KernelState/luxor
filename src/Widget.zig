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

fn leafLayout(_: *lu.Layout) void {}

const Widget = @This();

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

pub const LabelOpts = struct {
    font_idx: usize = 0,
    size: u32 = 24,
    spacing: lu.Rect = .{ .w = 2, .h = 4 },
    direction: Font.Direction = .ltr,
    color: lu.Color = .white,
    render: Font.RenderOpts = .{},
    padding: lu.Sides = .all(0),
};

pub const MonoData = struct {
    padding: lu.Sides,
    child_size: lu.Rect,
};

fn monoLayout(layout: *lu.Layout) void {
    layout.iindex = 0;
    if (layout.rindex == 0) return;
    const req = layout.requests[0];
    const element = req.element orelse return;
    const data: *MonoData = @ptrCast(@alignCast(layout.data orelse {
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
    const outer_w = (req.size orelse req.min_size).w;
    const outer_h = (req.size orelse req.min_size).h;
    const pad = data.padding;
    const content_w = outer_w -| (pad.left + pad.right);
    const content_h = outer_h -| (pad.top + pad.bottom);
    const cx = @divTrunc(@as(i32, @intCast(content_w)) -| @as(i32, @intCast(data.child_size.w)), 2);
    const cy = @divTrunc(@as(i32, @intCast(content_h)) -| @as(i32, @intCast(data.child_size.h)), 2);
    layout.items[0] = .{
        .node = element,
        .area = .{
            .pos = .{
                .x = @intCast(@max(0, cx)),
                .y = @intCast(@max(0, cy)),
            },
            .size = data.child_size,
        },
    };
    layout.iindex = 1;
}

pub fn label(
    self: *Widget,
    layout: *lu.Layout,
    text: []const u8,
    pos: lu.Pos,
    label_opts: LabelOpts,
    overrides: lu.Element.Overrides,
) !void {
    const font = &self.fonts[label_opts.font_idx];
    const text_size = try font.textSize(self.arena.allocator(), text, label_opts.size, label_opts.direction);
    const pixel_buf = try font.renderText(
        self.arena.allocator(),
        text,
        text_size,
        label_opts.spacing,
        label_opts.size,
        label_opts.direction,
        label_opts.color,
        label_opts.render,
    );

    const inner = lu.Element{
        .size = text_size,
        .pos = .{ .x = 0, .y = 0 },
        .background = lu.Background.buffer(pixel_buf),
        .layout = &self.leaf_layout,
        .focusable = false,
        .events = .{
            .hover = .{ .handle = null },
            .click = .{ .handle = null },
            .drag = .{ .handle = null },
            .render = .{ .handle = null },
            .modify = .{ .handle = null },
            .focus = .{ .handle = null },
            .key = .{ .handle = null },
        },
    };

    const pad = label_opts.padding;

    const outer_size = lu.Rect{
        .w = text_size.w + pad.left + pad.right,
        .h = text_size.h + pad.top + pad.bottom,
    };

    const mono_data = try self.arena.allocator().create(MonoData);
    mono_data.* = .{ .padding = pad, .child_size = text_size };

    const mono = try self.arena.allocator().create(lu.Layout);
    mono.* = .{
        .fn_lay = &monoLayout,
        .parent = layout,
        .data = mono_data,
    };

    var outer = lu.Element{
        .size = outer_size,
        .pos = pos,
        .background = lu.Background.solid(.{ .r = 0, .g = 0, .b = 0, .a = 0 }),
        .layout = mono,
        .focusable = false,
        .events = .{
            .hover = .{ .handle = null },
            .click = .{ .handle = null },
            .drag = .{ .handle = null },
            .render = .{ .handle = null },
            .modify = .{ .handle = null },
            .focus = .{ .handle = null },
            .key = .{ .handle = null },
        },
    };
    outer.override(overrides);

    layout.request(outer_size, null, pos, null);
    layout.addElement(outer);

    mono.request(text_size, null, .{ .x = 0, .y = 0 }, null);
    mono.addElement(inner);
}
