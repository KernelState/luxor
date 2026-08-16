/// A layout is a vtable plus an opaque config plus the state the layout kind
/// itself manages. Applications and widgets build a layout by picking a kind
/// (`Layout.flex`, `Layout.grid`, ...), supplying a kind-specific config
/// through `data`, and connecting a `parent`. Layouts are built bottom-up with
/// `start`/`request`/`end` and laid out top-down by the window with `lay`: each
/// layout reads its own element's size (through a back-pointer) and writes each
/// child's final `.size`/`.pos` onto the child element itself, then recurses
/// into the children that are containers. Layout kinds are just values with
/// that vtable.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const lu = @import("luxor.zig");

/// The number of requests/children a single layout can hold in one SizedBox
/// pass. Elements are referenced by pointer (into the widget's element pool),
/// never by value, so `Element` can embed a `Layout` by value without a
/// size-recursion loop. Configurable at build time with `-Dlayout-inner=<n>`;
/// the default matches the library's baseline.
pub const Inner = options.inner;
/// Size of working scratch buffers used while laying out a container. Content
/// with more children than this cannot be laid out. Configurable at build time
/// with `-Dlayout-max=<n>`.
pub const Max = options.max;

pub const Layout = struct {
    /// The layout kind (flex, grid, ...).
    vtable: *const VTable,
    /// Opaque per-kind configuration. Layouts read all their behavior from
    /// here; applications and widgets never touch the layout's state.
    data: ?*anyopaque = null,
    /// The layout that will lay this one out; null for the root.
    parent: ?*Layout = null,
    /// Space reserved around the inside edge of the container before children
    /// are laid out. Handled centrally by `lay`, so every layout honors it.
    padding: lu.Sides = .all(0),
    /// The element this layout is attached to, set by `addElement` when the
    /// element is placed (or by the app/window for the root). `lay` reads the
    /// size and position to lay into from here, and `start`/`end` reach the
    /// widget through the element's `widget` pointer, so neither takes an
    /// argument.
    element: ?*lu.Element = null,
    /// The allocator the layout grows its loaded children/requests from. Set
    /// by `Context` when the layout is created (see `Context.allocator`), so
    /// element structs stay tiny: the arrays live in one scratch buffer shared
    /// by the whole frame instead of being copied into every element. Layouts
    /// built without a Context fall back to their element's context, or the
    /// page allocator when neither exists (tests).
    allocator: ?std.mem.Allocator = null,
    /// The laid-out children, filled by `lay`. Each child's `.size` and `.pos`
    /// are final (world space). The window walks this list to draw. Children
    /// are pointers into the widget's element pool, never stored by value.
    /// Grows from `allocatorOf` so element structs stay tiny.
    children: std.ArrayListUnmanaged(*lu.Element) = .{ .items = &.{}, .capacity = 0 },
    /// Number of laid-out children.
    cindex: usize = 0,
    /// The box this layout lays its children into, set by `lay`.
    container: lu.Rect = .{ .w = 0, .h = 0 },
    /// The saved requests from the build phase (`request` + `addElement`).
    requests: std.ArrayListUnmanaged(Request) = .{ .items = &.{}, .capacity = 0 },
    /// Next free slot in `requests`.
    rindex: usize = 0,

    /// The set of operations a layout kind provides.
    pub const VTable = struct {
        /// Fill `layout.children` from `layout.requests`, using `layout.container`.
        lay: *const fn (*Layout) void,
        /// The world size this layout wants along its content axes, given the
        /// box it is about to be given. `null` when a layout fills whatever
        /// it is given (no content axes). Parents call this during their own
        /// `lay` to size content-sized children; the public API never does.
        content: ?*const fn (*Layout, lu.Rect) ?lu.Rect = null,
    };

    // Layout kinds are just values with that vtable.
    pub const flex = VTable{ .lay = flexLay, .content = flexContent };
    pub const grid = VTable{ .lay = gridLay, .content = gridContent };
    pub const absolute = VTable{ .lay = absoluteLay, .content = null };
    pub const mono = VTable{ .lay = monoLay, .content = null };
    pub const leaf = VTable{ .lay = leafLay, .content = null };

    /// Per-axis auto-sizing mode.
    pub const AxisSizing = enum {
        /// Use the area given by the parent, no matter what.
        fixed,
        /// Size along this axis from the children's content.
        content,
    };

    /// The sizing of a layout along its main and cross axis. The main axis is
    /// the flow direction (row -> horizontal, column -> vertical); the cross
    /// axis is the other one.
    pub const Flexibility = struct {
        main: AxisSizing = .fixed,
        cross: AxisSizing = .fixed,
    };

    /// What happens when fixed content overflows the container.
    pub const Overflow = enum {
        /// Let children overflow and be clipped by the parent. The window clips
        /// each element to its own box before drawing, so overflow never lands
        /// on a sibling.
        clip,
        /// Shrink the flexible children to fit. Children shrink evenly toward
        /// their `min_size` floor, and only when the box is completely full
        /// (every flexible child is already at its floor) do they keep
        /// shrinking below it. The window's per-element clip keeps anything
        /// the box still cannot hold from bleeding onto a sibling.
        squeeze,
    };

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

    /// Configuration for a CSS-like flex layout. This is the only knob the
    /// application turns; the layout reads everything else from its own state.
    pub const FlexConfig = struct {
        direction: FlexDirection = .row,
        justify: JustifyContent = .flex_start,
        align_items: AlignItems = .stretch,
        gap: u32 = 0,
        /// Wrap to a new line along the cross axis when the main axis is full.
        wrap: bool = false,
        sizing: Flexibility = .{ .main = .fixed, .cross = .fixed },
        /// What to do when fixed content does not fit the container. Boxes
        /// squeeze their flexible children to fit by default.
        overflow: Overflow = .squeeze,
    };

    /// Configuration for a grid layout. Children are placed row by row into
    /// equal cells.
    pub const GridConfig = struct {
        columns: u16 = 1,
        gap: u32 = 0,
        sizing: Flexibility = .{ .main = .fixed, .cross = .fixed },
        overflow: Overflow = .clip,
    };

    /// A request from an element to get some space from the parent. The element
    /// is null until `addElement` is called with this request's id.
    pub const Request = struct {
        /// The requesting element, a pointer into the widget's element pool.
        /// `addElement` fills this in.
        element: ?*lu.Element = null,
        /// The base size the layout tries to give the element; also the floor
        /// when there is room.
        min_size: lu.Rect,
        /// The largest size this element may be given. Null means the whole
        /// container is eligible.
        max_size: ?lu.Rect = null,
        /// An exact size that ignores `min_size`/`max_size` entirely.
        size: ?lu.Rect = null,
        pos: ?lu.Pos = null,
        margin: ?lu.Sides = null,
        /// CSS `flex-grow`: how extra main-axis space is split between
        /// flexible children. Exact-size requests never grow.
        grow: u32 = 0,
        /// CSS `flex-basis`. Overrides the main-axis base size when set.
        basis: ?u32 = null,
        /// CSS `align-self`; overrides the container's cross alignment.
        align_self: ?AlignItems = null,
        /// Called once per `lay` for this child, with the space the layout is
        /// about to give it. It returns the child's required footprint; the
        /// layout honors it: on the main axis the child keeps the returned size
        /// and the siblings after it are pushed down the main axis to make room
        /// (offloading the oversized request), while on the cross axis the child
        /// may stay at the reserved box and overflow is simply tolerated. Return
        /// null to take the space as laid out.
        overflow: ?*const fn (*lu.Element, lu.Rect) ?lu.Rect = null,
    };

    /// Set `widget.current` to this layout. The widget is read from the element
    /// this layout is wired to (its `widget` pointer), so no argument is
    /// needed. Widgets whose builders are called afterwards register their
    /// children here, until `end` is called.
    pub fn start(self: *Layout) void {
        const el = self.element orelse {
            @panic("layout.start() called before the layout was wired to an element (set layout.element or add the element to a parent first)");
        };
        const w = el.ctx orelse {
            @panic("layout.start(): the element has no context pointer");
        };
        w.current = self;
    }

    /// Stop being the current parent. Restores the element's widget's current
    /// parent to this layout's parent (null for the root), leaving the layout
    /// exactly as the build phase left it. The window lays everything out later
    /// with `lay`.
    pub fn end(self: *Layout) void {
        const el = self.element orelse return;
        if (el.ctx) |w| w.current = self.parent;
    }

    /// Discards the saved requests from the previous build phase so the layout
    /// starts from an empty request list. Widgets create their containers fresh
    /// every frame (so `rindex` starts at zero anyway); this is for layouts that
    /// live across frames and re-register their children each build.
    pub fn reset(self: *Layout) void {
        self.requests.clearRetainingCapacity();
        self.rindex = 0;
    }

    /// The allocator this layout grows its arrays from: the one `Context`
    /// installed (see `allocator`), otherwise the element's context allocator,
    /// otherwise the page allocator.
    pub fn allocatorOf(self: *const Layout) std.mem.Allocator {
        if (self.allocator) |a| return a;
        if (self.element) |el| {
            if (el.ctx) |c| return c.allocator;
        }
        return std.heap.page_allocator;
    }

    /// Request space from the layout, returning the id assigned to this
    /// request. Call `addElement(id, element)` to attach the requesting
    /// element; the parent reads `getSize` style information from the element
    /// after `lay`.
    pub fn request(self: *Layout, req: Request) u32 {
        const id: u32 = @intCast(self.requests.items.len);
        const alloc = self.allocatorOf();
        self.requests.append(alloc, req) catch {
            if (builtin.mode == .Debug) {
                @panic("layout request allocation failed: raise -Dfba-bytes (or use Context.setAlloc)");
            } else {
                std.log.warn("layout request allocation failed; increase -Dfba-bytes", .{});
            }
            return id;
        };
        self.rindex = self.requests.items.len;
        return id;
    }

    /// Assign the element that made request `id` to its request slot, and wire
    /// the element's layout back to the element pointed at so `start`/`end` can
    /// reach the element (and its widget) and `lay` can read its size. `element`
    /// is a pointer into the widget's element pool; the caller keeps it alive.
    pub fn addElement(self: *Layout, id: u32, element: *lu.Element) void {
        const idx: usize = id;
        if (idx >= self.requests.items.len) {
            @panic("layout.addElement called with an invalid request id; request() assigns one first");
        }
        self.requests.items[idx].element = element;
        if (self.requests.items[idx].element.?.layout) |*l| l.element = self.requests.items[idx].element;
    }

    /// Lay out this layout's children, top-down. The window sets the root
    /// element's size and position, wires `element` to it, then calls the root
    /// layout's `lay`; each layout sizes its own children, writes their final
    /// `.size`/`.pos` onto the child elements, and lays out the children that
    /// are containers themselves. When the element carries a stable id and its
    /// layout was computed into the same box on an earlier frame, the cached
    /// child results are replayed instead of re-running the layout math. Returns
    /// the laid-out children.
    pub fn lay(self: *Layout) []*lu.Element {
        const el = self.element orelse return self.children.items[0..0];
        const pad = self.padding;
        self.container = .{
            .w = el.size.w -| (pad.left + pad.right),
            .h = el.size.h -| (pad.top + pad.bottom),
        };
        self.children.clearRetainingCapacity();
        self.cindex = 0;
        self.gather();
        for (0..self.cindex) |i| {
            const child = self.children.items[i];
            child.pos.x += el.pos.x + pad.left;
            child.pos.y += el.pos.y + pad.top;
            if (child.layout) |*cl| {
                cl.element = child;
                _ = cl.lay();
            }
        }
        return self.children.items[0..self.cindex];
    }

    /// Computes `layout.children` and each child's relative `.pos`/`.size`,
    /// either from the cached results of a previous `lay` (when the element has
    /// a stable id, the container is the same size and the children still have
    /// the same ids) or by running `vtable.lay`. Writes and reads the cache
    /// through `element.ctx.layout_cache`; elements with `id == 0` (containers
    /// rebuilt as raw structs) never consult it. Child positions are relative to
    /// the container's content origin; `lay` adds the container's own position
    /// afterwards, so cached and freshly computed children behave identically.
    fn gather(self: *Layout) void {
        const el = self.element orelse return;
        // Leaf layouts have no children to cache: a leaf's `store` would write
        // an `n == 0` entry under its key, and since leaves reuse their parent
        // element's id (text glyphs share the owning element's cache key), that
        // empty entry would clobber the parent's cached child results and the
        // parent would silently replay an empty layout. Leaves always lay.
        if (self.vtable == &leaf or el.id == 0) {
            self.vtable.lay(self);
            return;
        }
        if (el.ctx) |ctx| {
            if (ctx.layout_cache) |sink| {
                const key = lu.Context.cacheKey(el.id, el.id_extra);
                if (sink.consult(sink.ptr, key)) |entry| {
                    if (entry.container.w == self.container.w and entry.container.h == self.container.h and self.replay(entry))
                        return;
                }
                self.vtable.lay(self);
                sink.store(sink.ptr, key, self);
                return;
            }
        }
        self.vtable.lay(self);
    }

    /// Replays a cached layout onto the freshly rebuilt children: each child's
    /// cached relative position/size is written onto the matching current
    /// request element, in request order. Returns false when the cached tree
    /// does not match the current one (a different number of children, or a
    /// child whose stable id moved), which forces a real `lay`.
    fn replay(self: *Layout, entry: *const lu.Context.LayoutEntry) bool {
        if (entry.n > self.rindex) return false;
        self.children.clearRetainingCapacity();
        var cindex: usize = 0;
        var idx: usize = 0;
        for (0..self.rindex) |i| {
            const req = &self.requests.items[i];
            const ce = req.element orelse continue;
            if (idx >= entry.n) return false;
            const kid = entry.kids[idx];
            if (ce.id != kid.id or ce.id_extra != kid.extra) return false;
            ce.pos = kid.pos;
            ce.size = kid.size;
            self.children.append(self.allocatorOf(), ce) catch {
                if (builtin.mode == .Debug) {
                    @panic("layout children allocation failed: raise -Dfba-bytes (or use Context.setAlloc)");
                }
                std.log.warn("layout children allocation failed; increase -Dfba-bytes", .{});
                return false;
            };
            cindex += 1;
            idx += 1;
        }
        if (idx != entry.n) return false;
        self.cindex = cindex;
        return true;
    }

    /// The typed config for a flex layout, or null when this is not a flex
    /// layout or has no config.
    fn flexCfg(self: *const Layout) ?*const FlexConfig {
        if (self.vtable != &flex) return null;
        return @ptrCast(@alignCast(self.data orelse return null));
    }

    /// The typed config for a grid layout, or null when this is not a grid
    /// layout or has no config.
    fn gridCfg(self: *const Layout) ?*const GridConfig {
        if (self.vtable != &grid) return null;
        return @ptrCast(@alignCast(self.data orelse return null));
    }

    /// Which of a layout's world axes are sized by content. `content` vtable
    /// functions report a world size; parents apply only the content axes.
    fn contentAxes(self: *const Layout) struct { w: bool, h: bool } {
        if (self.vtable == &flex) {
            const cfg = flexCfg(self) orelse return .{ .w = false, .h = false };
            const row = cfg.direction == .row;
            return .{
                .w = if (row) cfg.sizing.main == .content else cfg.sizing.cross == .content,
                .h = if (row) cfg.sizing.cross == .content else cfg.sizing.main == .content,
            };
        }
        if (self.vtable == &grid) {
            const cfg = gridCfg(self) orelse return .{ .w = false, .h = false };
            return .{ .w = cfg.sizing.main == .content, .h = cfg.sizing.cross == .content };
        }
        // Any other layout that reports a content size (text, ...) is content
        // on both axes: it can wrap/grow along both given what it is given.
        if (self.vtable.content != null) return .{ .w = true, .h = true };
        return .{ .w = false, .h = false };
    }
};

// ---------------------------------------------------------------------------
// Kinds
// ---------------------------------------------------------------------------

/// A layout with no children; does nothing. Leaf elements (text, images, boxes)
/// use this: their size is set by their parent and the window draws them.
fn leafLay(_: *Layout) void {}

/// Places each child at exactly its requested position and size.
fn absoluteLay(layout: *Layout) void {
    layout.children.clearRetainingCapacity();
    var cindex: usize = 0;
    for (0..layout.rindex) |id| {
        const req = &layout.requests.items[id];
        const el = req.element orelse continue;
        layout.children.append(layout.allocatorOf(), el) catch {
            if (builtin.mode == .Debug) @panic("layout children allocation failed: raise -Dfba-bytes (or use Context.setAlloc)");
            std.log.warn("layout children allocation failed; increase -Dfba-bytes", .{});
            return;
        };
        el.pos = req.pos orelse .{ .x = 0, .y = 0 };
        el.size = req.size orelse req.min_size;
        cindex += 1;
    }
    layout.cindex = cindex;
}

/// Centers a single child in the container. Used by text widgets to center
/// their label; the child's own request carries its size.
fn monoLay(layout: *Layout) void {
    layout.children.clearRetainingCapacity();
    if (layout.rindex == 0) return;
    const req = &layout.requests.items[0];
    const el = req.element orelse return;
    const child = req.size orelse req.min_size;
    layout.children.append(layout.allocatorOf(), el) catch {
        if (builtin.mode == .Debug) @panic("layout children allocation failed: raise -Dfba-bytes (or use Context.setAlloc)");
        std.log.warn("layout children allocation failed; increase -Dfba-bytes", .{});
        return;
    };
    el.pos = .{
        .x = @divTrunc(layout.container.w -| child.w, 2),
        .y = @divTrunc(layout.container.h -| child.h, 2),
    };
    el.size = child;
    layout.cindex = 1;
}

// ---------------------------------------------------------------------------
// Flexbox
// ---------------------------------------------------------------------------

const Line = struct {
    start: usize,
    len: usize,
};

/// Packed, in-request-order child data shared by laying out and sizing.
const Packed = struct {
    n: usize,
    basis: [Max]u32,
    minm: [Max]u32,
    minc: [Max]u32,
    maxm: [Max]u32,
    grow: [Max]u32,
    ownc: [Max]u32,
    /// True when the request carries an exact `size` that ignores min/max.
    exact: [Max]bool,
    align_items: [Max]Layout.AlignItems,
    order: [Max]usize,
    overflow: [Max]?*const fn (*lu.Element, lu.Rect) ?lu.Rect,
    /// True when this child's main axis is content-sized: its `minm` is its
    /// content size and it must never shrink below it. Parents of content
    /// containers (a wrap toolbar, a content grid) use this so a too-small
    /// parent cannot crush a container below what it holds, which would make
    /// the container's children leak out over the following siblings.
    rigid: [Max]bool,
    el: [Max]*lu.Element,
};

/// Gather a flex container's children. Content-sized children report their
/// preferred size through their layout's `content` vtable function, which the
/// parent applies to the axes it controls.
fn packFlex(layout: *Layout, cfg: *const Layout.FlexConfig, row: bool, pk: *Packed) void {
    const n_max = @min(layout.rindex, Max);
    pk.n = 0;
    for (0..n_max) |i| {
        const req = &layout.requests.items[i];
        if (req.element == null) continue;
        const own = req.size orelse req.min_size;
        const exact = req.size != null;
        var b: u32 = req.basis orelse (if (row) own.w else own.h);
        var oc: u32 = if (row) own.h else own.w;
        var sizes_cross: bool = false;
        pk.rigid[pk.n] = false;
        if (req.element.?.layout) |*cl| {
            if (cl.vtable.content) |content_fn| {
                if (content_fn(cl, layout.container)) |p| {
                    const axes = Layout.contentAxes(cl);
                    if (axes.w) {
                        if (row) b = p.w else oc = p.w;
                    }
                    if (axes.h) {
                        if (row) oc = p.h else b = p.h;
                    }
                    sizes_cross = (axes.w and !row) or (axes.h and row);
                    // A content-sized main axis is rigid: the parent may lay it
                    // out at its content size but never crush it below that.
                    if ((axes.w and row) or (axes.h and !row)) {
                        pk.rigid[pk.n] = true;
                    }
                }
            }
        }
        const n = pk.n;
        pk.basis[n] = b;
        pk.minm[n] = if (row) req.min_size.w else req.min_size.h;
        if (pk.rigid[n]) {
            pk.minm[n] = @max(pk.minm[n], b);
        }
        // A content-sized axis reports the size that fits the box it is about
        // to be given; a wrapping child may therefore shrink its cross axis to
        // whatever width the parent offers, so its request min must not hold it
        // rigid on that axis.
        pk.minc[n] = if (sizes_cross and !exact)
            oc
        else if (row) req.min_size.h else req.min_size.w;
        // Ceilings clamp to the container when a max_size isn't given.
        pk.maxm[n] = if (req.max_size) |mx|
            if (row) mx.w else mx.h
        else if (row) layout.container.w else layout.container.h;
        pk.grow[n] = if (exact) 0 else req.grow;
        pk.ownc[n] = oc;
        pk.exact[n] = exact;
        pk.align_items[n] = req.align_self orelse cfg.align_items;
        pk.order[n] = n;
        pk.overflow[n] = req.overflow;
        pk.el[n] = req.element.?;
        pk.n += 1;
    }
}

/// Build the wrapped (or single) lines of a flex container. When `wrap` is set
/// and the main axis is fixed, lines break once `main_limit` is reached.
fn buildLines(
    cfg: *const Layout.FlexConfig,
    pk: *const Packed,
    main_content: bool,
    main_limit: u32,
    lines: *[Max]Line,
) usize {
    const n = pk.n;
    var nl: usize = 0;
    if (cfg.wrap and !main_content and main_limit > 0) {
        var lstart: usize = 0;
        var lmain: u64 = 0;
        for (0..n) |k| {
            const g = pk.order[k];
            const b: u64 = pk.basis[g];
            if (k > lstart and lmain + cfg.gap + b > main_limit and b <= main_limit) {
                lines[nl] = .{ .start = lstart, .len = k - lstart };
                nl += 1;
                lstart = k;
                lmain = 0;
            }
            lmain += b;
        }
        lines[nl] = .{ .start = lstart, .len = n - lstart };
        nl += 1;
    } else {
        lines[0] = .{ .start = 0, .len = n };
        nl = 1;
    }
    return nl;
}

/// The world size a flex layout wants along its content axes given the box
/// `avail` it is about to be given. Content axes report a size; fixed axes
/// report 0.
fn flexContent(layout: *Layout, avail: lu.Rect) ?lu.Rect {
    const cfg = Layout.flexCfg(layout) orelse return null;
    const row = cfg.direction == .row;
    const axes = Layout.contentAxes(layout);
    if (!axes.w and !axes.h) return null;

    var pk: Packed = undefined;
    packFlex(layout, cfg, row, &pk);
    const n = pk.n;
    if (n == 0) return null;

    var w_total: u64 = 0;
    var h_total: u64 = 0;
    for (0..n) |k| {
        const g = pk.order[k];
        if (row) {
            w_total += pk.basis[g];
            h_total = @max(h_total, pk.ownc[g]);
        } else {
            h_total += pk.basis[g];
            w_total = @max(w_total, pk.ownc[g]);
        }
    }
    if (n > 1) {
        if (row) w_total += cfg.gap * (n - 1) else h_total += cfg.gap * (n - 1);
    }

    // Wrapped cross size (used when the cross axis is content and wrap is set);
    // the wrap point depends on the main-axis space `avail` provides.
    var used_cross: u64 = 0;
    if (cfg.wrap and (if (row) axes.h else axes.w)) {
        const main_avail: u32 = if (row) avail.w else avail.h;
        var lines: [Max]Line = undefined;
        const nl = buildLines(cfg, &pk, cfg.sizing.main == .content, main_avail, &lines);
        for (0..nl) |li| {
            const len = lines[li].len;
            var lc: u32 = 0;
            for (0..len) |j| {
                const g = pk.order[lines[li].start + j];
                lc = @max(lc, @max(pk.ownc[g], pk.minc[g]));
            }
            if (li > 0) used_cross += cfg.gap;
            used_cross += lc;
        }
    }

    var p = lu.Rect{ .w = 0, .h = 0 };
    if (row) {
        if (axes.w) p.w = @intCast(w_total);
        if (axes.h) p.h = @intCast(if (cfg.wrap) used_cross else h_total);
    } else {
        if (axes.w) p.w = @intCast(if (cfg.wrap) used_cross else w_total);
        if (axes.h) p.h = @intCast(h_total);
    }
    return p;
}

/// Shrink the flexible children of one flex line so it fits its box.
///
/// Children start at their basis. Each pass distributes the still-unpaid
/// deficit evenly over the flexible children, but no child may shrink below
/// its `min_size` floor; a child whose even share would cross its floor gives
/// up only the surplus it has to give and the leftover is redistributed. When
/// every flexible child is already at its floor and a deficit remains, the box
/// is completely full, so the children continue shrinking below their floors
/// (toward zero) until the line fits. Exact-size children never change.
fn shrinkOverflow(
    pk: *const Packed,
    line: []const usize,
    deficit: u64,
    main: *[Max]u32,
) void {
    for (line) |g| main[g] = pk.basis[g];

    var remaining: u64 = deficit;
    while (remaining > 0 and line.len > 0) {
        // How many flexible children still have room down to their floor.
        var within_floor: usize = 0;
        for (line) |g| {
            if (!pk.exact[g] and main[g] > pk.minm[g]) within_floor += 1;
        }
        if (within_floor == 0) {
            // The box is completely full: everyone flexible is at its floor and
            // it still does not fit, so keep shrinking below the floor, spread
            // evenly, until the line fits or they hit zero.
            var left: u64 = remaining;
            while (left > 0) {
                var flexible: usize = 0;
                for (line) |g| {
                    // Rigid children (content-sized containers) never shrink
                    // below their content; only fixed content does.
                    if (!pk.exact[g] and !pk.rigid[g] and main[g] > 0) flexible += 1;
                }
                if (flexible == 0) break;
                const share: u64 = left / flexible;
                var given: u64 = 0;
                for (line) |g| {
                    if (pk.exact[g] or pk.rigid[g] or main[g] == 0) continue;
                    const take = @min(share, main[g]);
                    main[g] -= @intCast(take);
                    given += take;
                }
                if (given == 0) break;
                left -= given;
            }
            break;
        }

        const share: u64 = remaining / within_floor;
        var given: u64 = 0;
        for (line) |g| {
            if (pk.exact[g] or main[g] <= pk.minm[g]) continue;
            const take = @min(share, main[g] - pk.minm[g]);
            main[g] -= @intCast(take);
            given += take;
        }
        if (given == 0) break;
        // Passing children that reached their floor absorb less or nothing, so
        // only whatever was actually taken comes off the deficit.
        remaining = if (remaining > given) remaining - given else 0;
    }
}

/// Fills `layout.children` with the laid-out children of a flex container.
fn flexLay(layout: *Layout) void {
    const cfg = Layout.flexCfg(layout) orelse return;
    const row = cfg.direction == .row;
    var pk: Packed = undefined;
    packFlex(layout, cfg, row, &pk);
    const n = pk.n;
    if (n == 0) {
        layout.children.clearRetainingCapacity();
        layout.cindex = 0;
        return;
    }

    const msize = if (row) layout.container.w else layout.container.h;
    const csize = if (row) layout.container.h else layout.container.w;
    const main_content = cfg.sizing.main == .content;
    const cross_content = cfg.sizing.cross == .content;

    var lines: [Max]Line = undefined;
    const nl = buildLines(cfg, &pk, main_content, msize, &lines);

    var main: [Max]u32 = undefined;
    var cross: [Max]u32 = undefined;
    var crossstart: [Max]u32 = undefined;
    var line_cross: [Max]u32 = undefined;

    var used_cross: u64 = 0;
    for (0..nl) |li| {
        const len = lines[li].len;
        var line_main: u64 = 0;
        for (0..len) |j| line_main += pk.basis[pk.order[lines[li].start + j]];
        if (len > 1) line_main += cfg.gap * (len - 1);

        const free: i64 = @as(i64, @intCast(msize)) - @as(i64, @intCast(line_main));
        if (main_content) {
            // Content-sized: every child gets its basis; nothing grows.
            for (0..len) |j| main[pk.order[lines[li].start + j]] = pk.basis[pk.order[lines[li].start + j]];
        } else if (free >= 0) {
            // There is room: keep every element at its base (min) size, then
            // hand the leftover to `grow` children, each capped at its max.
            for (0..len) |j| main[pk.order[lines[li].start + j]] = pk.basis[pk.order[lines[li].start + j]];
            var used: i64 = 0;
            while (used < free) {
                var total_w: u64 = 0;
                for (0..len) |j| {
                    const g = pk.order[lines[li].start + j];
                    if (!pk.exact[g] and pk.grow[g] > 0 and main[g] < pk.maxm[g]) total_w += pk.grow[g];
                }
                if (total_w == 0) break;
                const remaining = free - used;
                var added: i64 = 0;
                for (0..len) |j| {
                    const g = pk.order[lines[li].start + j];
                    if (!pk.exact[g] and pk.grow[g] > 0 and main[g] < pk.maxm[g]) {
                        const add = @min(
                            @divTrunc(remaining * @as(i64, pk.grow[g]), @as(i64, @intCast(total_w))),
                            @as(i64, @intCast(pk.maxm[g] - main[g])),
                        );
                        main[g] += @intCast(add);
                        added += add;
                    }
                }
                if (added == 0) {
                    // Integer rounding left a pixel: give it to the first child
                    // still below its max and stop.
                    for (0..len) |j| {
                        const g = pk.order[lines[li].start + j];
                        if (!pk.exact[g] and pk.grow[g] > 0 and main[g] < pk.maxm[g]) {
                            main[g] += 1;
                            break;
                        }
                    }
                    break;
                }
                used += added;
            }
            for (0..len) |j| {
                const g = pk.order[lines[li].start + j];
                if (!pk.exact[g]) main[g] = std.math.clamp(main[g], pk.minm[g], pk.maxm[g]);
            }
        } else if (cfg.overflow == .squeeze) {
            // Too little room: shrink the flexible children to fit. Children
            // first lose size evenly down to their `min_size` floor; an even
            // share that would push one child past its floor only takes that
            // child's surplus and spreads the leftover over the rest. Only when
            // every flexible child is already at its floor and the line still
            // does not fit (the box is completely full) do they keep shrinking
            // below the floor. Exact-size children never change.
            const deficit: u64 = @intCast(@as(i64, @intCast(line_main)) - @as(i64, @intCast(msize)));
            shrinkOverflow(&pk, pk.order[lines[li].start .. lines[li].start + len], deficit, &main);
        } else {
            // Not enough room and not squeezing: keep each element at its base
            // size so it overflows; the parent clips the excess.
            for (0..len) |j| main[pk.order[lines[li].start + j]] = pk.basis[pk.order[lines[li].start + j]];
        }

        var lc: u32 = 0;
        for (0..len) |j| {
            const g = pk.order[lines[li].start + j];
            lc = @max(lc, @max(pk.ownc[g], pk.minc[g]));
        }
        line_cross[li] = if (cross_content or cfg.wrap) lc else csize;

        for (0..len) |j| {
            const g = pk.order[lines[li].start + j];
            const alc = line_cross[li];
            switch (pk.align_items[g]) {
                .stretch => {
                    cross[g] = @max(alc, pk.minc[g]);
                    crossstart[g] = 0;
                },
                .flex_start => {
                    cross[g] = @max(pk.ownc[g], pk.minc[g]);
                    crossstart[g] = 0;
                },
                .flex_end => {
                    cross[g] = @max(pk.ownc[g], pk.minc[g]);
                    crossstart[g] = alc -| cross[g];
                },
                .center => {
                    cross[g] = @max(pk.ownc[g], pk.minc[g]);
                    crossstart[g] = @divTrunc(alc -| cross[g], 2);
                },
            }
        }
        if (li > 0) used_cross += cfg.gap;
        used_cross += line_cross[li];
    }

    layout.children.clearRetainingCapacity();
    layout.cindex = 0;
    var cy: i64 = 0;
    for (0..nl) |li| {
        const len = lines[li].len;
        var cursor: i64 = 0;
        var space: u32 = cfg.gap;
        var line_used: u64 = 0;
        for (0..len) |j| line_used += main[pk.order[lines[li].start + j]];
        if (len > 1) line_used += cfg.gap * (len - 1);
        const free_j: i64 = @as(i64, @intCast(msize)) - @as(i64, @intCast(line_used));
        switch (cfg.justify) {
            .flex_start => cursor = 0,
            .flex_end => cursor = free_j,
            .center => cursor = @divTrunc(free_j, 2),
            .space_between => {
                space = if (len > 1) cfg.gap + @as(u32, @intCast(@divTrunc(@max(0, free_j), @as(i64, @intCast(len - 1))))) else 0;
                cursor = if (len > 1) 0 else @divTrunc(free_j, 2);
            },
            .space_around => {
                const single: u64 = if (len == 0) 0 else @as(u64, @intCast(@max(0, free_j))) / @as(u64, len);
                cursor = @intCast(@divTrunc(@as(i64, @intCast(single)), 2));
                space = cfg.gap + @as(u32, @intCast(single));
            },
            .space_evenly => {
                const single: u64 = if (len == 0) 0 else @as(u64, @intCast(@max(0, free_j))) / @as(u64, len + 1);
                cursor = @intCast(single);
                space = cfg.gap + @as(u32, @intCast(single));
            },
        }
        for (0..len) |j| {
            const g = pk.order[lines[li].start + j];
            var area: lu.Area = undefined;
            // The space this element is reserved on the main axis. Its
            // `overflow` fn may claim a bigger main size: the element keeps
            // that size and the siblings after it are pushed along the main
            // axis to make room, instead of the element spilling onto them.
            var use_main: u32 = main[g];
            if (pk.overflow[g]) |ofn| {
                if (ofn(pk.el[g], .{ .w = main[g], .h = cross[g] })) |r| {
                    const claimed: u32 = if (row) r.w else r.h;
                    use_main = @max(use_main, claimed);
                }
            }
            if (row) {
                area = .{
                    .pos = .{ .x = @intCast(cursor), .y = @intCast(cy + @as(i64, crossstart[g])) },
                    .size = .{ .w = use_main, .h = cross[g] },
                };
            } else {
                area = .{
                    .pos = .{ .x = @intCast(cy + @as(i64, crossstart[g])), .y = @intCast(cursor) },
                    .size = .{ .w = cross[g], .h = use_main },
                };
            }
            cursor += @as(i64, use_main) + @as(i64, space);
            const ce = pk.el[g];
            layout.children.append(layout.allocatorOf(), ce) catch {
                if (builtin.mode == .Debug) @panic("layout children allocation failed: raise -Dfba-bytes (or use Context.setAlloc)");
                std.log.warn("layout children allocation failed; increase -Dfba-bytes", .{});
                layout.cindex = layout.children.items.len;
                return;
            };
            ce.pos = area.pos;
            ce.size = area.size;
        }
        if (li + 1 < nl) cy += @as(i64, line_cross[li]) + cfg.gap;
    }
    layout.cindex = layout.children.items.len;
}

// ---------------------------------------------------------------------------
// Grid
// ---------------------------------------------------------------------------

/// The largest preferred size any child would take, plus the count.
fn gridExtents(layout: *Layout, cfg: *const Layout.GridConfig, max_w: *u32, max_h: *u32, count: *usize) void {
    _ = cfg;
    var mw: u32 = 0;
    var mh: u32 = 0;
    var n: usize = 0;
    for (0..layout.rindex) |i| {
        const req = &layout.requests.items[i];
        if (req.element == null) continue;
        const child = req.size orelse req.min_size;
        var w = child.w;
        var h = child.h;
        if (req.element.?.layout) |*cl| {
            if (cl.vtable.content) |content_fn| {
                if (content_fn(cl, layout.container)) |p| {
                    w = p.w;
                    h = p.h;
                }
            }
        }
        mw = @max(mw, w);
        mh = @max(mh, h);
        n += 1;
    }
    max_w.* = mw;
    max_h.* = mh;
    count.* = n;
}

/// The world size a grid layout wants along its content axes.
fn gridContent(layout: *Layout, _: lu.Rect) ?lu.Rect {
    const cfg = Layout.gridCfg(layout) orelse return null;
    const axes = Layout.contentAxes(layout);
    if (!axes.w and !axes.h) return null;

    var mw: u32 = 0;
    var mh: u32 = 0;
    var n: usize = 0;
    gridExtents(layout, cfg, &mw, &mh, &n);
    if (n == 0) return null;
    const cols: usize = @max(1, cfg.columns);
    const rows: usize = @divTrunc(n, cols) + @intFromBool(@rem(n, cols) != 0);

    var p = lu.Rect{ .w = 0, .h = 0 };
    if (axes.w) p.w = @intCast(mw * cols + cfg.gap * (cols - 1));
    if (axes.h) p.h = @intCast(mh * rows + cfg.gap * (rows - 1));
    return p;
}

/// Fills `layout.children` with the laid-out children of a grid container.
fn gridLay(layout: *Layout) void {
    const cfg = Layout.gridCfg(layout) orelse return;
    var n: usize = 0;
    for (0..layout.rindex) |i| {
        if (layout.requests.items[i].element != null) n += 1;
    }
    if (n == 0) {
        layout.children.clearRetainingCapacity();
        layout.cindex = 0;
        return;
    }
    const cols: usize = @max(1, cfg.columns);
    const rows: usize = @divTrunc(n, cols) + @intFromBool(@rem(n, cols) != 0);

    var col_w: u32 = @divTrunc(layout.container.w, @as(u32, @intCast(cols)));
    var row_h: u32 = @divTrunc(layout.container.h, @as(u32, @intCast(@max(1, rows))));

    if (cfg.sizing.main == .content or cfg.sizing.cross == .content) {
        var mw: u32 = 0;
        var mh: u32 = 0;
        var count: usize = 0;
        gridExtents(layout, cfg, &mw, &mh, &count);
        if (count > 0) {
            if (cfg.sizing.main == .content) col_w = mw;
            if (cfg.sizing.cross == .content) row_h = mh;
        }
    }

    layout.children.clearRetainingCapacity();
    var i: usize = 0;
    for (0..layout.rindex) |idx| {
        if (layout.requests.items[idx].element == null) continue;
        const col = i % cols;
        const r = i / cols;
        var area = lu.Area{
            .pos = .{
                .x = @intCast(col * (col_w + cfg.gap)),
                .y = @intCast(r * (row_h + cfg.gap)),
            },
            .size = .{ .w = col_w, .h = row_h },
        };
        const min = layout.requests.items[idx].min_size;
        area.size.w = @max(area.size.w, min.w);
        area.size.h = @max(area.size.h, min.h);
        if (layout.requests.items[idx].max_size) |mx| {
            area.size.w = @min(area.size.w, mx.w);
            area.size.h = @min(area.size.h, mx.h);
        }
        const ce = layout.requests.items[idx].element.?;
        layout.children.append(layout.allocatorOf(), ce) catch {
            if (builtin.mode == .Debug) @panic("layout children allocation failed: raise -Dfba-bytes (or use Context.setAlloc)");
            std.log.warn("layout children allocation failed; increase -Dfba-bytes", .{});
            layout.cindex = layout.children.items.len;
            return;
        };
        ce.pos = area.pos;
        ce.size = area.size;
        i += 1;
    }
    layout.cindex = layout.children.items.len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// A leaf layout embedded by value into every test leaf. Sharing a copy keeps
// leaves outside of the (container) recursion so they are never re-measured.
const leaf_layout: Layout = .{
    .vtable = &Layout.leaf,
    .parent = null,
};

// Test elements live in a static pool, mirroring the widget pool: layouts hold
// element *pointers*, so the elements they point at must outlive the layout.
var test_elems: [4096]lu.Element = undefined;
var next_elem: usize = 0;

fn mkElement(w: u32, h: u32) *lu.Element {
    const e = &test_elems[next_elem];
    next_elem += 1;
    e.* = .{
        .size = .{ .w = w, .h = h },
        .pos = .{ .x = 0, .y = 0 },
        .style = .{ .background = lu.Background.solid(.{ .r = 0, .g = 0, .b = 0, .a = 255 }) },
        .layout = leaf_layout,
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
    return e;
}

fn mkLayout() Layout {
    return .{
        .vtable = &Layout.flex,
        .parent = null,
    };
}

/// Point `layout` at a caller-owned root element so `lay` reads its size/pos.
fn mkRoot(layout: *Layout, root: *lu.Element) void {
    layout.element = root;
}

test "flex row lays children in order with gap" {
    var layout = mkLayout();
    var cfg = Layout.FlexConfig{ .direction = .row, .gap = 4 };
    layout.data = &cfg;
    const root = mkElement(100, 40);
    mkRoot(&layout, root);

    layout.addElement(layout.request(.{ .min_size = .{ .w = 10, .h = 20 } }), mkElement(10, 20));
    layout.addElement(layout.request(.{ .min_size = .{ .w = 30, .h = 20 } }), mkElement(30, 20));

    const children = layout.lay();
    try std.testing.expectEqual(@as(usize, 2), children.len);
    try std.testing.expectEqual(@as(u32, 0), children[0].pos.x);
    try std.testing.expectEqual(@as(u32, 10), children[0].size.w);
    try std.testing.expectEqual(@as(u32, 14), children[1].pos.x);
    try std.testing.expectEqual(@as(u32, 30), children[1].size.w);
    // stretch cross axis
    try std.testing.expectEqual(@as(u32, 40), children[0].size.h);
}

test "flex row grow fills free space" {
    var layout = mkLayout();
    var cfg = Layout.FlexConfig{ .direction = .row };
    layout.data = &cfg;
    const root = mkElement(100, 10);
    mkRoot(&layout, root);

    layout.addElement(layout.request(.{ .min_size = .{ .w = 0, .h = 10 }, .grow = 1 }), mkElement(0, 10));
    layout.addElement(layout.request(.{ .min_size = .{ .w = 0, .h = 10 }, .grow = 3 }), mkElement(0, 10));

    const children = layout.lay();
    try std.testing.expectEqual(@as(u32, 25), children[0].size.w);
    try std.testing.expectEqual(@as(u32, 75), children[1].size.w);
}

test "flex column justify flex_end" {
    var layout = mkLayout();
    var cfg = Layout.FlexConfig{ .direction = .column, .justify = .flex_end };
    layout.data = &cfg;
    const root = mkElement(20, 100);
    mkRoot(&layout, root);

    layout.addElement(layout.request(.{ .min_size = .{ .w = 10, .h = 10 } }), mkElement(10, 10));

    const children = layout.lay();
    try std.testing.expectEqual(@as(u32, 90), children[0].pos.y);
}

test "grid places children into cells" {
    var layout = mkLayout();
    layout.vtable = &Layout.grid;
    var cfg = Layout.GridConfig{ .columns = 2, .gap = 0 };
    layout.data = &cfg;
    const root = mkElement(100, 100);
    mkRoot(&layout, root);

    layout.addElement(layout.request(.{ .min_size = .{ .w = 5, .h = 5 } }), mkElement(5, 5));
    layout.addElement(layout.request(.{ .min_size = .{ .w = 5, .h = 5 } }), mkElement(5, 5));
    layout.addElement(layout.request(.{ .min_size = .{ .w = 5, .h = 5 } }), mkElement(5, 5));

    const children = layout.lay();
    try std.testing.expectEqual(@as(usize, 3), children.len);
    try std.testing.expectEqual(@as(u32, 0), children[0].pos.x);
    try std.testing.expectEqual(@as(u32, 50), children[1].pos.x);
    try std.testing.expectEqual(@as(u32, 50), children[2].pos.y);
}

test "flex wrap creates a new line" {
    var layout = mkLayout();
    var cfg = Layout.FlexConfig{ .direction = .row, .gap = 2, .wrap = true };
    layout.data = &cfg;
    const root = mkElement(90, 100);
    mkRoot(&layout, root);

    layout.addElement(layout.request(.{ .min_size = .{ .w = 40, .h = 20 } }), mkElement(40, 20));
    layout.addElement(layout.request(.{ .min_size = .{ .w = 40, .h = 20 } }), mkElement(40, 20));
    layout.addElement(layout.request(.{ .min_size = .{ .w = 40, .h = 20 } }), mkElement(40, 20));

    const children = layout.lay();
    // first line: 40 + 2 + 40 = 82 <= 90, third wraps
    try std.testing.expectEqual(@as(usize, 3), children.len);
    try std.testing.expectEqual(@as(u32, 0), children[2].pos.x);
    try std.testing.expectEqual(@as(u32, 22), children[2].pos.y);
}

test "wrapped lines are content-sized on the cross axis" {
    var layout = mkLayout();
    var cfg = Layout.FlexConfig{ .direction = .row, .gap = 2, .wrap = true };
    layout.data = &cfg;
    const root = mkElement(90, 100);
    mkRoot(&layout, root);

    layout.addElement(layout.request(.{ .min_size = .{ .w = 40, .h = 20 } }), mkElement(40, 20));
    layout.addElement(layout.request(.{ .min_size = .{ .w = 40, .h = 30 } }), mkElement(40, 30));
    layout.addElement(layout.request(.{ .min_size = .{ .w = 40, .h = 20 } }), mkElement(40, 20));

    const children = layout.lay();
    // first line cross is max(20,30)=30, so the wrapped item sits below it
    try std.testing.expectEqual(@as(u32, 20), children[2].size.h);
    try std.testing.expectEqual(@as(u32, 32), children[2].pos.y);
    // both items on the first line stretch to that line's height
    try std.testing.expectEqual(@as(u32, 30), children[1].size.h);
}

test "squeeze shrinks to the min floor, only going below when the box is full" {
    var layout = mkLayout();
    var cfg = Layout.FlexConfig{ .direction = .row, .overflow = .squeeze };
    layout.data = &cfg;
    const root = mkElement(14, 10);
    mkRoot(&layout, root);

    layout.addElement(layout.request(.{ .min_size = .{ .w = 10, .h = 10 } }), mkElement(10, 10));
    layout.addElement(layout.request(.{ .min_size = .{ .w = 10, .h = 10 } }), mkElement(10, 10));

    const children = layout.lay();
    // 20px of basis in a 14px container: the box is completely full (both are
    // already at their 10px floor), so each is squeezed below the floor by 3px.
    try std.testing.expectEqual(@as(u32, 7), children[0].size.w);
    try std.testing.expectEqual(@as(u32, 7), children[1].size.w);
}

test "squeeze stops at the min floor when the deficit fits within it" {
    var layout = mkLayout();
    var cfg = Layout.FlexConfig{ .direction = .row, .overflow = .squeeze };
    layout.data = &cfg;
    const root = mkElement(24, 10);
    mkRoot(&layout, root);

    layout.addElement(layout.request(.{ .min_size = .{ .w = 10, .h = 10 }, .basis = 20 }), mkElement(20, 10));
    layout.addElement(layout.request(.{ .min_size = .{ .w = 10, .h = 10 }, .basis = 20 }), mkElement(20, 10));

    const children = layout.lay();
    // 40px of basis in a 24px container: the 16px deficit fits inside the
    // 10px floor of each child, so the split is even and nothing hits below.
    try std.testing.expectEqual(@as(u32, 12), children[0].size.w);
    try std.testing.expectEqual(@as(u32, 12), children[1].size.w);
}

test "squeeze redistributes a floor-limited share over the other children" {
    var layout = mkLayout();
    var cfg = Layout.FlexConfig{ .direction = .row, .overflow = .squeeze };
    layout.data = &cfg;
    const root = mkElement(24, 10);
    mkRoot(&layout, root);

    layout.addElement(layout.request(.{ .min_size = .{ .w = 19, .h = 10 }, .basis = 20 }), mkElement(20, 10));
    layout.addElement(layout.request(.{ .min_size = .{ .w = 0, .h = 10 }, .basis = 20 }), mkElement(20, 10));

    const children = layout.lay();
    // Even split wants 8px off each, but the first can only give 1px before
    // its 19px floor; the leftover 7px comes off the second child.
    try std.testing.expectEqual(@as(u32, 19), children[0].size.w);
    try std.testing.expectEqual(@as(u32, 5), children[1].size.w);
}

test "squeeze is the default overflow for flex boxes" {
    var layout = mkLayout();
    var cfg = Layout.FlexConfig{ .direction = .row }; // overflow left at default
    layout.data = &cfg;
    const root = mkElement(14, 10);
    mkRoot(&layout, root);

    layout.addElement(layout.request(.{ .min_size = .{ .w = 10, .h = 10 } }), mkElement(10, 10));
    layout.addElement(layout.request(.{ .min_size = .{ .w = 10, .h = 10 } }), mkElement(10, 10));

    const children = layout.lay();
    try std.testing.expectEqual(@as(u32, 7), children[0].size.w);
    try std.testing.expectEqual(@as(u32, 7), children[1].size.w);
}

fn overflowFn(_: *lu.Element, _: lu.Rect) ?lu.Rect {
    return .{ .w = 10, .h = 40 };
}

test "overflow fn pushes the siblings down on the main axis" {
    var layout = mkLayout();
    var cfg = Layout.FlexConfig{ .direction = .column, .gap = 0 };
    layout.data = &cfg;
    const root = mkElement(100, 100);
    mkRoot(&layout, root);

    layout.addElement(layout.request(.{ .min_size = .{ .w = 20, .h = 20 }, .overflow = overflowFn }), mkElement(20, 20));
    layout.addElement(layout.request(.{ .min_size = .{ .w = 20, .h = 20 } }), mkElement(20, 20));

    const children = layout.lay();
    // Column main is height: the first child claims 40px, so the second child
    // is pushed down instead of overlapping the overflow area.
    try std.testing.expectEqual(@as(u32, 40), children[0].size.h);
    try std.testing.expectEqual(@as(u32, 40), children[1].pos.y);
}

fn overflowCrossFn(_: *lu.Element, _: lu.Rect) ?lu.Rect {
    return .{ .w = 10, .h = 30 };
}

test "overflow fn cross is clipped to the reserved box" {
    var layout = mkLayout();
    var cfg = Layout.FlexConfig{ .direction = .row, .align_items = .flex_start };
    layout.data = &cfg;
    const root = mkElement(100, 100);
    mkRoot(&layout, root);

    layout.addElement(layout.request(.{ .min_size = .{ .w = 10, .h = 10 }, .overflow = overflowCrossFn }), mkElement(10, 10));
    layout.addElement(layout.request(.{ .min_size = .{ .w = 10, .h = 10 } }), mkElement(10, 10));

    const children = layout.lay();
    // Cross is height, so a 30px claim is tolerated: the child stays clipped to
    // its reserved 10px box and the sibling is not pushed down.
    try std.testing.expectEqual(@as(u32, 10), children[0].size.h);
    try std.testing.expectEqual(@as(u32, 0), children[1].pos.y);
}

test "flex content sizing measures preferred size" {
    var layout = mkLayout();
    var cfg = Layout.FlexConfig{ .direction = .row, .gap = 4, .sizing = .{ .main = .content, .cross = .content } };
    layout.data = &cfg;
    const root = mkElement(500, 500);
    mkRoot(&layout, root);

    layout.addElement(layout.request(.{ .min_size = .{ .w = 10, .h = 20 } }), mkElement(10, 20));
    layout.addElement(layout.request(.{ .min_size = .{ .w = 30, .h = 20 } }), mkElement(30, 20));

    const children = layout.lay();
    try std.testing.expectEqual(@as(u32, 10), children[0].size.w);
    try std.testing.expectEqual(@as(u32, 30), children[1].size.w);
    try std.testing.expectEqual(@as(usize, 2), children.len);
}

test "content reports a wrap row's content height from its own requests" {
    var layout = mkLayout();
    var cfg = Layout.FlexConfig{ .direction = .row, .gap = 8, .wrap = true, .sizing = .{ .main = .fixed, .cross = .content } };
    layout.data = &cfg;
    const root = mkElement(800, 600);
    mkRoot(&layout, root);

    for (0..3) |_| {
        layout.addElement(layout.request(.{ .min_size = .{ .w = 400, .h = 40 } }), mkElement(400, 40));
    }

    // Three 400px buttons in an 800px wide row: one per line (400+8+400 > 800).
    const p = layout.vtable.content.?(&layout, .{ .w = 800, .h = 600 }).?;
    try std.testing.expectEqual(@as(u32, 136), p.h); // 3 lines of 40 + 2 gaps of 8
    try std.testing.expectEqual(@as(u32, 0), p.w); // main axis is fixed
}

test "column parent gives a wrap child its fixed width and content height" {
    var parent = mkLayout();
    var pcfg = Layout.FlexConfig{ .direction = .column, .align_items = .flex_start };
    parent.data = &pcfg;
    const root = mkElement(800, 600);
    mkRoot(&parent, root);

    const ce = mkElement(800, 0);
    ce.layout = .{ .vtable = &Layout.flex, .parent = null };
    var ccfg = Layout.FlexConfig{ .direction = .row, .gap = 8, .wrap = true, .sizing = .{ .main = .fixed, .cross = .content } };
    ce.layout.?.data = &ccfg;
    parent.addElement(parent.request(.{ .min_size = .{ .w = 800, .h = 0 }, .size = .{ .w = 800, .h = 0 } }), ce);

    for (0..3) |_| {
        ce.layout.?.addElement(ce.layout.?.request(.{ .min_size = .{ .w = 400, .h = 40 } }), mkElement(400, 40));
    }

    const children = parent.lay();
    try std.testing.expectEqual(@as(usize, 1), children.len);
    try std.testing.expectEqual(@as(u32, 800), children[0].size.w);
    try std.testing.expectEqual(@as(u32, 136), children[0].size.h);
    // the child's own buttons were laid out into its content height
    try std.testing.expectEqual(@as(usize, 3), ce.layout.?.cindex);
}

// A stand-in text layout: a single line of 1170px, which word-wraps to the
// offered width underneath two 30px lines.
const wrapLine = struct {
    fn lay(_: *Layout) void {}
    fn content(_: *Layout, avail: lu.Rect) ?lu.Rect {
        if (avail.w >= 1170) return .{ .w = 1170, .h = 30 };
        return .{ .w = avail.w, .h = 60 };
    }
};
var wrap_line_vtable = Layout.VTable{ .lay = wrapLine.lay, .content = wrapLine.content };
var wrap_line_layout: Layout = .{ .vtable = &wrap_line_vtable, .parent = null };

test "a wrapping content child shrinks to the parent's width" {
    var parent = mkLayout();
    var pcfg = Layout.FlexConfig{ .direction = .column, .align_items = .flex_start };
    parent.data = &pcfg;
    const root = mkElement(100, 200);
    mkRoot(&parent, root);

    const ce = mkElement(1170, 30);
    ce.layout = wrap_line_layout;
    parent.addElement(parent.request(.{ .min_size = .{ .w = 1170, .h = 30 } }), ce);

    const children = parent.lay();
    // The parent only offers 100px of width, so the child wraps: it uses that
    // width (cross), and grows in height (main) to the wrapped block.
    try std.testing.expectEqual(@as(u32, 100), children[0].size.w);
    try std.testing.expectEqual(@as(u32, 60), children[0].size.h);
}

test "a fitting content child keeps its natural single-line size" {
    var parent = mkLayout();
    var pcfg = Layout.FlexConfig{ .direction = .column, .align_items = .flex_start };
    parent.data = &pcfg;
    const root = mkElement(2000, 200);
    mkRoot(&parent, root);

    const ce = mkElement(1170, 30);
    ce.layout = wrap_line_layout;
    parent.addElement(parent.request(.{ .min_size = .{ .w = 1170, .h = 30 } }), ce);

    const children = parent.lay();
    try std.testing.expectEqual(@as(u32, 1170), children[0].size.w);
    try std.testing.expectEqual(@as(u32, 30), children[0].size.h);
}
