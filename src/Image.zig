/// Image decoding and caching.
///
/// Decodes PNG/JPEG/WebP through the installed system libraries (libpng,
/// libjpeg, libwebp via the C shim in `vendor/luxor_c`) and SVG through the
/// vendored nanosvg rasterizer. Every decoder produces a flat RGBA8888 buffer.
///
/// Decoding is expensive, so `Cache` memoizes the decoded buffers: it keys them
/// by a hash of the source bytes plus the raster settings that change the
/// output, and only decodes once per unique key. The buffers are allocated in
/// the caller's allocator (the widget arena) and live as long as it does.
const std = @import("std");
const lu = @import("luxor.zig");
const c = @cImport({
    @cInclude("image_shim.h");
});

pub const Decoded = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
};

/// Raster settings that affect the decoded output. Only SVG is vector so only
/// it honors these; raster formats always decode at their natural resolution.
pub const DecodeOpts = struct {
    /// Target raster width for SVG; 0 = natural width (times `scale`).
    svg_width: u32 = 0,
    /// Target raster height for SVG; 0 = natural height (times `scale`).
    svg_height: u32 = 0,
    /// Multiplies the natural SVG size when no explicit raster size is given.
    scale: f32 = 1.0,
};

const hash_seed = 0x6a17e93e;

pub const Cache = struct {
    pub const Node = struct {
        key: u64,
        decoded: Decoded,
        next: ?*Node,
    };

    first: ?*Node = null,

    /// Returns the decoded image for `src`, decoding (and caching) it on a
    /// miss. `buffer` sources bypass the cache entirely: the caller already
    /// owns those pixels.
    pub fn decode(self: *Cache, alloc: std.mem.Allocator, src: lu.ImageSource, opts: DecodeOpts) !Decoded {
        switch (src) {
            .buffer => |pb| return .{ .pixels = pb.pixels, .width = pb.width, .height = pb.height },
            .png, .jpeg, .webp => |bytes| {
                const key = rasterKey(src, bytes);
                if (self.lookup(key)) |d| return d;
                const d = try decodeRaster(alloc, src, bytes);
                try self.store(alloc, key, d);
                return d;
            },
            .svg => |text| {
                const key = svgKey(text, opts);
                if (self.lookup(key)) |d| return d;
                const d = try decodeSVG(alloc, text, opts);
                try self.store(alloc, key, d);
                return d;
            },
        }
    }

    fn lookup(self: *Cache, key: u64) ?Decoded {
        var cur = self.first;
        while (cur) |node| : (cur = node.next) {
            if (node.key == key) return node.decoded;
        }
        return null;
    }

    fn store(self: *Cache, alloc: std.mem.Allocator, key: u64, decoded: Decoded) !void {
        const node = try alloc.create(Node);
        node.* = .{ .key = key, .decoded = decoded, .next = self.first };
        self.first = node;
    }
};

fn rasterKey(src: lu.ImageSource, bytes: []const u8) u64 {
    var h = std.hash.Wyhash.init(hash_seed);
    switch (src) {
        .png => h.update("png"),
        .jpeg => h.update("jpeg"),
        .webp => h.update("webp"),
        else => unreachable,
    }
    h.update(bytes);
    return h.final();
}

fn svgKey(text: []const u8, opts: DecodeOpts) u64 {
    var h = std.hash.Wyhash.init(hash_seed);
    h.update("svg");
    h.update(text);
    h.update(std.mem.asBytes(&opts.svg_width));
    h.update(std.mem.asBytes(&opts.svg_height));
    h.update(std.mem.asBytes(&opts.scale));
    return h.final();
}

fn decodeRaster(alloc: std.mem.Allocator, src: lu.ImageSource, bytes: []const u8) !Decoded {
    switch (src) {
        .png => return decodeViaC(alloc, c.luxor_decode_png, bytes),
        .jpeg => return decodeViaC(alloc, c.luxor_decode_jpeg, bytes),
        .webp => return decodeViaC(alloc, c.luxor_decode_webp, bytes),
        else => unreachable,
    }
}

fn decodeViaC(alloc: std.mem.Allocator, comptime f: anytype, bytes: []const u8) !Decoded {
    var w: c_int = 0;
    var h: c_int = 0;
    const raw = f(bytes.ptr, bytes.len, &w, &h) orelse return error.ImageDecodeFailed;
    defer c.luxor_free_image(raw);
    const len: usize = @intCast(@as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4);
    const out = try alloc.alloc(u8, len);
    @memcpy(out, raw[0..len]);
    return .{
        .pixels = out,
        .width = @intCast(w),
        .height = @intCast(h),
    };
}

fn decodeSVG(alloc: std.mem.Allocator, text: []const u8, opts: DecodeOpts) !Decoded {
    const mutable = try alloc.allocSentinel(u8, text.len, 0);
    defer alloc.free(mutable);
    @memcpy(mutable, text);

    var nw: c_int = 0;
    var nh: c_int = 0;
    if (c.luxor_svg_natural_size(mutable.ptr, &nw, &nh) == 0)
        return error.ImageDecodeFailed;

    var tw: u32 = opts.svg_width;
    var th: u32 = opts.svg_height;
    if (tw == 0 and th == 0) {
        tw = @intFromFloat(@as(f32, @floatFromInt(nw)) * opts.scale);
        th = @intFromFloat(@as(f32, @floatFromInt(nh)) * opts.scale);
    } else if (tw == 0) {
        tw = @intFromFloat(@as(f32, @floatFromInt(th)) * @as(f32, @floatFromInt(nw)) / @as(f32, @floatFromInt(nh)));
    } else if (th == 0) {
        th = @intFromFloat(@as(f32, @floatFromInt(tw)) * @as(f32, @floatFromInt(nh)) / @as(f32, @floatFromInt(nw)));
    }
    if (tw == 0 or th == 0) return error.ImageDecodeFailed;

    var rw: c_int = 0;
    var rh: c_int = 0;
    const raw = c.luxor_svg_render(mutable.ptr, @intCast(tw), @intCast(th), &rw, &rh) orelse
        return error.ImageDecodeFailed;
    defer c.luxor_free_image(raw);

    const len: usize = @intCast(@as(usize, @intCast(rw)) * @as(usize, @intCast(rh)) * 4);
    const out = try alloc.alloc(u8, len);
    @memcpy(out, raw[0..len]);
    return .{
        .pixels = out,
        .width = @intCast(rw),
        .height = @intCast(rh),
    };
}
