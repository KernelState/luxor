/// A layout is a handler that arranges elements in a certain way based on
/// their request of size or position or both. Layouts are usually long lasting
/// objects that are maintained externally, this struct only makes it so you can
/// layout any externally initialized and handled layout handler.
const std = @import("std");
const builtin = @import("builtin");
const lu = @import("luxor.zig");

/// index for the last item in requests
rindex: usize = 0,
/// index for the last item in items
iindex: usize = 0,
requests: [1000]Request = undefined,
/// The actual things getting space, the layout doesn't care about them but them
/// but they're important for the window getting the layout.
items: [1000]Item = undefined,
/// Layout all the saved requests for taking up some size.
fn_lay: *const fn (*Layout) void,
/// A layout can have a parent, this is important for the flow inside of the tree
/// and important for the layout itself to request.
parent: ?*Layout,
/// Index of a request that is waiting for an element to be assigned via addElement.
/// null means no request is pending.
pending: ?usize = null,
/// Opaque pointer for layout-specific data, accessible from the fn_lay callback.
data: ?*const anyopaque = null,
/// The amount of box space this layout is given to lay its children out in.
/// Set by the window right before `lay`, based on the owning element's area.
container: lu.Rect = .{ .w = 0, .h = 0 },
/// Space reserved around the inside edge of the container before children are
/// laid out. Handled centrally by `lay`, so every layout honors it.
padding: lu.Sides = .all(0),
/// The inset origin applied to laid-out items; computed by `lay` from padding.
pad_origin: lu.Pos = .{ .x = 0, .y = 0 },

const Layout = @This();

/// The main axis distribution for a flex layout.
pub const FlexDirection = enum {
    row,
    column,
};

pub const JustifyContent = enum {
    flex_start,
    flex_end,
    center,
    space_between,
    space_around,
    space_evenly,
};

pub const AlignItems = enum {
    flex_start,
    flex_end,
    center,
    stretch,
};

/// Configuration for a CSS-like flex layout. Kept as data on the layout so it
/// can be changed at runtime ("a dynamic value for a config").
pub const FlexConfig = struct {
    direction: FlexDirection = .row,
    justify: JustifyContent = .flex_start,
    align_items: AlignItems = .stretch,
    gap: u32 = 0,
};

/// Configuration for a grid layout. Children are placed row by row into cells.
pub const GridConfig = struct {
    columns: u16 = 1,
    gap: u32 = 0,
};

pub const Item = struct {
    node: lu.Element,
    area: lu.Area,
};

/// A request from an element to get some space from the parent. The element is
/// null until addElement is called.
pub const Request = struct {
    element: ?lu.Element = null,
    min_size: lu.Rect,
    size: ?lu.Rect = null,
    pos: ?lu.Pos = null,
    margin: ?lu.Sides = null,
    /// CSS `flex-grow`.
    grow: u32 = 0,
    /// CSS `flex-shrink` (0 disables shrinking).
    shrink: u32 = 1,
    /// CSS `flex-basis`. Overrides the main-axis size when set.
    basis: ?u32 = null,
    /// CSS `align-self`; overrides the container's cross alignment.
    align_self: ?AlignItems = null,
};

/// Layout all the saved requests for taking up `size` of space, returning the
/// resulting items to render.
pub fn lay(self: *Layout, size: lu.Rect) []Item {
    const p = self.padding;
    self.container = .{
        .w = size.w -| (p.left + p.right),
        .h = size.h -| (p.top + p.bottom),
    };
    self.pad_origin = .{ .x = p.left, .y = p.top };
    self.fn_lay(self);
    const count = self.iindex;
    for (0..count) |i| {
        self.items[i].area.pos.x += self.pad_origin.x;
        self.items[i].area.pos.y += self.pad_origin.y;
    }
    return self.items[0..count];
}

/// Request space from the layout. Asserts that no request is already pending.
/// After calling this, call addElement to assign the element to this slot.
pub fn request(self: *Layout, req: Request) void {
    if (self.pending != null) {
        if (builtin.mode == .Debug) {
            @panic("layout.request called while a pending request exists; call addElement first");
        } else {
            std.log.warn("layout.request called while a pending request exists, ignoring", .{});
            return;
        }
    }
    if (self.rindex == self.requests.len) {
        if (builtin.mode == .Debug) {
            @panic("Reached maximum layout requests");
        } else {
            std.log.warn("Reached maximum layout requests, please contact the developer to fix this");
            return;
        }
    }
    self.requests[self.rindex] = req;
    self.pending = self.rindex;
    self.rindex += 1;
}

/// Assign an element to the last pending request. Asserts that a pending request exists.
pub fn addElement(self: *Layout, element: lu.Element) void {
    const idx = self.pending orelse {
        if (builtin.mode == .Debug) {
            @panic("layout.addElement called with no pending request; call request first");
        } else {
            std.log.warn("layout.addElement called with no pending request, ignoring", .{});
            return;
        }
    };
    self.requests[idx].element = element;
    self.pending = null;
}

// ---------------------------------------------------------------------------
// Flexbox
// ---------------------------------------------------------------------------

const Max = 1000;

/// Fills `layout.items` with the laid-out children of a flex container.
pub fn flexLayout(layout: *Layout) void {
    const cfg: *const FlexConfig = @ptrCast(@alignCast(layout.data orelse return));
    const row = cfg.direction == .row;
    const n_max = @min(layout.rindex, Max);

    var n: usize = 0;
    var basis: [Max]u32 = undefined;
    var grow: [Max]u32 = undefined;
    var shrink: [Max]u32 = undefined;
    var owin: [Max]u32 = undefined; // own cross size
    var alignSelf: [Max]AlignItems = undefined;
    var ord: [Max]u32 = undefined;
    var el: [Max]lu.Element = undefined;
    var inidx: [Max]usize = undefined;

    for (0..n_max) |i| {
        const req = &layout.requests[i];
        if (req.element == null) continue;
        const own = req.size orelse req.min_size;
        basis[n] = req.basis orelse (if (row) own.w else own.h);
        grow[n] = req.grow;
        shrink[n] = req.shrink;
        owin[n] = if (row) own.h else own.w;
        alignSelf[n] = req.align_self orelse cfg.align_items;
        ord[n] = @intCast(i);
        el[n] = req.element.?;
        inidx[n] = i;
        n += 1;
    }
    if (n == 0) {
        layout.iindex = 0;
        return;
    }

    // Stable insertion order (keyed by request index).
    var order: [Max]usize = undefined;
    for (0..n) |i| order[i] = i;
    for (0..n) |i| {
        for (0..(n - 1 - i)) |j| {
            if (ord[order[j]] > ord[order[j + 1]]) {
                const t = order[j];
                order[j] = order[j + 1];
                order[j + 1] = t;
            }
        }
    }

    const msize = if (row) layout.container.w else layout.container.h;
    const csize = if (row) layout.container.h else layout.container.w;

    var total_basis: u64 = 0;
    for (0..n) |k| total_basis += basis[order[k]];
    const free: i64 = @as(i64, msize) - @as(i64, @intCast(total_basis));
    var main: [Max]u32 = undefined;
    if (free >= 0) {
        var grow_w: u64 = 0;
        for (0..n) |k| grow_w += grow[order[k]];
        if (grow_w > 0) {
            var given: i64 = 0;
            for (0..n) |k| {
                const g = order[k];
                const part: i64 = @divTrunc(free * @as(i64, grow[g]), @as(i64, @intCast(grow_w)));
                main[g] = @intCast(basis[g] + @as(u32, @intCast(part)));
                given += part;
            }
            main[order[n - 1]] += @intCast(free - given);
        } else {
            for (0..n) |k| main[order[k]] = basis[order[k]];
        }
    } else {
        const deficit: u64 = @intCast(-free);
        var basis_sum: u64 = 0;
        var shrink_w: u64 = 0;
        for (0..n) |k| {
            shrink_w += shrink[order[k]];
            basis_sum += basis[order[k]];
        }
        if (deficit > 0 and basis_sum > 0) {
            for (0..n) |k| {
                const g = order[k];
                const weight: f64 = @as(f64, @floatFromInt(shrink[g] * basis[g]));
                const share: f64 = weight / @as(f64, @floatFromInt(basis_sum)) * @as(f64, @floatFromInt(deficit));
                main[g] = @intCast(@as(i64, basis[g]) - @as(i64, @intFromFloat(share)));
            }
        } else {
            for (0..n) |k| main[order[k]] = basis[order[k]];
        }
    }

    // Cross sizes.
    var cross: [Max]u32 = undefined;
    var crossstart: [Max]u32 = undefined;
    for (0..n) |k| {
        const g = order[k];
        switch (alignSelf[g]) {
            .stretch => {
                cross[g] = csize;
                crossstart[g] = 0;
            },
            .flex_start => {
                cross[g] = owin[g];
                crossstart[g] = 0;
            },
            .flex_end => {
                cross[g] = owin[g];
                crossstart[g] = csize -| owin[g];
            },
            .center => {
                cross[g] = owin[g];
                crossstart[g] = @divTrunc(csize -| owin[g], 2);
            },
        }
    }

    var used: u64 = 0;
    for (0..n) |k| used += main[order[k]];
    if (n > 1) used += @as(u64, cfg.gap) * @as(u64, n - 1);
    const free_j: i64 = @as(i64, msize) - @as(i64, @intCast(used));

    var cursor: i64 = 0;
    var space: u32 = cfg.gap;
    switch (cfg.justify) {
        .flex_start => cursor = 0,
        .flex_end => cursor = free_j,
        .center => cursor = @divTrunc(free_j, 2),
        .space_between => {
            space = if (n > 1) cfg.gap + @as(u32, @intCast(@divTrunc(@max(0, free_j), @as(i64, @intCast(n - 1))))) else 0;
            cursor = if (n > 1) 0 else @divTrunc(free_j, 2);
        },
        .space_around => {
            const single: u64 = if (n == 0) 0 else @as(u64, @intCast(@max(0, free_j))) / @as(u64, n);
            cursor = @intCast(@divTrunc(@as(i64, @intCast(single)), 2));
            space = cfg.gap + @as(u32, @intCast(single));
        },
        .space_evenly => {
            const single: u64 = if (n == 0) 0 else @as(u64, @intCast(@max(0, free_j))) / @as(u64, n + 1);
            cursor = @intCast(single);
            space = cfg.gap + @as(u32, @intCast(single));
        },
    }

    layout.iindex = 0;
    for (0..n) |k| {
        const g = order[k];
        var area: lu.Area = undefined;
        if (row) {
            area = .{
                .pos = .{ .x = @intCast(cursor), .y = crossstart[g] },
                .size = .{ .w = main[g], .h = cross[g] },
            };
        } else {
            area = .{
                .pos = .{ .x = crossstart[g], .y = @intCast(cursor) },
                .size = .{ .w = cross[g], .h = main[g] },
            };
        }
        cursor += @as(i64, main[g]) + @as(i64, space);
        layout.items[layout.iindex] = .{ .node = el[g], .area = area };
        layout.iindex += 1;
    }
}

// ---------------------------------------------------------------------------
// Grid
// ---------------------------------------------------------------------------

pub fn gridLayout(layout: *Layout) void {
    const cfg: *const GridConfig = @ptrCast(@alignCast(layout.data orelse return));
    var n: usize = 0;
    for (0..layout.rindex) |i| {
        if (layout.requests[i].element != null) n += 1;
    }
    if (n == 0) {
        layout.iindex = 0;
        return;
    }
    const cols: usize = @max(1, cfg.columns);
    const rows: usize = @divTrunc(n, cols) + @intFromBool(@rem(n, cols) != 0);
    const col_w = @divTrunc(layout.container.w, @as(u32, @intCast(cols)));
    const row_h = @divTrunc(layout.container.h, @as(u32, @intCast(@max(1, rows))));

    layout.iindex = 0;
    var i: usize = 0;
    for (0..layout.rindex) |idx| {
        if (layout.requests[idx].element == null) continue;
        const col = i % cols;
        const r = i / cols;
        var area = lu.Area{
            .pos = .{
                .x = @intCast(col * (col_w + cfg.gap)),
                .y = @intCast(r * (row_h + cfg.gap)),
            },
            .size = .{ .w = col_w, .h = row_h },
        };
        const child = layout.requests[idx].size orelse layout.requests[idx].min_size;
        if (child.h < area.size.h) area.size.h = child.h;
        layout.items[layout.iindex] = .{ .node = layout.requests[idx].element.?, .area = area };
        layout.iindex += 1;
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn mkElement(layout: *lu.Layout, w: u32, h: u32) lu.Element {
    return .{
        .size = .{ .w = w, .h = h },
        .pos = .{ .x = 0, .y = 0 },
        .background = lu.Background.solid(.{ .r = 0, .g = 0, .b = 0, .a = 255 }),
        .layout = layout,
        .events = .{
            .hover = .{ .handle = null },
            .click = .{ .handle = null },
            .drag = .{ .handle = null },
            .render = .{ .handle = null },
            .modify = .{ .handle = null },
            .focus = .{ .handle = null },
            .key = .{ .handle = null },
        },
        .focusable = false,
    };
}

fn mkLayout() Layout {
    return .{
        .fn_lay = &flexLayout,
        .parent = null,
    };
}

test "flex row lays children in order with gap" {
    var layout = mkLayout();
    var cfg = FlexConfig{ .direction = .row, .gap = 4 };
    layout.data = &cfg;

    const e1 = mkElement(&layout, 10, 20);
    const e2 = mkElement(&layout, 30, 20);
    layout.request(.{ .min_size = .{ .w = 10, .h = 20 } });
    layout.addElement(e1);
    layout.request(.{ .min_size = .{ .w = 30, .h = 20 } });
    layout.addElement(e2);

    const items = layout.lay(.{ .w = 100, .h = 40 });
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(i32, 0), items[0].area.pos.x);
    try std.testing.expectEqual(@as(u32, 10), items[0].area.size.w);
    try std.testing.expectEqual(@as(i32, 14), items[1].area.pos.x);
    try std.testing.expectEqual(@as(u32, 30), items[1].area.size.w);
    // stretch cross axis
    try std.testing.expectEqual(@as(u32, 40), items[0].area.size.h);
}

test "flex row grow fills free space" {
    var layout = mkLayout();
    var cfg = FlexConfig{ .direction = .row };
    layout.data = &cfg;

    const e1 = mkElement(&layout, 0, 10);
    const e2 = mkElement(&layout, 0, 10);
    layout.request(.{ .min_size = .{ .w = 0, .h = 10 }, .grow = 1 });
    layout.addElement(e1);
    layout.request(.{ .min_size = .{ .w = 0, .h = 10 }, .grow = 3 });
    layout.addElement(e2);

    const items = layout.lay(.{ .w = 100, .h = 10 });
    try std.testing.expectEqual(@as(u32, 25), items[0].area.size.w);
    try std.testing.expectEqual(@as(u32, 75), items[1].area.size.w);
}

test "flex column justify flex_end" {
    var layout = mkLayout();
    var cfg = FlexConfig{ .direction = .column, .justify = .flex_end };
    layout.data = &cfg;

    const e1 = mkElement(&layout, 10, 10);
    layout.request(.{ .min_size = .{ .w = 10, .h = 10 } });
    layout.addElement(e1);

    const items = layout.lay(.{ .w = 20, .h = 100 });
    try std.testing.expectEqual(@as(i32, 90), items[0].area.pos.y);
}

test "grid places children into cells" {
    var layout = mkLayout();
    var cfg = GridConfig{ .columns = 2, .gap = 0 };
    layout.data = &cfg;

    const e1 = mkElement(&layout, 5, 5);
    const e2 = mkElement(&layout, 5, 5);
    const e3 = mkElement(&layout, 5, 5);
    layout.request(.{ .min_size = .{ .w = 5, .h = 5 } });
    layout.addElement(e1);
    layout.request(.{ .min_size = .{ .w = 5, .h = 5 } });
    layout.addElement(e2);
    layout.request(.{ .min_size = .{ .w = 5, .h = 5 } });
    layout.addElement(e3);

    const items = layout.lay(.{ .w = 100, .h = 100 });
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(i32, 0), items[0].area.pos.x);
    try std.testing.expectEqual(@as(i32, 50), items[1].area.pos.x);
    try std.testing.expectEqual(@as(i32, 0), items[2].area.pos.y);
}