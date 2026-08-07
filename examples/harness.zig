const std = @import("std");
const lu = @import("luxor");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var freetype = try lu.Context.Freetype.init();
    defer freetype.deinit();
    var font = try freetype.createFont("/usr/share/fonts/noto/NotoSansArabic-Regular.ttf", 28);
    defer font.deinit();

    const text = "\u{645}\u{631}\u{62D}\u{628}\u{627} \u{628}\u{644}\u{639}\u{627}\u{644}\u{645}";
    std.debug.print("text.len={d}\n", .{text.len});
    const shaped = try font.shapeText(alloc, text, .rtl);
    var tw: i64 = 0;
    for (shaped.glyphs) |g| {
        std.debug.print("gid={d} adv={d} off={d},{d} cluster={d} cw={d} ch={d} bl={d} bt={d}\n", .{ g.glyph_index, g.x_advance, g.x_offset, g.y_offset, g.cluster, g.width, g.height, g.bitmap_left, g.bitmap_top });
        tw += @as(i64, g.x_advance);
    }
    std.debug.print("sum adv={d} => {d}px\n", .{ tw, @divTrunc(tw, 64) });
    const size = try font.textSize(alloc, text, 28, .rtl, 400);
    std.debug.print("textSize={d}x{d} shaped height={d} ascender={d}\n", .{ size.w, size.h, shaped.height, shaped.ascender });
    const buf = try font.renderText(alloc, text, size, .{ .w = 2, .h = 4 }, 28, .rtl, .{ .r = 255, .g = 255, .b = 255, .a = 255 }, .{}, .{ .x = 0, .y = 0 }, null, 400);
    std.debug.print("textSize={d}x{d} buffer={d}x{d}\n", .{ size.w, size.h, buf.width, buf.height });

    {
        const stdout = std.posix.STDOUT_FILENO;
        var buf2: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(&buf2, "P5\n{d} {d}\n255\n", .{ buf.width, buf.height });
        const hw: usize = @intCast(std.os.linux.write(stdout, header.ptr, header.len));
        _ = hw;
        var rows: [1024]u8 = undefined;
        for (0..buf.height) |y| {
            for (0..buf.width) |x| {
                const i = (y * buf.width + x) * 4;
                rows[@intCast(x)] = buf.pixels[i];
            }
            var off: usize = 0;
            while (off < buf.width) {
                const n: usize = @intCast(std.os.linux.write(stdout, rows[off..].ptr, buf.width - off));
                off += n;
            }
        }
        return;
    }

    var arr: [4096]u8 = undefined;
    for (0..buf.height) |y| {
        var len: usize = 0;
        for (0..buf.width) |x| {
            const i = (y * buf.width + x) * 4;
            const v: f32 = @as(f32, @floatFromInt(buf.pixels[i])) * 0.299 + @as(f32, @floatFromInt(buf.pixels[i + 1])) * 0.587 + @as(f32, @floatFromInt(buf.pixels[i + 2])) * 0.114 + @as(f32, @floatFromInt(buf.pixels[i + 3]));
            const c: u8 = if (v > 480) '#' else if (v > 320) '+' else if (v > 200) ':' else if (v > 100) '.' else ' ';
            arr[len] = c;
            len += 1;
        }
        std.debug.print("{s}\n", .{arr[0..len]});
    }
}