const std = @import("std");
const lu = @import("src/luxor.zig");

var leaf_layout: lu.Layout = .{ .vtable = &lu.Layout.leaf, .parent = null };

fn mkLeaf(w: u32, h: u32) lu.Element {
    return .{
        .size = .{ .w = w, .h = h },
        .pos = .{ .x = 0, .y = 0 },
        .background = lu.Background.solid(.{ .r = 0, .g = 0, .b = 0, .a = 255 }),
        .layout = &leaf_layout,
        .events = .{ .hover = .{ .handle = null }, .click = .{ .handle = null }, .drag = .{ .handle = null }, .render = .{ .handle = null }, .modify = .{ .handle = null }, .focus = .{ .handle = null }, .key = .{ .handle = null } },
        .focusable = false,
    };
}

const Tree = struct {
    root: lu.Element,
    root_cfg: lu.Layout.FlexConfig,
    root_layout: lu.Layout,
    toolbar: lu.Element,
    toolbar_cfg: lu.Layout.FlexConfig,
    toolbar_layout: lu.Layout,
    field: lu.Element,
    field_cfg: lu.Layout.FlexConfig,
    field_layout: lu.Layout,
    grid: lu.Element,
    grid_cfg: lu.Layout.GridConfig,
    grid_layout: lu.Layout,
    tiles: [8]lu.Element,
    tile_layouts: [8]lu.Layout,
    tile_cfgs: [8]lu.Layout.GridConfig,

    fn init(alloc: std.mem.Allocator, w: u32, h: u32) !*Tree {
        const t = try alloc.create(Tree);
        t.* = Tree{
            .root = mkLeaf(w, h),
            .root_cfg = .{ .direction = .column, .gap = 12, .align_items = .flex_start },
            .root_layout = undefined,
            .toolbar = mkLeaf(0, 0),
            .toolbar_cfg = .{ .direction = .row, .gap = 8, .wrap = true, .sizing = .{ .main = .fixed, .cross = .content } },
            .toolbar_layout = undefined,
            .field = mkLeaf(0, 0),
            .field_cfg = .{ .direction = .row, .gap = 8, .wrap = true, .sizing = .{ .main = .fixed, .cross = .content } },
            .field_layout = undefined,
            .grid = mkLeaf(0, 0),
            .grid_cfg = .{ .columns = 4, .gap = 8, .sizing = .{ .main = .content, .cross = .content } },
            .grid_layout = undefined,
            .tiles = undefined,
            .tile_layouts = undefined,
            .tile_cfgs = [_]lu.Layout.GridConfig{.{ .columns = 1, .gap = 0 }} ** 8,
        };
        t.root_layout = .{ .vtable = &lu.Layout.flex, .parent = null, .data = &t.root_cfg };
        t.root_layout.element = &t.root;
        t.toolbar_layout = .{ .vtable = &lu.Layout.flex, .parent = &t.root_layout, .data = &t.toolbar_cfg };
        t.field_layout = .{ .vtable = &lu.Layout.flex, .parent = &t.root_layout, .data = &t.field_cfg };
        t.grid_layout = .{ .vtable = &lu.Layout.grid, .parent = &t.root_layout, .data = &t.grid_cfg };
        return t;
    }
};

fn buildRadix(t: *Tree, w: u32, h: u32) void {
    _ = t;
    _ = w;
    _ = h;
}

test "repro" {
    const alloc = std.heap.page_allocator;
    var w: u32 = 100;
    while (w <= 320) : (w += 40) {
        var h: u32 = 100;
        while (h <= 400) : (h += 50) {
            try run(alloc, w, h);
        }
    }
}

fn run(alloc: std.mem.Allocator, w: u32, h: u32) !void {
    const t = try Tree.init(alloc, w, h);
    defer alloc.destroy(t);

    // Wire container layouts before the parent measures them for content.
    t.toolbar.layout = &t.toolbar_layout;
    t.field.layout = &t.field_layout;
    t.grid.layout = &t.grid_layout;

    // Labels first (they cannot shrink), then toolbar, field, grid.
    var label1 = mkLeaf(200, 40);
    var label2 = mkLeaf(180, 40);
    var sl1 = lu.Layout{ .vtable = &lu.Layout.mono, .parent = &t.root_layout, .padding = .all(0) };
    var sl2 = lu.Layout{ .vtable = &lu.Layout.mono, .parent = &t.root_layout, .padding = .all(0) };
    label1.layout = &sl1;
    label2.layout = &sl2;
    t.root_layout.addElement(t.root_layout.request(.{ .min_size = .{ .w = 200, .h = 40 } }), label1);
    t.root_layout.addElement(t.root_layout.request(.{ .min_size = .{ .w = 200, .h = 40 } }), label2);

    t.root_layout.addElement(t.root_layout.request(.{ .min_size = .{ .w = 0, .h = 0 }, .align_self = .stretch }), t.toolbar);
    t.root_layout.addElement(t.root_layout.request(.{ .min_size = .{ .w = 0, .h = 0 }, .align_self = .stretch }), t.field);
    t.root_layout.addElement(t.root_layout.request(.{ .min_size = .{ .w = 0, .h = 0 } }), t.grid);

    // toolbar buttons
    for (0..8) |i| {
        const b = mkLeaf(90 + @as(u32, @intCast(i)) * 8, 34);
        t.toolbar_layout.addElement(t.toolbar_layout.request(.{ .min_size = .{ .w = 90 + @as(u32, @intCast(i)) * 8, .h = 34 } }), b);
    }
    // field buttons
    for (0..12) |_| {
        const b = mkLeaf(96, 40);
        t.field_layout.addElement(t.field_layout.request(.{ .min_size = .{ .w = 96, .h = 40 }, .max_size = .{ .w = 168, .h = 40 }, .grow = 1 }), b);
    }
    // grid tiles
    for (0..8) |i| {
        var tile = mkLeaf(40, 40);
        t.tile_layouts[i] = .{ .vtable = &lu.Layout.grid, .parent = &t.grid_layout, .data = &t.tile_cfgs[i] };
        tile.layout = &t.tile_layouts[i];
        t.grid_layout.addElement(t.grid_layout.request(.{ .min_size = .{ .w = 40, .h = 40 } }), tile);
    }

    const children = t.root_layout.lay();
    var bad = false;
    for (children) |c| {
        const y1 = c.pos.y + c.size.h;
        if (y1 > h) bad = true;
    }

    // Check the toolbar's and field's own children for overlaps and leaks
    // outside their container boxes.
    const tb_box = children[2];
    const fd_box = children[3];
    std.debug.print("  ~ {d}x{d}: toolbar(box y={d} h={d}) field(box y={d} h={d})\n", .{ w, h, tb_box.pos.y, tb_box.size.h, fd_box.pos.y, fd_box.size.h });
    {
        const tb = &t.toolbar_layout;
        for (0..tb.cindex) |i| {
            const c = tb.children[i];
            std.debug.print("    tb child{d} y={d} h={d}\n", .{ i, c.pos.y, c.size.h });
            if (c.pos.y + c.size.h > tb_box.pos.y + tb_box.size.h) {
                bad = true;
                std.debug.print("toolbar child [{d}] leaks below toolbar: box y={d} h={d} tb.y={d} tb.h={d}\n", .{ i, c.pos.y, c.size.h, tb_box.pos.y, tb_box.size.h });
            }
        }
    }
    {
        const fd = &t.field_layout;
        for (0..fd.cindex) |i| {
            const c = fd.children[i];
            if (c.pos.y + c.size.h > fd_box.pos.y + fd_box.size.h) {
                bad = true;
                std.debug.print("field child [{d}] leaks below field: box y={d} h={d} fd.y={d} fd.h={d}\n", .{ i, c.pos.y, c.size.h, fd_box.pos.y, fd_box.size.h });
            }
        }
    }
    if (bad) std.debug.print(">> OVERLAP/OUT-OF-BOUNDS at {d}x{d}\n", .{ w, h });
}