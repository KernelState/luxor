const std = @import("std");
const builtin = @import("builtin");
const lu = @import("luxor.zig");
const sdl = @import("sdl");

title: [*:0]const u8,
size: lu.Rect,
transparent: bool,
events: Events = .{},
window: *sdl.SDL_Window,
renderer: *sdl.SDL_Renderer,
textures: [max_textures]Texture = undefined,
clip_stack: [max_clips]lu.Area = undefined,
/// Current index in `textures`
tindex: usize = 0,
/// Current index in `clip_stack`
cindex: usize = 0,
/// Set while a primitive that must escape every ancestor clip (outer shadows)
/// is being queued; `currentClip` then reports no clip so the batch flushes it
/// with the renderer's clip disabled.
clip_suspend: bool = false,
/// Persistent per-element-id textures (created/uploaded via `plugCache`). The
/// Window owns these and destroys them in `deinit`. Falls back to CPU
/// rasterized `Background.buffer` in Context when a draw needs a texture that
/// is not here.
gpu_cache: lu.Cache.Cache(u64, GpuEntry, 65536) = .{},
/// Persistent per-shadow-texture cache (see `drawShadow`). This Window owns the
/// textures; they are destroyed in `deinit` and when the cache fills up or an
/// entry goes stale.
shadow_cache: lu.Cache.Cache(u64, ShadowEntry, 65536) = .{},
/// Persistent backdrop-blur textures (see `drawBlurBackdrop`), keyed by the
/// element's geometry plus the blur settings. This Window owns the textures;
/// they are destroyed in `deinit` and when an entry goes stale.
blur_cache: lu.Cache.Cache(u64, BlurEntry, 65536) = .{},
/// Persistent laid-out layout results (see `Layout.lay`), keyed by the
/// container element's stable id. Owns no textures; stale entries are dropped.
layout_cache: lu.Cache.Cache(u64, lu.Context.LayoutEntry, 65536) = .{},
/// Frame counter, incremented at the top of every `render`. Caches stamp each
/// entry with the last frame it was used and evict entries idle for more than
/// `eviction_frames`, so a disappearing element's textures are torn down.
frame: u64 = 0,
/// Set by `update` when the window is asked to close (QUIT or the window close
/// button). The app loop should stop when `shouldQuit` reports true.
quit: bool = false,
/// The `Context` this view renders, set by `plugCache`. The post-draw
/// processing pass publishes this frame's event state into `ctx.events`, which
/// widgets read when they initialize elements next frame.
ctx: ?*lu.Context = null,
/// Last known pointer position in window coordinates, kept fresh by `update`.
/// Hit-testing runs against this; the published copy lives in `ctx.events`.
pointer: lu.Pos = .{ .x = 0, .y = 0 },
/// Whether the pointer is currently inside the window (the OS does not report
/// motion once it leaves, so this clears hover instead of freezing the last hit).
pointer_inside: bool = false,
/// Set whenever a `MOUSE_MOTION` arrives, reset at the top of `update`, so the
/// processing pass can report "the pointer moved this frame" in `ctx.events`.
mouse_moved: bool = false,
/// Set to the new size whenever a `WINDOW_RESIZED` arrives, reset each frame.
resized: ?lu.Rect = null,
/// The key of the last `KEY_DOWN`/`KEY_UP` edge, reset each frame.
key: ?lu.Key = null,
key_down: bool = false,
/// Button passed to drag hooks while a drag is in progress.
drag_button: u32 = 0,
/// Edge flags accumulated by `update` and consumed by the processing pass at
/// the end of `render`, so per-frame rebuilds don't drop a press/release that
/// arrived between frames.
left_pressed: bool = false,
left_released: bool = false,
/// Per-frame scratch memory for transient working buffers (shadow coverage
/// planes, blur row/column buffers, eviction key lists). Allocated on the heap
/// in `init` (a multi-megabyte inline array would overflow the caller's stack);
/// reset to its base at the top of every `render`, and allocations that
/// overflow it fall back to the page allocator.
scratch: []u8 = &.{},
scratch_fba: std.heap.FixedBufferAllocator = undefined,
scratch_ready: bool = false,
/// Primitives queued during the tree walk and flushed (grouped by texture and
/// clip) once per frame, instead of issuing one SDL draw call per primitive.
batch: Batch = .{},
/// Transient textures (fresh gradient bakes that were not cached) referenced by
/// queued batch primitives; destroyed after the batch is flushed.
pending: [max_pending]?*sdl.SDL_Texture = undefined,
pn: usize = 0,
/// Frame profiler, reference-counted. Null when no debug watcher is alive;
/// `debug()` re-inits it on demand, and the last `debugRelease()` deinits it.
debug_info: ?lu.Debug.DebugInfo = null,
/// Live debug watchers. Zero means measuring is fully off (render does a null
/// check per section instead of reading the clock).
debug_refs: u32 = 0,

const max_textures = 1024;
const max_clips = 64;
/// Max blur downsample exponent: blur factor is `2^level`, `level` capped here.
const max_blur_levels = 5;

/// A cache entry is evicted when it has not been used for this many frames.
const eviction_frames: u64 = 5;
/// Per-frame scratch pool size. Working buffers above this size (large blur
/// planes, huge shadow rasters) are served by the page allocator instead.
const scratch_pool_bytes = 1 << 20;

const mask_segs = 8;
const mask_verts = mask_segs * 4 + 1;
const mask_indices = mask_segs * 4 * 3;

/// Max cells per side of the gradient mesh and the mesh buffers.
const gradient_cells_max = 32;
const gradient_verts_max = (gradient_cells_max + 1) * (gradient_cells_max + 1);
const gradient_indices_max = gradient_cells_max * gradient_cells_max * 6;
/// Gradients are baked into a texture capped at this resolution per side
/// and stretched to the drawing area.
const max_gradient_size: f32 = 512.0;

/// Frame buffer sizes for the batched primitive queue. The scene is small
/// (hundreds of rounded-rect fans and textured quads); when the buffers fill
/// mid-frame the queued primitives are flushed early and the queue reopens.
const max_batch_verts = 16384;
const max_batch_idx = 65536;
const max_batch_prims = 4096;
/// Transient textures awaiting destruction after the next batch flush.
const max_pending = 128;

/// One queued draw primitive: vertices/indices sliced into the batch arrays,
/// the texture they sample (null = flat vertex color), and the clip rect active
/// when it was queued. Consecutive primitives with the same texture and clip
/// share one primitive and are drawn with a single `SDL_RenderGeometry` call.
const BatchPrim = struct {
    tex: ?*sdl.SDL_Texture,
    clip: ClipRec,
    vstart: usize,
    vlen: usize,
    istart: usize,
    ilen: usize,
};

/// The clip rect in effect when a primitive was queued; `active = false` means
/// no clip (the render target's own bounds clip it).
const ClipRec = struct {
    active: bool,
    area: lu.Area = undefined,
};

const Batch = struct {
    prims: []BatchPrim = &.{},
    verts: []sdl.SDL_Vertex = &.{},
    idx: []c_int = &.{},
    nprims: usize = 0,
    nverts: usize = 0,
    nidx: usize = 0,
    /// The texture and clip of the currently open primitive run, for merging.
    open: bool = false,
    cur_tex: ?*sdl.SDL_Texture = undefined,
    cur_clip: ClipRec = undefined,
};

const Surface = sdl.surface.SDL_Surface;

// `sdl.renderReadPixels` is broken upstream: its extern return type references
// the non-existent `pixels.SDL_Surface` type, so the call has to be declared
// here. The surface and premultiply helpers are used from the sdl module.
extern fn SDL_RenderReadPixels(renderer: *sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) ?*Surface;

const Window = @This();

pub const Config = struct {
    min_size: lu.Rect,
    max_size: ?lu.Rect = null,
    pos: ?lu.Pos = null,
    title: [*:0]const u8,
    decorated: bool = true,
    transparent: bool = true,
    /// The window manager can still resize even when false,
    /// this is just a guide not a requirement.
    resizable: bool = true,
};

pub const Events = struct {
    resize: lu.Hook(lu.Rect) = .{ .handle = null },
    draw: lu.Hook(void) = .{ .handle = null },
    cursor_move: lu.Hook(lu.Pos) = .{ .handle = null },
    click: lu.Hook(lu.MouseButton) = .{ .handle = null },
    key: lu.Hook(lu.Key) = .{ .handle = null },
    exit: lu.Hook(void) = .{ .handle = null },
};

pub const Texture = struct {
    texture: *sdl.SDL_Texture,

    pub const Format = enum {
        rgba8,
        bgra8,
        rgb8,
        rgba16f,
        r8, // grayscale

        pub fn toSDLPixelFormat(self: Format) sdl.SDL_PixelFormat {
            return switch (self) {
                .rgba8 => sdl.SDL_PIXELFORMAT_RGBA8888,
                .bgra8 => sdl.SDL_PIXELFORMAT_BGRA8888,
                .rgb8 => sdl.pixels.SDL_PIXELFORMAT_RGB24,
                .rgba16f => sdl.pixels.SDL_PIXELFORMAT_RGBA64_FLOAT,
                .r8 => sdl.pixels.SDL_PIXELFORMAT_INDEX8,
            };
        }
    };
};

/// An entry in the Window's persistent per-element texture cache.
const GpuEntry = struct {
    texture: *sdl.SDL_Texture,
    /// Hash of the input that produced `texture`; a match means the texture is
    /// still current and no re-upload (or re-rasterize) is needed.
    fingerprint: u64,
    /// Last frame this entry was used; idle entries are evicted.
    last_seen: u64,
};

/// A cached backdrop-blur texture.
const BlurEntry = struct {
    texture: *sdl.SDL_Texture,
    /// Size of the (possibly downsampled) blur texture, in texels; the drawing
    /// code derives the source rectangle from the element geometry and these.
    w: u32,
    h: u32,
    /// Last frame this entry was used; idle entries are evicted.
    last_seen: u64,
};

pub fn init(config: Config) !Window {
    var flags: u32 = 0;
    if (config.resizable)
        flags |= sdl.SDL_WINDOW_RESIZABLE;
    if (!config.decorated)
        flags |= sdl.SDL_WINDOW_BORDERLESS;
    if (config.transparent)
        flags |= sdl.video.SDL_WINDOW_TRANSPARENT;
    var self = Window{
        .transparent = (flags & sdl.video.SDL_WINDOW_TRANSPARENT != 0),
        .renderer = undefined,
        .window = undefined,
        .size = undefined,
        .title = config.title,
    };
    // The per-frame scratch pool and batch buffers are the bulk of the struct's
    // memory; keep them on the heap so `Window` stays a small stack value.
    self.scratch = try std.heap.page_allocator.alloc(u8, scratch_pool_bytes);
    self.batch.prims = try std.heap.page_allocator.alloc(BatchPrim, max_batch_prims);
    self.batch.verts = try std.heap.page_allocator.alloc(sdl.SDL_Vertex, max_batch_verts);
    self.batch.idx = try std.heap.page_allocator.alloc(c_int, max_batch_idx);
    if (!sdl.createWindowAndRenderer(
        config.title,
        @intCast(config.min_size.w),
        @intCast(config.min_size.h),
        flags,
        @ptrCast(&self.window),
        @ptrCast(&self.renderer),
    ))
        return error.FailedToCreateWindow;
    if (!sdl.getWindowSize(
        self.window,
        @ptrCast(&self.size.w),
        @ptrCast(&self.size.h),
    ))
        return error.FailedToGetWindowInfo;
    return self;
}

pub fn deinit(self: *Window) void {
    for (self.textures[0..self.tindex]) |t| {
        sdl.destroyTexture(t.texture);
    }
    var it = self.gpu_cache.iterator();
    while (it.next()) |entry| {
        sdl.destroyTexture(entry.value_ptr.texture);
    }
    var sit = self.shadow_cache.iterator();
    while (sit.next()) |entry| {
        sdl.destroyTexture(entry.value_ptr.texture);
    }
    var bit = self.blur_cache.iterator();
    while (bit.next()) |entry| {
        sdl.destroyTexture(entry.value_ptr.texture);
    }
    std.heap.page_allocator.free(self.scratch);
    std.heap.page_allocator.free(self.batch.prims);
    std.heap.page_allocator.free(self.batch.verts);
    std.heap.page_allocator.free(self.batch.idx);
    sdl.destroyRenderer(self.renderer);
    sdl.destroyWindow(self.window);
}

/// Registers a texture and returns its index, usable in `lu.Image`.
pub fn addTexture(self: *Window, tex: *sdl.SDL_Texture) !usize {
    if (self.tindex >= max_textures) {
        if (builtin.mode == .Debug) {
            @panic("Failed to add texture, texture array is full");
        } else {
            return error.TextureLimitReached;
        }
    }
    const id = self.tindex;
    self.textures[id] = .{ .texture = tex };
    self.tindex += 1;
    return id;
}

/// Looks up a registered texture by index.
pub fn texture(self: *Window, id: usize) ?*sdl.SDL_Texture {
    if (id >= self.tindex) return null;
    return self.textures[id].texture;
}

/// Hands this Window's persistent texture cache and layout-results cache to
/// `ctx`, so rasterized text and images upload once per element id instead of
/// on every frame, and containers with a stable id reuse their laid-out
/// positions. Also links the view's per-frame event state (`ctx.events`), which
/// the post-draw processing pass rewrites every frame. Call once after the
/// Window (and the Context) exist, before building widgets.
pub fn plugCache(self: *Window, ctx: *lu.Context) void {
    self.ctx = ctx;
    ctx.gpu_cache = .{
        .ptr = self,
        .lookup = &lookupCached,
        .upload = &uploadCached,
    };
    ctx.layout_cache = .{
        .ptr = self,
        .consult = &consultLayout,
        .store = &storeLayout,
    };
}

/// Brackets one cache consult/retrieve/upload under the `.cache` profiler
/// section. The section is nesting-aware, so a cache call that happens while
/// another is open (a cached texture drawn from inside a shadow lookup) still
/// folds into a single timing span without corrupting the enclosing phase.
/// Mirrors `if (self.debug_info) |*d| ...` used for the other phases.
fn cacheBegin(self: *Window) void {
    if (self.debug_info) |*d| d.begin(.cache);
}

fn cacheEnd(self: *Window) void {
    if (self.debug_info) |*d| d.end(.cache);
}

fn lookupCached(ptr: *anyopaque, key: u64, fingerprint: u64) ?u64 {
    const self: *Window = @ptrCast(@alignCast(ptr));
    self.cacheBegin();
    defer self.cacheEnd();
    const entry = self.gpu_cache.getMutable(key) orelse return null;
    if (entry.fingerprint != fingerprint) return null;
    entry.last_seen = self.frame;
    return key;
}

fn uploadCached(ptr: *anyopaque, key: u64, fingerprint: u64, pb: lu.PixelBuffer) ?u64 {
    const self: *Window = @ptrCast(@alignCast(ptr));
    if (pb.pixels.len == 0 or pb.width == 0 or pb.height == 0) return null;
    const tex = sdl.createTexture(
        self.renderer,
        sdl.pixels.SDL_PIXELFORMAT_ABGR8888,
        sdl.SDL_TEXTUREACCESS_STREAMING,
        @intCast(pb.width),
        @intCast(pb.height),
    ) orelse return null;
    _ = sdl.setTextureBlendMode(tex, sdl.SDL_BLENDMODE_BLEND);
    _ = sdl.updateTexture(tex, null, @ptrCast(pb.pixels.ptr), @intCast(pb.width * 4));
    self.cacheBegin();
    defer self.cacheEnd();
    if (self.gpu_cache.get(key)) |old| sdl.destroyTexture(old.texture);
    self.gpu_cache.put(key, .{ .texture = tex, .fingerprint = fingerprint, .last_seen = self.frame });
    return key;
}

/// Returns the cached layout for a container element's stable id, or null when
/// there is no cached entry.
fn consultLayout(ptr: *anyopaque, key: u64) ?*lu.Context.LayoutEntry {
    const self: *Window = @ptrCast(@alignCast(ptr));
    self.cacheBegin();
    defer self.cacheEnd();
    const entry = self.layout_cache.getMutable(key) orelse return null;
    entry.last_seen = self.frame;
    return entry;
}

/// Stores a freshly computed layout under the container element's stable id.
fn storeLayout(ptr: *anyopaque, key: u64, layout: *lu.Layout) void {
    const self: *Window = @ptrCast(@alignCast(ptr));
    self.cacheBegin();
    defer self.cacheEnd();
    var entry = lu.Context.LayoutEntry{
        .container = layout.container,
        .n = layout.cindex,
        .kids = undefined,
        .last_seen = self.frame,
    };
    for (0..layout.cindex) |i| {
        const c = layout.children[i];
        entry.kids[i] = .{
            .id = c.id,
            .extra = c.id_extra,
            .pos = c.pos,
            .size = c.size,
        };
    }
    self.layout_cache.put(key, entry);
}

pub fn pushClip(self: *Window, area: lu.Area) void {
    if (self.cindex >= self.clip_stack.len) {
        if (builtin.mode == .Debug) {
            @panic("Failed to add clip, clip_stack is full");
        } else {
            std.log.warn("Failed to add clip, clip_stack is full, please contact the developer to fix that", .{});
            return;
        }
    }
    self.clip_stack[self.cindex] = area;
    _ = sdl.setRenderClipRect(self.renderer, &area.toSDL());
    self.cindex += 1;
}

pub fn popClip(self: *Window) void {
    if (self.cindex == 0) return;
    self.cindex -= 1;
    self.clip_stack[self.cindex] = undefined;
    if (self.cindex == 0)
        _ = sdl.setRenderClipRect(self.renderer, null)
    else
        _ = sdl.setRenderClipRect(self.renderer, &self.clip_stack[self.cindex - 1].toSDL());
}

/// Renders an element tree, applying the background, border, padding, margin
/// and effects of every element through SDL.
///
/// Elements with a `blur` effect capture the pixels currently behind them in
/// the backbuffer at draw time, so the blur is a live overlay: it only ever
/// blurs what is directly underneath and is independent of the window size.
///
/// After the frame is drawn, a *processing* pass runs against the freshly
/// laid-out tree: the pointer is hit-tested (clip-aware, so a child visually
/// clipped by an ancestor cannot be clicked where it is not visible), pointer
/// edges accumulated by `update` are dispatched onto the element hooks (hover,
/// click, focus, drag), and the frame's event state is written into `ctx.events`.
/// Because it runs after drawing, the frame always shows *last frame's* event
/// state (widgets evaluate it at init) while the hook callbacks fire here and
/// their effects appear next frame.
pub fn render(self: *Window, root: *lu.Element) void {
    _ = sdl.getWindowSize(
        self.window,
        @ptrCast(&self.size.w),
        @ptrCast(&self.size.h),
    );
    self.ensureScratch();
    _ = self.scratch_fba.reset();
    self.frame += 1;
    self.evictStale();
    self.batchReset();
    self.pn = 0;
    if (self.debug_info) |*d| d.begin(.layout);
    // Top-down layout: size the root from the window, wire it to its layout,
    // and let the layout tree size and position every descendant.
    root.size = self.size;
    root.pos = .{ .x = 0, .y = 0 };
    const root_layout = &(root.layout orelse return);
    root_layout.element = root;
    _ = root_layout.lay();
    if (self.debug_info) |*d| d.end(.layout);
    if (self.debug_info) |*d| d.begin(.draw);
    self.drawElement(root, .{ .pos = root.pos, .size = root.size });
    self.flushBatch();
    self.drainPending();
    if (self.debug_info) |*d| d.end(.draw);
    self.events.draw.emit({});
    self.process(root);
}

/// Whether `update` has seen the window asked to close (QUIT or a close
/// request). The app loop should stop as soon as this is true.
pub fn shouldQuit(self: *Window) bool {
    return self.quit;
}

/// Pumps the SDL event queue, mapping each event onto the view's raw input
/// state (pointer position, press/release edges, key edges, resize, exit) and
/// firing the `Window.Events` hooks (`resize`, `cursor_move`, `click`, `key`,
/// `exit`). The raw input is consumed by the processing pass at the end of
/// `render`, which publishes the frame's event state into `ctx.events`. Call
/// once per frame, before rebuilding the widget tree.
pub fn update(self: *Window) void {
    // Per-frame impulses: they only report what happened between this update
    // and the previous one, so clear them before pumping.
    self.mouse_moved = false;
    self.resized = null;
    self.key = null;
    self.key_down = false;
    var event: sdl.SDL_Event = undefined;
    while (sdl.pollEvent(&event)) {
        switch (event.type) {
            sdl.SDL_EVENT_QUIT, sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                self.events.exit.activate({});
                self.quit = true;
            },
            sdl.SDL_EVENT_WINDOW_RESIZED => {
                self.resized = .{
                    .w = @intCast(event.window.data1),
                    .h = @intCast(event.window.data2),
                };
                self.events.resize.activate(self.resized.?);
            },
            sdl.SDL_EVENT_WINDOW_MOUSE_ENTER => self.pointer_inside = true,
            sdl.SDL_EVENT_WINDOW_MOUSE_LEAVE => self.pointer_inside = false,
            sdl.SDL_EVENT_KEY_DOWN => {
                if (keyFromScancode(event.key.scancode)) |k| {
                    self.key = k;
                    self.key_down = true;
                    self.events.key.activate(k);
                }
            },
            sdl.SDL_EVENT_KEY_UP => {
                if (keyFromScancode(event.key.scancode)) |k| {
                    self.key = k;
                    self.key_down = false;
                    self.events.key.deactivate(k);
                }
            },
            sdl.SDL_EVENT_MOUSE_MOTION => {
                self.pointer_inside = true;
                self.mouse_moved = true;
                self.pointer = sdlPosToLu(event.motion.x, event.motion.y, self.size);
                self.events.cursor_move.activate(self.pointer);
            },
            sdl.SDL_EVENT_MOUSE_BUTTON_DOWN, sdl.SDL_EVENT_MOUSE_BUTTON_UP => {
                const button = sdlButtonToLu(event.button.button);
                self.pointer_inside = true;
                self.pointer = sdlPosToLu(event.button.x, event.button.y, self.size);
                if (event.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN) {
                    self.events.click.activate(button);
                    if (button == .left) self.left_pressed = true;
                } else {
                    self.events.click.deactivate(button);
                    if (button == .left) self.left_released = true;
                }
            },
            else => {},
        }
        // `window.size` is synced at the top of every `render` too, but keep it
        // authoritative for hit-testing in case events arrive between renders.
        _ = sdl.getWindowSize(self.window, @ptrCast(&self.size.w), @ptrCast(&self.size.h));
    }
}

/// The processing pass that runs *after* the frame is drawn: hit-test the
/// pointer against the freshly laid-out tree, dispatch pointer edges onto the
/// element hooks, and rewrite `ctx.events` with this frame's event state. The
/// next frame's widgets read that state at init (via `fromId`), so they render
/// last frame's interactions while the hook callbacks fired here take effect
/// next frame.
fn process(self: *Window, root: *lu.Element) void {
    const ctx = self.ctx orelse return;
    const root_area = lu.Area{ .pos = root.pos, .size = root.size };
    const hit = if (self.pointer_inside)
        self.hitTest(root, root_area, null, self.pointer)
    else
        null;

    // Non-element-specific state mirrors the raw input from `update`.
    ctx.events.pointer = self.pointer;
    ctx.events.pointer_inside = self.pointer_inside;
    ctx.events.mouse_moved = self.mouse_moved;
    ctx.events.resized = self.resized;
    ctx.events.key = self.key;
    ctx.events.key_down = self.key_down;
    ctx.events.exit = self.quit;

    // Hover: fire enter/leave against the previous frame's hovered element, and
    // record this frame's hovered element in the view.
    const hit_id = if (hit) |h| h.id else 0;
    const prev_hovered = ctx.events.hovered orelse 0;
    ctx.events.hovered = if (hit) |h| h.id else null;
    if (hit_id != prev_hovered) {
        if (prev_hovered != 0)
            if (self.findElement(root, prev_hovered)) |old| old.events.hover.deactivate({});
        if (hit) |h| h.events.hover.activate({});
    }

    if (self.left_pressed) {
        self.left_pressed = false;
        if (hit) |h| {
            // A press starts a click; when the element also has a drag hook the
            // press becomes the drag's start instead (the click hook still
            // fires, but the release below never completes it).
            ctx.events.clicked = h.id;
            h.events.click.activate({});
            if (h.events.drag.isEnabled()) {
                ctx.events.dragged = h.id;
                self.drag_button = @intFromEnum(lu.MouseButton.left);
                // One call when the drag starts; the app reads `ctx.events`
                // (dragged + pointer) during its build to follow the mouse.
                h.events.drag.activate(self.drag_button);
                self.focus(root, h);
            } else {
                self.focus(root, h);
            }
        } else {
            ctx.events.clicked = null;
            // Pressing empty space drops keyboard focus.
            if (ctx.events.focused) |pid|
                if (self.findElement(root, pid)) |old| old.events.focus.deactivate({});
            ctx.events.focused = null;
        }
    }

    if (self.left_released) {
        self.left_released = false;
        if (ctx.events.dragged) |did| {
            if (self.findElement(root, did)) |d|
                d.events.drag.deactivate(self.drag_button);
            ctx.events.dragged = null;
        } else if (ctx.events.clicked) |cid| {
            // Only a release inside the element that took the press completes
            // the click (the hook fires `false`); elsewhere the press is left
            // discrete because the element is rebuilt next frame anyway.
            if (hit) |h| if (h.id == cid) h.events.click.deactivate({});
            ctx.events.clicked = null;
        }
    }
}

/// Moves keyboard focus to `hit` if it is focusable and differs from the
/// current focus, debouncing the old element's `focus` hook.
fn focus(self: *Window, root: *lu.Element, hit: *lu.Element) void {
    const ctx = self.ctx orelse return;
    if (!hit.focusable) return;
    const prev = ctx.events.focused;
    if (prev) |pid| if (pid == hit.id) return;
    if (prev) |pid|
        if (self.findElement(root, pid)) |old| old.events.focus.deactivate({});
    ctx.events.focused = hit.id;
    hit.events.focus.activate({});
}

/// Recursively finds the topmost element under `pos`. Mirror of the draw walk:
/// children draw over their parent, so the deepest hit wins, and the effective
/// clip of every ancestor (`clip` plus the element's own box and content box)
/// gates the search so nothing invisible is returned.
fn hitTest(self: *Window, e: *lu.Element, area: lu.Area, clip: ?lu.Area, pos: lu.Pos) ?*lu.Element {
    if (!posInArea(pos, area)) return null;
    if (clip) |c| if (!posInArea(pos, c)) return null;
    if (e.layout) |*lay| {
        if (lay.cindex > 0) {
            const child_clip = intersectClip(clip, contentArea(e, area));
            var top: ?*lu.Element = null;
            for (0..lay.cindex) |i| {
                const child = lay.children[i];
                if (self.hitTest(child, .{ .pos = child.pos, .size = child.size }, child_clip, pos)) |h| top = h;
            }
            if (top) |t| return t;
        }
    }
    return e;
}

/// Depth-first search for the element with stable id `id` in the laid-out tree.
/// Used to reach the *previous* hover/focus element after the tree was rebuilt,
/// since the old pointer was invalidated by the pool reset.
fn findElement(self: *Window, e: *lu.Element, id: u64) ?*lu.Element {
    if (e.id == id) return e;
    if (e.layout) |*lay| {
        for (0..lay.cindex) |i| {
            if (self.findElement(lay.children[i], id)) |f| return f;
        }
    }
    return null;
}

fn posInArea(pos: lu.Pos, area: lu.Area) bool {
    return pos.x >= area.pos.x and pos.y >= area.pos.y and
        pos.x < area.pos.x + area.size.w and pos.y < area.pos.y + area.size.h;
}

/// Intersects an optional clip rect with `area`, or returns `area` when no clip
/// is active. A zero-area result simply fails every `posInArea` test.
fn intersectClip(clip: ?lu.Area, area: lu.Area) ?lu.Area {
    const a = clip orelse return area;
    const x0 = @max(a.pos.x, area.pos.x);
    const y0 = @max(a.pos.y, area.pos.y);
    const x1 = @min(a.pos.x +| a.size.w, area.pos.x +| area.size.w);
    const y1 = @min(a.pos.y +| a.size.h, area.pos.y +| area.size.h);
    return .{
        .pos = .{ .x = x0, .y = y0 },
        .size = .{ .w = x1 -| x0, .h = y1 -| y0 },
    };
}

/// Clamps raw SDL mouse coordinates into window pixel coordinates.
fn sdlPosToLu(x: f32, y: f32, size: lu.Rect) lu.Pos {
    const clamp_axis = struct {
        fn f(v: f32, m: u32) u32 {
            const iv = @max(@as(i32, @intFromFloat(@floor(v))), 0);
            const limit = @as(i32, @intCast(m)) -| 1;
            return @intCast(@min(iv, limit));
        }
    }.f;
    return .{ .x = clamp_axis(x, size.w), .y = clamp_axis(y, size.h) };
}

/// Maps SDL mouse button indices onto `lu.MouseButton`. SDL numbers buttons
/// 1..5 (left, middle, right, X1, X2); anything unmapped falls back to left.
fn sdlButtonToLu(button: u8) lu.MouseButton {
    return switch (button) {
        sdl.SDL_BUTTON_LEFT => .left,
        sdl.SDL_BUTTON_MIDDLE => .scroll,
        else => .right,
    };
}

/// Maps an SDL scancode onto the `lu.Key` repertoire, when it exists there.
fn keyFromScancode(sc: c_int) ?lu.Key {
    const letter = sdl.keycode.SDL_SCANCODE_A;
    if (sc >= letter and sc < letter + 26)
        return @enumFromInt(@as(u8, @intCast(sc - letter)));
    return switch (sc) {
        sdl.keycode.SDL_SCANCODE_1 => .num1,
        sdl.keycode.SDL_SCANCODE_2 => .num2,
        sdl.keycode.SDL_SCANCODE_3 => .num3,
        sdl.keycode.SDL_SCANCODE_4 => .num4,
        sdl.keycode.SDL_SCANCODE_5 => .num5,
        sdl.keycode.SDL_SCANCODE_6 => .num6,
        sdl.keycode.SDL_SCANCODE_7 => .num7,
        sdl.keycode.SDL_SCANCODE_8 => .num8,
        sdl.keycode.SDL_SCANCODE_9 => .num9,
        sdl.keycode.SDL_SCANCODE_0 => .num0,
        sdl.keycode.SDL_SCANCODE_F1 => .f1,
        sdl.keycode.SDL_SCANCODE_F2 => .f2,
        sdl.keycode.SDL_SCANCODE_F3 => .f3,
        sdl.keycode.SDL_SCANCODE_F4 => .f4,
        sdl.keycode.SDL_SCANCODE_F5 => .f5,
        sdl.keycode.SDL_SCANCODE_F6 => .f6,
        sdl.keycode.SDL_SCANCODE_F7 => .f7,
        sdl.keycode.SDL_SCANCODE_F8 => .f8,
        sdl.keycode.SDL_SCANCODE_F9 => .f9,
        sdl.keycode.SDL_SCANCODE_F10 => .f10,
        sdl.keycode.SDL_SCANCODE_F11 => .f11,
        sdl.keycode.SDL_SCANCODE_F12 => .f12,
        sdl.keycode.SDL_SCANCODE_RETURN => .enter,
        sdl.keycode.SDL_SCANCODE_ESCAPE => .escape,
        sdl.keycode.SDL_SCANCODE_BACKSPACE => .backspace,
        sdl.keycode.SDL_SCANCODE_TAB => .tab,
        sdl.keycode.SDL_SCANCODE_SPACE => .space,
        sdl.keycode.SDL_SCANCODE_GRAVE => .grave,
        sdl.keycode.SDL_SCANCODE_MINUS => .minus,
        sdl.keycode.SDL_SCANCODE_EQUALS => .equal,
        sdl.keycode.SDL_SCANCODE_LEFTBRACKET => .left_bracket,
        sdl.keycode.SDL_SCANCODE_RIGHTBRACKET => .right_bracket,
        sdl.keycode.SDL_SCANCODE_BACKSLASH => .backslash,
        sdl.keycode.SDL_SCANCODE_SEMICOLON => .semicolon,
        sdl.keycode.SDL_SCANCODE_APOSTROPHE => .apostrophe,
        sdl.keycode.SDL_SCANCODE_COMMA => .comma,
        sdl.keycode.SDL_SCANCODE_PERIOD => .period,
        sdl.keycode.SDL_SCANCODE_SLASH => .slash,
        sdl.keycode.SDL_SCANCODE_CAPSLOCK => .caps_lock,
        sdl.keycode.SDL_SCANCODE_PRINTSCREEN => .print_screen,
        sdl.keycode.SDL_SCANCODE_SCROLLLOCK => .scroll_lock,
        sdl.keycode.SDL_SCANCODE_PAUSE => .pause,
        sdl.keycode.SDL_SCANCODE_INSERT => .insert,
        sdl.keycode.SDL_SCANCODE_HOME => .home,
        sdl.keycode.SDL_SCANCODE_PAGEUP => .page_up,
        sdl.keycode.SDL_SCANCODE_DELETE => .delete,
        sdl.keycode.SDL_SCANCODE_END => .end,
        sdl.keycode.SDL_SCANCODE_PAGEDOWN => .page_down,
        sdl.keycode.SDL_SCANCODE_RIGHT => .right,
        sdl.keycode.SDL_SCANCODE_LEFT => .left,
        sdl.keycode.SDL_SCANCODE_DOWN => .down,
        sdl.keycode.SDL_SCANCODE_UP => .up,
        sdl.keycode.SDL_SCANCODE_NUMLOCKCLEAR => .num_lock,
        sdl.keycode.SDL_SCANCODE_KP_DIVIDE => .kp_divide,
        sdl.keycode.SDL_SCANCODE_KP_MULTIPLY => .kp_multiply,
        sdl.keycode.SDL_SCANCODE_KP_MINUS => .kp_subtract,
        sdl.keycode.SDL_SCANCODE_KP_PLUS => .kp_add,
        sdl.keycode.SDL_SCANCODE_KP_ENTER => .kp_enter,
        sdl.keycode.SDL_SCANCODE_KP_1 => .kp1,
        sdl.keycode.SDL_SCANCODE_KP_2 => .kp2,
        sdl.keycode.SDL_SCANCODE_KP_3 => .kp3,
        sdl.keycode.SDL_SCANCODE_KP_4 => .kp4,
        sdl.keycode.SDL_SCANCODE_KP_5 => .kp5,
        sdl.keycode.SDL_SCANCODE_KP_6 => .kp6,
        sdl.keycode.SDL_SCANCODE_KP_7 => .kp7,
        sdl.keycode.SDL_SCANCODE_KP_8 => .kp8,
        sdl.keycode.SDL_SCANCODE_KP_9 => .kp9,
        sdl.keycode.SDL_SCANCODE_KP_0 => .kp0,
        sdl.keycode.SDL_SCANCODE_KP_PERIOD => .kp_decimal,
        sdl.keycode.SDL_SCANCODE_MENU => .menu,
        sdl.keycode.SDL_SCANCODE_LCTRL => .left_ctrl,
        sdl.keycode.SDL_SCANCODE_LSHIFT => .left_shift,
        sdl.keycode.SDL_SCANCODE_LALT => .left_alt,
        sdl.keycode.SDL_SCANCODE_LGUI => .left_super,
        sdl.keycode.SDL_SCANCODE_RCTRL => .right_ctrl,
        sdl.keycode.SDL_SCANCODE_RSHIFT => .right_shift,
        sdl.keycode.SDL_SCANCODE_RALT => .right_alt,
        sdl.keycode.SDL_SCANCODE_RGUI => .right_super,
        else => null,
    };
}

/// The current window state as `Overrides`, so a rebuilt root element tracks
/// reactive values (the window size, for example). Apply these to the root
/// before rendering each frame:
///
/// ```zig
/// var root = lu.Element{ ... };
/// root.override(window.overrides());
/// window.render(root);
/// ```
pub fn overrides(self: *Window) lu.Element.Overrides {
    return .{ .size = self.size };
}

/// Enables frame profiling and returns the shared `DebugInfo` (re-inited fresh
/// if it was released). Every call to `debug()` must be matched by a
/// `debugRelease()`; the actual profiler object is torn down when the last
/// watcher releases, so timing overhead is zero when nobody is looking.
pub fn debug(self: *Window) *lu.Debug.DebugInfo {
    if (self.debug_info == null)
        self.debug_info = lu.Debug.DebugInfo.init();
    self.debug_refs += 1;
    return &self.debug_info.?;
}

/// Releases one `debug()` reference (idempotent). When the last watcher
/// releases, the profiler object is deinited; a later `debug()` re-inits it.
pub fn debugRelease(self: *Window) void {
    if (self.debug_refs == 0) return;
    self.debug_refs -= 1;
    if (self.debug_refs == 0) {
        self.debug_info.?.deinit();
        self.debug_info = null;
    }
}

fn ensureScratch(self: *Window) void {
    if (self.scratch_ready) return;
    self.scratch_fba = std.heap.FixedBufferAllocator.init(self.scratch);
    self.scratch_ready = true;
}

/// Allocates `n` items from the per-frame scratch pool, falling back to the
/// page allocator for allocations that overflow the pool. Pool memory is
/// reclaimed wholesale at the next frame's `scratch_fba.reset()`.
fn scratchAlloc(self: *Window, comptime T: type, n: usize) ![]T {
    self.ensureScratch();
    if (self.scratch_fba.allocator().alloc(T, n)) |m| return m else |_| {}
    return std.heap.page_allocator.alloc(T, n);
}

/// Frees a scratch allocation. Pool-owned memory is a no-op (reclaimed on the
/// next frame reset); page-backed overflow is returned to the allocator.
fn scratchFree(self: *Window, comptime T: type, m: []T) void {
    if (m.len == 0) return;
    const lo: usize = @intFromPtr(self.scratch.ptr);
    const hi: usize = lo + self.scratch.len;
    const p: usize = @intFromPtr(m.ptr);
    if (p >= lo and p < hi) return;
    std.heap.page_allocator.free(m);
}

/// Frees every texture cached entry that has not been used in the last
/// `eviction_frames` frames, across all caches. Runs once per frame at the top
/// of `render`, so a texture whose element disappears (or stops being drawn)
/// is torn down shortly after it goes idle.
fn evictStale(self: *Window) void {
    self.sweepCache(GpuEntry, &self.gpu_cache, true);
    self.sweepCache(ShadowEntry, &self.shadow_cache, true);
    self.sweepCache(BlurEntry, &self.blur_cache, true);
    self.sweepCache(lu.Context.LayoutEntry, &self.layout_cache, false);
}

fn sweepCache(
    self: *Window,
    comptime V: type,
    cache: *lu.Cache.Cache(u64, V, 65536),
    comptime destroy_tex: bool,
) void {
    const n = cache.count();
    if (n == 0) return;
    const keys = self.scratchAlloc(u64, n) catch return;
    defer self.scratchFree(u64, keys);
    var kn: usize = 0;
    var it = cache.iterator();
    while (it.next()) |en| {
        const e = &en.value_ptr.*;
        if (self.frame -| e.last_seen > eviction_frames) {
            keys[kn] = en.key_ptr.*;
            kn += 1;
        }
    }
    for (keys[0..kn]) |k| {
        if (destroy_tex)
            if (cache.get(k)) |en| sdl.destroyTexture(en.texture);
        cache.remove(k);
    }
}

fn batchReset(self: *Window) void {
    self.batch.nprims = 0;
    self.batch.nverts = 0;
    self.batch.nidx = 0;
    self.batch.open = false;
}

/// The clip rect in effect right now (the top of the clip stack), or no clip.
/// While `clip_suspend` is set, everything reports no clip so queued primitives
/// (outer shadows) are flushed with the renderer clip disabled.
fn currentClip(self: *const Window) ClipRec {
    if (self.clip_suspend) return .{ .active = false };
    if (self.cindex == 0) return .{ .active = false };
    return .{ .active = true, .area = self.clip_stack[self.cindex - 1] };
}

fn clipEq(a: ClipRec, b: ClipRec) bool {
    if (a.active != b.active) return false;
    if (!a.active) return true;
    return a.area.pos.x == b.area.pos.x and a.area.pos.y == b.area.pos.y and
        a.area.size.w == b.area.size.w and a.area.size.h == b.area.size.h;
}

/// Appends a primitive to the per-frame batch. Consecutive primitives with the
/// same texture and clip are merged into a single `SDL_RenderGeometry` call at
/// flush time (their vertices carry their own colors, so distinct colors can
/// share a call); when a run breaks (texture or clip changes) the previous run
/// is closed and a new one begins, preserving painter's order. If the batch
/// buffers fill, everything queued so far is flushed early and the batch
/// reopens for the remainder.
fn emitPrim(self: *Window, tex: ?*sdl.SDL_Texture, clip: ClipRec, verts: []const sdl.SDL_Vertex, idx: []const c_int) void {
    if (verts.len == 0 or idx.len == 0) return;
    const b = &self.batch;
    const same_run = b.open and b.cur_tex == tex and clipEq(b.cur_clip, clip);
    if (!same_run) {
        if (b.nprims >= b.prims.len) {
            self.flushBatch();
            return self.emitPrim(tex, clip, verts, idx);
        }
        b.open = true;
        b.cur_tex = tex;
        b.cur_clip = clip;
        b.prims[b.nprims] = .{
            .tex = tex,
            .clip = clip,
            .vstart = b.nverts,
            .vlen = verts.len,
            .istart = b.nidx,
            .ilen = idx.len,
        };
        b.nprims += 1;
    }
    if (b.nverts + verts.len > b.verts.len or b.nidx + idx.len > b.idx.len) {
        self.flushBatch();
        return self.emitPrim(tex, clip, verts, idx);
    }
    const p = &b.prims[b.nprims - 1];
    @memcpy(b.verts[b.nverts .. b.nverts + verts.len], verts);
    @memcpy(b.idx[b.nidx .. b.nidx + idx.len], idx);
    b.nverts += verts.len;
    b.nidx += idx.len;
    p.vlen = b.nverts - p.vstart;
    p.ilen = b.nidx - p.istart;
}

/// Draws every queued primitive, setting the clip rect only when it changes
/// between runs and issuing one `SDL_RenderGeometry` call per run. The batch is
/// empty afterwards; `render` calls this once after the tree walk.
fn flushBatch(self: *Window) void {
    const b = &self.batch;
    if (b.nprims == 0) return;
    _ = sdl.setRenderDrawBlendMode(self.renderer, sdl.SDL_BLENDMODE_BLEND);
    var cur = ClipRec{ .active = false };
    for (b.prims[0..b.nprims]) |p| {
        if (!clipEq(cur, p.clip)) {
            cur = p.clip;
            if (p.clip.active)
                _ = sdl.setRenderClipRect(self.renderer, &p.clip.area.toSDL())
            else
                _ = sdl.setRenderClipRect(self.renderer, null);
        }
        _ = sdl.renderGeometry(
            self.renderer,
            p.tex,
            b.verts[p.vstart..][0..p.vlen].ptr,
            @intCast(p.vlen),
            b.idx[p.istart..][0..p.ilen].ptr,
            @intCast(p.ilen),
        );
    }
    _ = sdl.setRenderClipRect(self.renderer, null);
    self.batchReset();
}

/// Schedules a texture for destruction after the next batch flush. Transient
/// textures (uncached gradient bakes) are still referenced by queued
/// primitives, so they must outlive the flush that draws them.
fn deferDestroy(self: *Window, tex: *sdl.SDL_Texture) void {
    if (self.pn >= self.pending.len) {
        self.flushBatch();
        self.drainPending();
    }
    self.pending[self.pn] = tex;
    self.pn += 1;
}

fn drainPending(self: *Window) void {
    for (self.pending[0..self.pn]) |t| {
        if (t) |tex| sdl.destroyTexture(tex);
    }
    self.pn = 0;
}

fn toFColor(c: lu.Color) sdl.SDL_FColor {
    return .{
        .r = @as(f32, @floatFromInt(c.r)) / 255.0,
        .g = @as(f32, @floatFromInt(c.g)) / 255.0,
        .b = @as(f32, @floatFromInt(c.b)) / 255.0,
        .a = @as(f32, @floatFromInt(c.a)) / 255.0,
    };
}

/// Draws an axis-aligned quad into the batch. `dst` is the target rect in world
/// pixels; `src` is the sampled region of the texture in *texture pixels* and
/// is normalized here, matching how textured masks map UVs.
fn emitQuad(self: *Window, tex: ?*sdl.SDL_Texture, dst: sdl.SDL_FRect, src: ?sdl.SDL_FRect, color: sdl.SDL_FColor) void {
    var tu0: f32 = 0;
    var tv0: f32 = 0;
    var tu1: f32 = 1;
    var tv1: f32 = 1;
    if (tex) |t| {
        var tw: f32 = 1;
        var th: f32 = 1;
        _ = sdl.textureSize(t, &tw, &th);
        const s = src orelse sdl.SDL_FRect{ .x = 0, .y = 0, .w = tw, .h = th };
        tu0 = s.x / tw;
        tv0 = s.y / th;
        tu1 = (s.x + s.w) / tw;
        tv1 = (s.y + s.h) / th;
    }
    var verts: [4]sdl.SDL_Vertex = undefined;
    verts[0] = .{ .position = .{ .x = dst.x, .y = dst.y }, .color = color, .tex_coord = .{ .x = tu0, .y = tv0 } };
    verts[1] = .{ .position = .{ .x = dst.x + dst.w, .y = dst.y }, .color = color, .tex_coord = .{ .x = tu1, .y = tv0 } };
    verts[2] = .{ .position = .{ .x = dst.x, .y = dst.y + dst.h }, .color = color, .tex_coord = .{ .x = tu0, .y = tv1 } };
    verts[3] = .{ .position = .{ .x = dst.x + dst.w, .y = dst.y + dst.h }, .color = color, .tex_coord = .{ .x = tu1, .y = tv1 } };
    const indeces = [6]c_int{ 0, 1, 2, 2, 1, 3 };
    self.emitPrim(tex, self.currentClip(), &verts, &indeces);
}

fn bufferFingerprint(pb: lu.PixelBuffer) u64 {
    var h = std.hash.Wyhash.init(0xc0ffee);
    h.update(std.mem.asBytes(&pb.width));
    h.update(std.mem.asBytes(&pb.height));
    h.update(pb.pixels);
    return h.final();
}

fn bufferFitFingerprint(b: lu.Buffer8) u64 {
    var h = std.hash.Wyhash.init(0xc0ffee);
    h.update(std.mem.asBytes(&b.buffer.width));
    h.update(std.mem.asBytes(&b.buffer.height));
    h.update(b.buffer.pixels);
    h.update(std.mem.asBytes(&b.fit));
    h.update(std.mem.asBytes(&b.filter));
    return h.final();
}

/// Hash of the element's geometry plus every gradient setting that changes the
/// baked texture, so a cached gradient bake is reused only while the element
/// keeps the same shape and gradient.
fn gradientFingerprint(g: lu.Gradient, geom: lu.Geometry) u64 {
    var h = std.hash.Wyhash.init(0xdecafbad);
    h.update(std.mem.asBytes(&geom.pos.x));
    h.update(std.mem.asBytes(&geom.pos.y));
    h.update(std.mem.asBytes(&geom.size.w));
    h.update(std.mem.asBytes(&geom.size.h));
    h.update(std.mem.asBytes(&geom.radius.top_left));
    h.update(std.mem.asBytes(&geom.radius.top_right));
    h.update(std.mem.asBytes(&geom.radius.bottom_left));
    h.update(std.mem.asBytes(&geom.radius.bottom_right));
    h.update(std.mem.asBytes(&g.opacity));
    for (g.points) |p| {
        h.update(std.mem.asBytes(&p.x));
        h.update(std.mem.asBytes(&p.y));
        h.update(std.mem.asBytes(&p.color));
    }
    return h.final();
}

/// The texture for a CPU pixel buffer, served from the per-element cache: the
/// first frame uploads the buffer under the element's stable id, later frames
/// reuse the texture (no per-frame create/update/destroy). A changed fingerprint
/// re-uploads. Elements without a stable id (raw container structs) fall back to
/// a transient texture destroyed after the batch flush.
fn elementBufferTexture(self: *Window, e: *lu.Element, pb: lu.PixelBuffer, filter: lu.Filter) ?*sdl.SDL_Texture {
    if (pb.pixels.len == 0 or pb.width == 0 or pb.height == 0) return null;
    const fp = bufferFingerprint(pb);
    if (e.id == 0) {
        const tex = self.uploadBuffer(pb, filter) orelse return null;
        self.deferDestroy(tex);
        return tex;
    }
    const key = lu.Context.cacheKey(e.id, e.id_extra);
    if (self.gpu_cache.getMutable(key)) |entry| {
        entry.last_seen = self.frame;
        if (entry.fingerprint == fp) return entry.texture;
    }
    const tex = self.uploadBuffer(pb, filter) orelse return null;
    if (self.gpu_cache.get(key)) |old| sdl.destroyTexture(old.texture);
    self.gpu_cache.put(key, .{ .texture = tex, .fingerprint = fp, .last_seen = self.frame });
    if (self.gpu_cache.get(key) == null) self.deferDestroy(tex);
    return tex;
}

/// Creates and fills a streaming texture from a pixel buffer.
fn uploadBuffer(self: *Window, pb: lu.PixelBuffer, filter: lu.Filter) ?*sdl.SDL_Texture {
    const tex = sdl.createTexture(
        self.renderer,
        sdl.pixels.SDL_PIXELFORMAT_ABGR8888,
        sdl.SDL_TEXTUREACCESS_STREAMING,
        @intCast(pb.width),
        @intCast(pb.height),
    ) orelse return null;
    _ = sdl.setTextureBlendMode(tex, sdl.SDL_BLENDMODE_BLEND);
    if (filter == .linear)
        _ = sdl.setTextureScaleMode(tex, .SDL_SCALEMODE_LINEAR)
    else
        _ = sdl.setTextureScaleMode(tex, .SDL_SCALEMODE_NEAREST);
    _ = sdl.updateTexture(tex, null, @ptrCast(pb.pixels.ptr), @intCast(pb.width * 4));
    return tex;
}

/// The baked gradient texture for an element, served from the per-element cache
/// keyed by the element id, the gradient and the element's geometry. Like
/// `elementBufferTexture`, elements without a stable id use a transient bake.
fn elementGradientTexture(self: *Window, e: *lu.Element, g: lu.Gradient, geom: lu.Geometry) ?*sdl.SDL_Texture {
    const fp = gradientFingerprint(g, geom);
    if (e.id == 0) {
        const tex = self.gradientTexture(g, geom.size.w, geom.size.h) orelse return null;
        self.deferDestroy(tex);
        return tex;
    }
    const key = lu.Context.cacheKey(e.id, e.id_extra);
    if (self.gpu_cache.getMutable(key)) |entry| {
        entry.last_seen = self.frame;
        if (entry.fingerprint == fp) return entry.texture;
    }
    const tex = self.gradientTexture(g, geom.size.w, geom.size.h) orelse return null;
    if (self.gpu_cache.get(key)) |old| sdl.destroyTexture(old.texture);
    self.gpu_cache.put(key, .{ .texture = tex, .fingerprint = fp, .last_seen = self.frame });
    if (self.gpu_cache.get(key) == null) self.deferDestroy(tex);
    return tex;
}

fn drawElement(self: *Window, e: *lu.Element, area: lu.Area) void {
    // Drop shadows extend outside the element's own box, so draw them before
    // pushing the element clip, with every ancestor clip suspended so a shadow
    // can spill past the parent's content box.
    self.clip_suspend = true;
    self.drawShadows(e, area, .out);
    self.clip_suspend = false;

    self.pushClip(area);
    defer self.popClip();

    self.drawBackground(e, area);
    self.drawBorder(e, area);

    // Inner shadows sit on top of the background, inside the element's box.
    self.drawShadows(e, area, .in);

    const content = contentArea(e, area);
    self.pushClip(content);
    defer self.popClip();

    // Children were sized and positioned by the top-down `lay` pass; their
    // `.pos`/`.size` are already final (world space), so draw them as-is.
    const layout = &(e.layout orelse return);
    if (layout.cindex == 0) return;
    for (0..layout.cindex) |i| {
        const child = layout.children[i];
        self.drawElement(child, .{ .pos = child.pos, .size = child.size });
    }
}

/// Draws every `shadow` effect in `e.effects` whose mask matches `mask`.
fn drawShadows(self: *Window, e: *lu.Element, area: lu.Area, mask: lu.Effect.Shadow.ShadowMask) void {
    const effects = e.effects orelse return;
    for (effects) |effect| {
        switch (effect) {
            .shadow => |sh| if (sh.mask == mask) self.drawShadow(e, area, sh),
            else => {},
        }
    }
}

/// Upper bound on a shadow raster's width or height in pixels. Shadows larger
/// than this (a huge element with a huge blur) are skipped to keep the CPU
/// raster bounded; the example's shadows are well below this.
const max_shadow_edge = 1024;
const max_shadow_pixels = 1 << 20;
/// Cap on distinct box-shadow rasters kept alive at once. Shadows are cheap to
/// re-rasterize, so when this fills we just drop everything and start over.
const max_shadow_cache = 64;

/// One rasterized box shadow in the persistent `shadow_cache`. Shadows are
/// keyed by the shape parameters that determine the pixels, not by the element,
/// so an unchanged shadow (same box, radius, spread, offset, blur, color and
/// mask) is drawn from the cache instead of being re-rasterized and re-uploaded
/// every frame.
const ShadowEntry = struct {
    texture: *sdl.SDL_Texture,
    w: i32,
    h: i32,
    /// Last frame this entry was used; idle entries are evicted.
    last_seen: u64,
};

/// Rasterizes a single box shadow on the CPU and draws it as a texture.
///
/// The shadow is the element's rounded rect, shifted by `x_offset`/`y_offset`
/// and grown by `spread`, filled with the shadow color, then blurred. For
/// `mask = out` the element's own rounded shape is punched out (a strict drop
/// shadow: the shadow never shows over the element, even with a translucent
/// background). For `mask = in` only the inside of the element's rounded shape
/// is kept, which produces the inner-glow look.
///
/// The raster spans the full shape plus the blur margin, so the pixels depend
/// only on the shape and the shadow settings — never on where the element sits.
/// Every shadow is cached (even ones whose blur region reaches a window edge;
/// SDL clips the drawn quad to the render target), keyed by the element's id,
/// its size and border radius, and the shadow parameters.
fn drawShadow(self: *Window, e: *lu.Element, area: lu.Area, sh: lu.Effect.Shadow) void {
    if (area.size.w == 0 or area.size.h == 0) return;
    const ox: i32 = @intFromFloat(@round(sh.x_offset));
    const oy: i32 = @intFromFloat(@round(sh.y_offset));
    const spr: i32 = @intFromFloat(@round(sh.spread));
    const blur: i32 = @intFromFloat(@round(@max(0.0, sh.blur)));
    const color = tint(sh.color, e.effects);

    const iw: i32 = @as(i32, @intCast(area.size.w)) + 2 * spr;
    const ih: i32 = @as(i32, @intCast(area.size.h)) + 2 * spr;
    if (iw <= 0 or ih <= 0) return;

    const margin: i32 = 2 * blur + 2;
    const rw: i32 = iw + 2 * margin;
    const rh: i32 = ih + 2 * margin;
    if (rw > max_shadow_edge or rh > max_shadow_edge) return;
    const n: usize = @as(usize, @intCast(rw)) * @as(usize, @intCast(rh));
    if (n > max_shadow_pixels) return;

    const rr = clampRadius(e.border_radius, iw, ih);
    const key = shadowKey(e, iw, ih, ox, oy, spr, blur, rr, color, sh.mask);
    self.cacheBegin();
    const shadow_entry = self.shadow_cache.getMutable(key);
    if (shadow_entry) |entry| entry.last_seen = self.frame;
    self.cacheEnd();
    if (shadow_entry) |entry| {
        self.drawShadowTexture(
            entry.texture,
            entry.w,
            entry.h,
            @as(i32, @intCast(area.pos.x)) + ox - spr - margin,
            @as(i32, @intCast(area.pos.y)) + oy - spr - margin,
        );
        return;
    }

    const cov = self.scratchAlloc(f32, n) catch return;
    defer self.scratchFree(f32, cov);
    const scratch = self.scratchAlloc(f32, n) catch return;
    defer self.scratchFree(f32, scratch);

    // Shape rect in local raster coords: the raster starts at the top-left of
    // the whole plane (shape minus the blur margin), so the shape sits at the
    // margin inset.
    const sx: i32 = margin;
    const sy: i32 = margin;
    for (0..@as(usize, @intCast(rh))) |y| {
        for (0..@as(usize, @intCast(rw))) |x| {
            const px: i32 = @intCast(x);
            const py: i32 = @intCast(y);
            cov[y * @as(usize, @intCast(rw)) + x] =
                if (inRoundedRect(sx, sy, iw, ih, rr, px, py)) 1.0 else 0.0;
        }
    }

    // Blur the coverage plane (separable box blur, two iterations) to get a
    // smooth gaussian-like falloff.
    if (blur > 0) {
        boxBlur(cov, scratch, @intCast(rw), @intCast(rh), blur);
        boxBlur(scratch, cov, @intCast(rw), @intCast(rh), blur);
    }

    const pixels = self.scratchAlloc(u8, n * 4) catch return;
    defer self.scratchFree(u8, pixels);

    // Element box in local raster coords, for punching / clipping. The
    // punch/keep follows the element's *rounded* silhouette: clipping against a
    // sharp box would carve straight edges across the corners of a rounded
    // element, leaving white triangles where the shadow should hug the curve.
    const ex: i32 = sx + spr - ox;
    const ey: i32 = sy + spr - oy;
    const e_w: i32 = @intCast(area.size.w);
    const e_h: i32 = @intCast(area.size.h);

    const shadow_a: f32 = @as(f32, @floatFromInt(color.a)) / 255.0;
    for (0..@as(usize, @intCast(rh))) |y| {
        for (0..@as(usize, @intCast(rw))) |x| {
            const px: i32 = @intCast(x);
            const py: i32 = @intCast(y);
            const inside_elem = inRoundedRect(ex, ey, e_w, e_h, rr, px, py);
            var a = cov[y * @as(usize, @intCast(rw)) + x] * shadow_a;
            if (sh.mask == .out) {
                if (inside_elem) a = 0;
            } else {
                if (!inside_elem) a = 0;
            }
            const idx = (y * @as(usize, @intCast(rw)) + x) * 4;
            pixels[idx] = color.r;
            pixels[idx + 1] = color.g;
            pixels[idx + 2] = color.b;
            pixels[idx + 3] = @intFromFloat(@min(a * 255.0, 255.0));
        }
    }

    const tex = sdl.createTexture(
        self.renderer,
        sdl.pixels.SDL_PIXELFORMAT_ABGR8888,
        sdl.SDL_TEXTUREACCESS_STREAMING,
        @intCast(rw),
        @intCast(rh),
    ) orelse return;
    _ = sdl.setTextureBlendMode(tex, sdl.SDL_BLENDMODE_BLEND);
    _ = sdl.updateTexture(tex, null, @ptrCast(pixels.ptr), @intCast(rw * 4));

    self.storeShadow(key, tex, rw, rh);
    self.drawShadowTexture(tex, rw, rh, @as(i32, @intCast(area.pos.x)) + ox - spr - margin, @as(i32, @intCast(area.pos.y)) + oy - spr - margin);
}

/// Draws a shadow raster (from the cache or freshly rasterized) at `(rx, ry)`.
fn drawShadowTexture(self: *Window, tex: *sdl.SDL_Texture, rw: i32, rh: i32, rx: i32, ry: i32) void {
    const src = sdl.SDL_FRect{ .x = 0, .y = 0, .w = @floatFromInt(rw), .h = @floatFromInt(rh) };
    const dst = sdl.SDL_FRect{
        .x = @floatFromInt(rx),
        .y = @floatFromInt(ry),
        .w = @floatFromInt(rw),
        .h = @floatFromInt(rh),
    };
    self.emitQuad(tex, dst, src, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
}

/// Stores a shadow raster in the cache, flushing the whole cache when it hits
/// `max_shadow_cache` entries so VRAM stays bounded. The per-frame eviction
/// sweep (`evictStale`) additionally drops shadow textures that go idle.
fn storeShadow(self: *Window, key: u64, tex: *sdl.SDL_Texture, w: i32, h: i32) void {
    if (self.shadow_cache.count() >= max_shadow_cache) {
        var it = self.shadow_cache.iterator();
        while (it.next()) |entry| sdl.destroyTexture(entry.value_ptr.texture);
        self.shadow_cache.clear();
    }
    if (self.shadow_cache.get(key)) |old| sdl.destroyTexture(old.texture);
    self.shadow_cache.put(key, .{ .texture = tex, .w = w, .h = h, .last_seen = self.frame });
}

/// Content key for a shadow raster: the element's stable id, its shape (size
/// and border radius, never its position), and every shadow setting that
/// changes the pixels. Inputs are small so collisions are unlikely; a collision
/// would only make a visually-equal shadow draw in place of the requested one.
fn shadowKey(e: *const lu.Element, iw: i32, ih: i32, ox: i32, oy: i32, spr: i32, blur: i32, rr: i32, color: lu.Color, mask: lu.Effect.Shadow.ShadowMask) u64 {
    var hasher = std.hash.Wyhash.init(0x5ed12a4acf31c1f3);
    const vals = [12]i32{
        iw,         ih,         ox,         oy,
        spr,        blur,       rr,         @as(i32, color.r),
        @as(i32, color.g), @as(i32, color.b), @as(i32, color.a), @intFromEnum(mask),
    };
    hasher.update(std.mem.asBytes(&vals));
    const eid = lu.Context.cacheKey(e.id, e.id_extra);
    hasher.update(std.mem.asBytes(&eid));
    return hasher.final();
}

/// The border radius for a shadow shape, clamped so the corners never exceed
/// half the smaller dimension.
fn clampRadius(corners: lu.Corners, w: i32, h: i32) i32 {
    const max_r: i32 = @divTrunc(@min(w, h), 2);
    var out: i32 = 0;
    const vals = [4]i32{
        @intCast(corners.top_left),
        @intCast(corners.top_right),
        @intCast(corners.bottom_left),
        @intCast(corners.bottom_right),
    };
    for (vals) |v| out = @max(out, @min(v, max_r));
    return out;
}

/// True when `(px, py)` lies inside the axis-aligned rounded rect with origin
/// `(x, y)`, size `w` x `h` and corner radius `r`.
fn inRoundedRect(x: i32, y: i32, w: i32, h: i32, r: i32, px: i32, py: i32) bool {
    if (px < x or py < y or px >= x + w or py >= y + h) return false;
    const rr: i32 = @min(r, @divTrunc(@min(w, h), 2));
    if (rr <= 0) return true;
    // In the middle band, definitely inside.
    if (px >= x + rr and px < x + w - rr) return true;
    if (py >= y + rr and py < y + h - rr) return true;
    // Otherwise check the nearest corner.
    const corners = [4][2]i32{
        .{ x + rr, y + rr },
        .{ x + w - rr - 1, y + rr },
        .{ x + rr, y + h - rr - 1 },
        .{ x + w - rr - 1, y + h - rr - 1 },
    };
    var best: f32 = 1e9;
    for (corners) |c| {
        const dx = @as(f32, @floatFromInt(px - c[0]));
        const dy = @as(f32, @floatFromInt(py - c[1]));
        const d = @sqrt(dx * dx + dy * dy);
        best = @min(best, d);
    }
    return best <= @as(f32, @floatFromInt(rr));
}

/// Separable box blur of `src` into `dst`, both `w` x `h` planes. Each row and
/// column is averaged over a window of `2*radius+1` pixels (clamped at the
/// edges).
fn boxBlur(src: []const f32, dst: []f32, w: usize, h: usize, radius: i32) void {
    const r = @min(@as(i32, @intCast(@max(w, h))), @max(radius, 1));
    const row = std.heap.page_allocator.alloc(f32, w) catch return;
    defer std.heap.page_allocator.free(row);

    // Horizontal pass.
    for (0..h) |y| {
        for (0..w) |x| {
            const lo: i32 = @intCast(x);
            const lo_r = @max(0, lo - r);
            const hi_r = @min(@as(i32, @intCast(w)) - 1, lo + r);
            var sum: f32 = 0;
            var count: f32 = 0;
            var k = lo_r;
            while (k <= hi_r) : (k += 1) {
                sum += src[y * w + @as(usize, @intCast(k))];
                count += 1;
            }
            row[x] = sum / count;
        }
        for (0..w) |x| dst[y * w + x] = row[x];
    }

    // Vertical pass over the horizontally-blurred `dst`.
    const col = std.heap.page_allocator.alloc(f32, h) catch return;
    defer std.heap.page_allocator.free(col);
    for (0..w) |x| {
        for (0..h) |y| {
            const lo_r = @max(0, @as(i32, @intCast(y)) - r);
            const hi_r = @min(@as(i32, @intCast(h)) - 1, @as(i32, @intCast(y)) + r);
            var sum: f32 = 0;
            var count: f32 = 0;
            var k = lo_r;
            while (k <= hi_r) : (k += 1) {
                sum += dst[@as(usize, @intCast(k)) * w + x];
                count += 1;
            }
            col[@intCast(y)] = sum / count;
        }
        for (0..h) |y| dst[y * w + x] = col[y];
    }
}

/// The usable box of an element after removing its border and padding.
fn contentArea(e: *const lu.Element, area: lu.Area) lu.Area {
    const b = e.border;
    const p = e.padding;
    return .{
        .pos = .{
            .x = area.pos.x + b.left + p.left,
            .y = area.pos.y + b.top + p.top,
        },
        .size = .{
            .w = area.size.w -| (b.left + b.right + p.left + p.right),
            .h = area.size.h -| (b.top + b.bottom + p.top + p.bottom),
        },
    };
}

fn drawBackground(self: *Window, e: *lu.Element, area: lu.Area) void {
    const alpha = totalOpacity(e.effects) * totalOpacity(e.background.effects);
    if (hasBlur(e.background.effects))
        self.drawBlurBackdrop(area, e.border_radius, alpha, e.background.effects);
    switch (e.background.base) {
        .solid => |c| {
            self.fillRoundedRect(area, e.border_radius, tint(tint(c, e.effects), e.background.effects));
        },
        .image => |img| self.drawImageBackground(img, area, e.border_radius, alpha),
        .gradient => |g| self.drawGradientBackground(e, g, area, e.border_radius, alpha),
        .buffer => |pb| self.drawBufferBackground(e, pb, area, e.border_radius, alpha),
        .image_buffer => |b| self.drawBufferFitBackground(e, b, area, e.border_radius, alpha),
        .cached => |c| self.drawCachedBackground(c.key, area, e.border_radius, alpha),
    }
}

/// Draws a persistent per-element texture, uploading it from CPU pixels the
/// first time it is seen (the element's first frame) and reusing the texture
/// every frame after.
fn drawCachedBackground(self: *Window, key: u64, area: lu.Area, radius: lu.Corners, alpha: f32) void {
    self.cacheBegin();
    const entry = self.gpu_cache.getMutable(key) orelse {
        self.cacheEnd();
        return;
    };
    entry.last_seen = self.frame;
    var tex_w: f32 = 0;
    var tex_h: f32 = 0;
    _ = sdl.textureSize(entry.texture, &tex_w, &tex_h);
    self.cacheEnd();
    const src = sdl.SDL_FRect{ .x = 0, .y = 0, .w = tex_w, .h = tex_h };
    self.renderMasked(area, radius, entry.texture, src, null, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = alpha });
}

fn drawBorder(self: *Window, e: *lu.Element, area: lu.Area) void {
    const b = e.border;
    if (b.top == 0 and b.bottom == 0 and b.left == 0 and b.right == 0)
        return;

    const bars = [4]lu.Area{
        .{
            .pos = .{ .x = area.pos.x, .y = area.pos.y },
            .size = .{ .w = area.size.w, .h = b.top },
        },
        .{
            .pos = .{ .x = area.pos.x, .y = area.pos.y + area.size.h -| b.bottom },
            .size = .{ .w = area.size.w, .h = b.bottom },
        },
        .{
            .pos = .{ .x = area.pos.x, .y = area.pos.y + b.top },
            .size = .{ .w = b.left, .h = area.size.h -| (b.top + b.bottom) },
        },
        .{
            .pos = .{ .x = area.pos.x + area.size.w -| b.right, .y = area.pos.y + b.top },
            .size = .{ .w = b.right, .h = area.size.h -| (b.top + b.bottom) },
        },
    };

    switch (e.border_color) {
        .gradient => |g| self.drawGradientBorder(e, g, area, &bars),
        .color => |c| {
            const color = tint(tint(c, e.effects), e.background.effects);
            switch (e.background.base) {
                .solid => |bg| {
                    const inner: lu.Area = .{
                        .pos = .{ .x = area.pos.x + b.left, .y = area.pos.y + b.top },
                        .size = .{ .w = area.size.w -| (b.left + b.right), .h = area.size.h -| (b.top + b.bottom) },
                    };
                    self.fillRoundedRect(area, e.border_radius, color);
                    self.fillRoundedRect(inner, e.border_radius, tint(tint(bg, e.effects), e.background.effects));
                },
                .image, .gradient, .buffer, .image_buffer, .cached => {
                    for (bars) |bar| self.fillRect(bar, color);
                },
            }
        },
    }
}

/// Blurs whatever is currently in the backbuffer behind `area` and masks it to
/// `area` with `radius`.
///
/// The element keeps its full footprint even when it extends past the window;
/// the window clip just cuts off whatever sticks outside, so the element never
/// shrinks to fit the window. The blur is computed from a region padded by the
/// blur radius (so content around the element bleeds into its edges), whose
/// size depends only on the element. That region is downsampled by repeatedly
/// halving it, accumulating a smooth, gaussian-like blur, and the texel grid is
/// anchored to the element. Interior texels are therefore pixel-identical no
/// matter the window size; only the thin band actually cut off by a window
/// edge differs (there is no content beyond it).
///
/// The blurred backdrop is cached per element geometry + blur settings, so the
/// expensive framebuffer read and downsample chain run once and the result is
/// reused every frame the element keeps its shape. Anything queued in the batch
/// *before* this blur in painter's order is flushed to the backbuffer first, so
/// the cached result is produced from the same content an immediate draw would
/// see.
fn drawBlurBackdrop(self: *Window, area: lu.Area, radius: lu.Corners, alpha: f32, effects: ?[]const lu.Effect) void {
    var blur_radius: u32 = 8;
    var saturation: f32 = 1.0;
    var found = false;
    for (effects orelse &.{}) |effect| {
        switch (effect) {
            .blur => |b| {
                blur_radius = b.radius;
                saturation = b.saturation;
                found = true;
            },
            .opacity => {},
            .shadow => {},
        }
    }
    if (!found) return;
    if (area.size.w == 0 or area.size.h == 0) return;

    // Padded region, derived purely from the element (independent of the
    // window). When it extends past the window, SDL clamps the source sampling
    // to the edge, which is fine because that part is clipped off anyway.
    const margin: u32 = blur_radius;
    const px = area.pos.x -| margin;
    const py = area.pos.y -| margin;
    const pw = area.size.w + 2 * margin;
    const ph = area.size.h + 2 * margin;

    const geom = lu.Geometry{ .pos = area.pos, .size = area.size, .radius = radius };
    const key = blurKey(geom, blur_radius, saturation);
    self.cacheBegin();
    const blur_entry = self.blur_cache.getMutable(key);
    if (blur_entry) |entry| entry.last_seen = self.frame;
    self.cacheEnd();
    if (blur_entry) |entry| {
        self.emitBlur(area, radius, alpha, entry.texture, entry.w, entry.h, px, py, pw, ph);
        return;
    }

    // The element's clip rect is still on the renderer here (pushed by
    // `drawElement`). The read and the offscreen stamp/downsample chain below
    // render targets whose coordinates differ from window space, so an active
    // clip would carve the mis-mapped element box out of the chain and leave a
    // weird, half-blurred result. Suspend it for the read + chain and restore
    // it once the blurred buffer is produced; the emission that follows queues
    // into the batch under the element clip anyway.
    var saved_clip: sdl.SDL_Rect = undefined;
    const had_clip = sdl.renderClipEnabled(self.renderer);
    if (had_clip) _ = sdl.getRenderClipRect(self.renderer, &saved_clip);
    _ = sdl.setRenderClipRect(self.renderer, null);
    defer if (had_clip) {
        _ = sdl.setRenderClipRect(self.renderer, &saved_clip);
    } else {
        _ = sdl.setRenderClipRect(self.renderer, null);
    };

    // Whatever is queued in the batch belongs *before* this blur in painter's
    // order and must be visible in the framebuffer read below, so flush it now.
    self.flushBatch();

    // Read the whole framebuffer (not just the region): the blur kernel
    // reaches ~blur_radius beyond the element, and reading the whole target
    // keeps whatever content is available even when the element is partially
    // clipped by a window edge.
    const surface = SDL_RenderReadPixels(self.renderer, null) orelse return;
    defer sdl.surface.destroySurface(surface);
    if (saturation != 1.0)
        self.saturateSurface(surface, @min(px, self.size.w -| 1), @min(py, self.size.h -| 1), @min(pw, self.size.w -| px), @min(ph, self.size.h -| py), saturation);
    // Premultiply the alpha into the colors so that downsampling interpolates
    // the colors (bright content bleeds outward) instead of blending them
    // toward the transparent black backdrop.
    _ = sdl.surface.premultiplySurfaceAlpha(surface, false);
    const full = sdl.createTextureFromSurface(self.renderer, surface) orelse return;
    defer sdl.destroyTexture(full);
    _ = sdl.setTextureScaleMode(full, .SDL_SCALEMODE_LINEAR);
    _ = sdl.setTextureBlendMode(full, sdl.pixels.SDL_BLENDMODE_BLEND_PREMULTIPLIED);

    // Stamp the full padded region at 1:1 into its own `pw` by `ph` texture so
    // the blur chain never samples a sub-rect that pokes outside the window
    // texture (which would make SDL clamp it and shift the texel grid). Only
    // the in-window part is real; the rest is left transparent and is clipped
    // out at draw time. This keeps the grid anchored to the element.
    const pw_i: c_int = @intCast(pw);
    const ph_i: c_int = @intCast(ph);
    const t0 = sdl.createTexture(self.renderer, surface.format, sdl.SDL_TEXTUREACCESS_TARGET, pw_i, ph_i) orelse return;
    _ = sdl.setTextureScaleMode(t0, .SDL_SCALEMODE_LINEAR);
    _ = sdl.setTextureBlendMode(t0, sdl.pixels.SDL_BLENDMODE_BLEND_PREMULTIPLIED);
    _ = sdl.setRenderTarget(self.renderer, t0);
    _ = sdl.setRenderDrawBlendMode(self.renderer, sdl.SDL_BLENDMODE_BLEND);
    _ = sdl.setRenderDrawColor(self.renderer, 0, 0, 0, 0);
    _ = sdl.renderClear(self.renderer);
    const avail_w = @min(pw, self.size.w -| px);
    const avail_h = @min(ph, self.size.h -| py);
    if (avail_w > 0 and avail_h > 0) {
        const isrc = sdl.SDL_FRect{
            .x = @floatFromInt(px),
            .y = @floatFromInt(py),
            .w = @floatFromInt(avail_w),
            .h = @floatFromInt(avail_h),
        };
        const idst = sdl.SDL_FRect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(avail_w),
            .h = @floatFromInt(avail_h),
        };
        _ = sdl.renderTexture(self.renderer, full, &isrc, &idst);
    }
    _ = sdl.setRenderTarget(self.renderer, null);

    // Progressively halve the padded region until each texel covers about the
    // blur factor in screen pixels. Each halving is a linear box filter, so
    // the chain accumulates a smooth blur rather than one harsh downsample.
    const factor = blurFactor(blur_radius);
    var levels: usize = 0;
    var f: u32 = factor;
    while (f > 1) : (f >>= 1) levels += 1;

    var chain: [6]*sdl.SDL_Texture = undefined;
    chain[0] = t0;
    var count: usize = 1;

    var prev: *sdl.SDL_Texture = t0;
    var prev_w: u32 = pw;
    var prev_h: u32 = ph;
    var level: usize = 0;
    while (level < levels) : (level += 1) {
        const w: c_int = @intCast(@max(@as(u32, 1), prev_w / 2));
        const h: c_int = @intCast(@max(@as(u32, 1), prev_h / 2));
        const tex = sdl.createTexture(self.renderer, surface.format, sdl.SDL_TEXTUREACCESS_TARGET, w, h) orelse return;
        _ = sdl.setTextureScaleMode(tex, .SDL_SCALEMODE_LINEAR);
        _ = sdl.setTextureBlendMode(tex, sdl.pixels.SDL_BLENDMODE_BLEND_PREMULTIPLIED);
        _ = sdl.setRenderTarget(self.renderer, tex);
        _ = sdl.setRenderDrawBlendMode(self.renderer, sdl.SDL_BLENDMODE_BLEND);
        _ = sdl.setRenderDrawColor(self.renderer, 0, 0, 0, 0);
        _ = sdl.renderClear(self.renderer);
        const src = sdl.SDL_FRect{ .x = 0, .y = 0, .w = @floatFromInt(prev_w), .h = @floatFromInt(prev_h) };
        const dst = sdl.SDL_FRect{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) };
        _ = sdl.renderTexture(self.renderer, prev, &src, &dst);
        chain[count] = tex;
        count += 1;
        prev = tex;
        prev_w = @intCast(w);
        prev_h = @intCast(h);
    }
    _ = sdl.setRenderTarget(self.renderer, null);

    // The final texture becomes the cached backdrop; the 1:1 stamp and the
    // downsample intermediates are torn down here. If the put fails (cache full)
    // the final texture is queued for destruction after the batch flush instead.
    self.cacheBegin();
    if (self.blur_cache.get(key)) |old| sdl.destroyTexture(old.texture);
    self.blur_cache.put(key, .{ .texture = prev, .w = prev_w, .h = prev_h, .last_seen = self.frame });
    if (self.blur_cache.get(key) == null) self.deferDestroy(prev);
    self.cacheEnd();
    for (chain[0 .. count - 1]) |tex| sdl.destroyTexture(tex);

    self.emitBlur(area, radius, alpha, prev, prev_w, prev_h, px, py, pw, ph);
}

/// Cache key for a blurred backdrop: the element geometry (position, size and
/// corner radius — the pixels really do depend on where the element sits, since
/// the blur samples the background behind it) plus the blur settings that change
/// the pixels. Saturation only reshapes the source colors before the chain runs.
fn blurKey(geom: lu.Geometry, blur_radius: u32, saturation: f32) u64 {
    var hasher = std.hash.Wyhash.init(0x4711d00d);
    hasher.update(std.mem.asBytes(&geom.pos.x));
    hasher.update(std.mem.asBytes(&geom.pos.y));
    hasher.update(std.mem.asBytes(&geom.size.w));
    hasher.update(std.mem.asBytes(&geom.size.h));
    hasher.update(std.mem.asBytes(&geom.radius.top_left));
    hasher.update(std.mem.asBytes(&geom.radius.top_right));
    hasher.update(std.mem.asBytes(&geom.radius.bottom_left));
    hasher.update(std.mem.asBytes(&geom.radius.bottom_right));
    hasher.update(std.mem.asBytes(&blur_radius));
    hasher.update(std.mem.asBytes(&saturation));
    return hasher.final();
}

/// Emits the masked blur draw from a cached (or freshly computed) blur texture,
/// deriving the source rectangle from the element geometry the same way the
/// downsample chain is anchored: the final texture covers the padded region, so
/// the element rect maps to the inner `pw` by `ph` at the padded offset.
fn emitBlur(self: *Window, area: lu.Area, radius: lu.Corners, alpha: f32, tex: *sdl.SDL_Texture, prev_w: u32, prev_h: u32, px: u32, py: u32, pw: u32, ph: u32) void {
    const tw: f32 = @floatFromInt(prev_w);
    const th: f32 = @floatFromInt(prev_h);
    const scale_x = tw / @as(f32, @floatFromInt(pw));
    const scale_y = th / @as(f32, @floatFromInt(ph));
    const src = sdl.SDL_FRect{
        .x = @as(f32, @floatFromInt(area.pos.x - px)) * scale_x,
        .y = @as(f32, @floatFromInt(area.pos.y - py)) * scale_y,
        .w = @as(f32, @floatFromInt(area.size.w)) * scale_x,
        .h = @as(f32, @floatFromInt(area.size.h)) * scale_y,
    };
    self.renderMasked(area, radius, tex, src, null, .{ .r = alpha, .g = alpha, .b = alpha, .a = alpha });
}

fn drawImageBackground(self: *Window, img: lu.Image, area: lu.Area, radius: lu.Corners, alpha: f32) void {
    const tex = self.texture(img.id) orelse return;
    _ = sdl.setTextureBlendMode(tex, sdl.SDL_BLENDMODE_BLEND);
    var tex_w: f32 = 0;
    var tex_h: f32 = 0;
    _ = sdl.textureSize(tex, &tex_w, &tex_h);
    const src: sdl.SDL_FRect = if (img.src) |s|
        .{
            .x = @floatFromInt(s.pos.x),
            .y = @floatFromInt(s.pos.y),
            .w = @floatFromInt(s.size.w),
            .h = @floatFromInt(s.size.h),
        }
    else
        .{ .x = 0, .y = 0, .w = tex_w, .h = tex_h };
    self.renderMasked(area, radius, tex, src, null, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = alpha });
}

/// Draws a CPU pixel buffer as the background. The buffer's texture is served
/// from the per-element cache (see `elementBufferTexture`), so a label or image
/// drawn from a buffer is uploaded once and reused instead of being re-uploaded
/// every frame.
fn drawBufferBackground(self: *Window, e: *lu.Element, pb: lu.PixelBuffer, area: lu.Area, radius: lu.Corners, alpha: f32) void {
    if (pb.pixels.len == 0 or pb.width == 0 or pb.height == 0) return;
    const tex = self.elementBufferTexture(e, pb, .linear) orelse return;
    var tex_w: f32 = 0;
    var tex_h: f32 = 0;
    _ = sdl.textureSize(tex, &tex_w, &tex_h);
    const src = sdl.SDL_FRect{ .x = 0, .y = 0, .w = tex_w, .h = tex_h };
    self.renderMasked(area, radius, tex, src, null, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = alpha });
}

/// Draws a decoded RGBA buffer into `area`, scaled according to `b.fit`. Like
/// `drawBufferBackground`, the texture is cached per element id.
fn drawBufferFitBackground(self: *Window, e: *lu.Element, b: lu.Buffer8, area: lu.Area, radius: lu.Corners, alpha: f32) void {
    if (b.buffer.pixels.len == 0 or b.buffer.width == 0 or b.buffer.height == 0) return;
    const tex = self.elementBufferTexture(e, b.buffer, b.filter) orelse return;

    const dst = fitRect(b.fit, area, @floatFromInt(b.buffer.width), @floatFromInt(b.buffer.height));
    const src = sdl.SDL_FRect{ .x = 0, .y = 0, .w = @floatFromInt(b.buffer.width), .h = @floatFromInt(b.buffer.height) };
    self.renderMasked(dst, radius, tex, src, null, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = alpha });
}

/// The sub-area of `area` that an image of `iw` x `ih` covers under `fit`.
fn fitRect(fit: lu.ImageFit, area: lu.Area, iw: f32, ih: f32) lu.Area {
    if (fit == .stretch) return area;
    const aw: f32 = @floatFromInt(area.size.w);
    const ah: f32 = @floatFromInt(area.size.h);
    if (aw == 0 or ah == 0 or iw == 0 or ih == 0) return area;
    const ar = iw / ih;
    const ar_area = aw / ah;
    const cover = fit == .cover;
    var dw: f32 = aw;
    var dh: f32 = ah;
    // contain: scale to the dimension that limits; cover: the one that overflows.
    if ((ar > ar_area) == cover) {
        dh = aw / ar;
    } else {
        dw = ah * ar;
    }
    const dx = @max(0.0, (aw - dw) / 2.0);
    const dy = @max(0.0, (ah - dh) / 2.0);
    return .{
        .pos = .{
            .x = area.pos.x + @as(u32, @intFromFloat(@floor(dx))),
            .y = area.pos.y + @as(u32, @intFromFloat(@floor(dy))),
        },
        .size = .{
            .w = @max(1, @as(u32, @intFromFloat(@ceil(dw)))),
            .h = @max(1, @as(u32, @intFromFloat(@ceil(dh)))),
        },
    };
}

/// Draws `g` as the background of `area`, masked to `radius`. The bake is served
/// from the per-element cache so it is not re-rasterized (and re-rendered into a
/// target texture) every frame.
fn drawGradientBackground(self: *Window, e: *lu.Element, g: lu.Gradient, area: lu.Area, radius: lu.Corners, alpha: f32) void {
    if (area.size.w == 0 or area.size.h == 0 or g.points.len == 0) return;
    const geom = e.geometry(area);
    const tex = self.elementGradientTexture(e, g, geom) orelse return;
    var tex_w: f32 = 0;
    var tex_h: f32 = 0;
    _ = sdl.textureSize(tex, &tex_w, &tex_h);
    const src = sdl.SDL_FRect{ .x = 0, .y = 0, .w = tex_w, .h = tex_h };
    self.renderMasked(area, radius, tex, src, null, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = alpha });
}

/// Draws `g` over the border bars. The gradient coordinates are relative to
/// `area`, the smallest rectangle containing every border shape.
fn drawGradientBorder(self: *Window, e: *lu.Element, g: lu.Gradient, area: lu.Area, bars: []const lu.Area) void {
    if (area.size.w == 0 or area.size.h == 0 or g.points.len == 0) return;
    const geom = e.geometry(area);
    const tex = self.elementGradientTexture(e, g, geom) orelse return;
    _ = sdl.setTextureBlendMode(tex, sdl.SDL_BLENDMODE_BLEND);
    var tex_w: f32 = 0;
    var tex_h: f32 = 0;
    _ = sdl.textureSize(tex, &tex_w, &tex_h);
    const sx = tex_w / @as(f32, @floatFromInt(area.size.w));
    const sy = tex_h / @as(f32, @floatFromInt(area.size.h));
    for (bars) |bar| {
        if (bar.size.w == 0 or bar.size.h == 0) continue;
        const src = sdl.SDL_FRect{
            .x = @as(f32, @floatFromInt(bar.pos.x - area.pos.x)) * sx,
            .y = @as(f32, @floatFromInt(bar.pos.y - area.pos.y)) * sy,
            .w = @as(f32, @floatFromInt(bar.size.w)) * sx,
            .h = @as(f32, @floatFromInt(bar.size.h)) * sy,
        };
        const dst = sdl.SDL_FRect{
            .x = @floatFromInt(bar.pos.x),
            .y = @floatFromInt(bar.pos.y),
            .w = @floatFromInt(bar.size.w),
            .h = @floatFromInt(bar.size.h),
        };
        self.emitQuad(tex, dst, src, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
    }
}

/// Bakes `g` into an RGBA texture spanning the drawing area. The texture is
/// capped at `max_gradient_size` per side and stretched to the area when drawn.
fn gradientTexture(self: *Window, g: lu.Gradient, w: u32, h: u32) ?*sdl.SDL_Texture {
    const scale = @min(1.0, max_gradient_size / @max(@as(f32, @floatFromInt(w)), @as(f32, @floatFromInt(h))));
    const tw: c_int = @intFromFloat(@max(1.0, @as(f32, @floatFromInt(w)) * scale));
    const th: c_int = @intFromFloat(@max(1.0, @as(f32, @floatFromInt(h)) * scale));

    const tex = sdl.createTexture(self.renderer, sdl.pixels.SDL_PIXELFORMAT_RGBA8888, sdl.SDL_TEXTUREACCESS_TARGET, tw, th) orelse return null;
    _ = sdl.setTextureBlendMode(tex, sdl.SDL_BLENDMODE_BLEND);
    _ = sdl.setTextureScaleMode(tex, .SDL_SCALEMODE_LINEAR);

    _ = sdl.setRenderTarget(self.renderer, tex);
    defer _ = sdl.setRenderTarget(self.renderer, null);
    _ = sdl.setRenderDrawBlendMode(self.renderer, sdl.SDL_BLENDMODE_BLEND);
    _ = sdl.setRenderDrawColor(self.renderer, 0, 0, 0, 0);
    _ = sdl.renderClear(self.renderer);

    const cell: f32 = 16.0;
    const nx = @max(2, @min(gradient_cells_max, @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(tw)) / cell)))));
    const ny = @max(2, @min(gradient_cells_max, @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(th)) / cell)))));

    var verts: [gradient_verts_max]sdl.SDL_Vertex = undefined;
    var indices: [gradient_indices_max]c_int = undefined;

    var nv: usize = 0;
    for (0..ny + 1) |iy| {
        const py = @as(f32, @floatFromInt(iy)) / @as(f32, @floatFromInt(ny));
        for (0..nx + 1) |ix| {
            const px = @as(f32, @floatFromInt(ix)) / @as(f32, @floatFromInt(nx));
            verts[nv] = .{
                .position = .{ .x = px * @as(f32, @floatFromInt(tw)), .y = py * @as(f32, @floatFromInt(th)) },
                .color = gradientColor(g, px, py),
                .tex_coord = .{ .x = 0, .y = 0 },
            };
            nv += 1;
        }
    }

    var ni: usize = 0;
    for (0..ny) |iy| {
        for (0..nx) |ix| {
            const tl = iy * (nx + 1) + ix;
            const tr = tl + 1;
            const bl = tl + (nx + 1);
            const br = bl + 1;
            indices[ni] = @intCast(tl);
            indices[ni + 1] = @intCast(bl);
            indices[ni + 2] = @intCast(tr);
            indices[ni + 3] = @intCast(tr);
            indices[ni + 4] = @intCast(bl);
            indices[ni + 5] = @intCast(br);
            ni += 6;
        }
    }

    _ = sdl.renderGeometry(self.renderer, null, &verts, @intCast(nv), &indices, @intCast(ni));
    return tex;
}

/// The color at normalized position (x, y) of `g`, inverse-distance weighted
/// across every point. Each point's alpha is multiplied by `g.opacity`.
fn gradientColor(g: lu.Gradient, x: f32, y: f32) sdl.SDL_FColor {
    var weight_sum: f32 = 0;
    var r: f32 = 0;
    var gg: f32 = 0;
    var b: f32 = 0;
    var a: f32 = 0;
    for (g.points) |p| {
        const dx = x - p.x;
        const dy = y - p.y;
        const d2 = dx * dx + dy * dy;
        if (d2 < 1e-9) {
            return .{
                .r = @as(f32, @floatFromInt(p.color.r)) / 255.0,
                .g = @as(f32, @floatFromInt(p.color.g)) / 255.0,
                .b = @as(f32, @floatFromInt(p.color.b)) / 255.0,
                .a = @as(f32, @floatFromInt(p.color.a)) / 255.0 * g.opacity,
            };
        }
        const w = 1.0 / (d2 + 1e-6);
        weight_sum += w;
        r += w * @as(f32, @floatFromInt(p.color.r));
        gg += w * @as(f32, @floatFromInt(p.color.g));
        b += w * @as(f32, @floatFromInt(p.color.b));
        a += w * @as(f32, @floatFromInt(p.color.a)) * g.opacity;
    }
    const inv = 1.0 / weight_sum;
    return .{
        .r = r * inv / 255.0,
        .g = gg * inv / 255.0,
        .b = b * inv / 255.0,
        .a = a * inv / 255.0,
    };
}

/// Multiplies the alpha channel of `color` by the `opacity` effect value.
fn tint(color: lu.Color, effects: ?[]const lu.Effect) lu.Color {
    var out = color;
    for (effects orelse &.{}) |effect| {
        switch (effect) {
            .opacity => |o| {
                out.a = @intFromFloat(@min(@as(f64, @floatFromInt(out.a)) * o, 255.0));
            },
            .blur => {},
            .shadow => {},
        }
    }
    return out;
}

/// The product of all `opacity` effects in `effects`, blur is transparent.
fn totalOpacity(effects: ?[]const lu.Effect) f32 {
    var out: f32 = 1.0;
    for (effects orelse &.{}) |effect| {
        switch (effect) {
            .opacity => |o| out *= @floatCast(o),
            .blur => {},
            .shadow => {},
        }
    }
    return out;
}

fn hasBlur(effects: ?[]const lu.Effect) bool {
    for (effects orelse &.{}) |effect| {
        switch (effect) {
            .blur => return true,
            .opacity => {},
            .shadow => {},
        }
    }
    return false;
}

/// The downsample factor (`2^level`) whose size best matches `radius`.
fn blurFactor(radius: u32) u32 {
    var level: usize = 0;
    var r = @max(radius, 1);
    while (r > 1 and level + 1 < max_blur_levels) : (r >>= 1) level += 1;
    return @as(u32, 1) << @intCast(level);
}

/// Adjusts the saturation of `surface`'s pixels inside the given region (in
/// surface coordinates). `saturation` follows CSS `saturate()`: 1.0 is
/// unchanged, 0.0 is grayscale, above 1.0 boosts the color.
fn saturateSurface(self: *Window, surface: *Surface, x: u32, y: u32, w: u32, h: u32, saturation: f32) void {
    if (w == 0 or h == 0) return;
    const win_w: c_int = @intCast(self.size.w);
    const win_h: c_int = @intCast(self.size.h);
    const surf_w = @min(win_w, surface.w);
    const surf_h = @min(win_h, surface.h);
    for (0..h) |oy| {
        const sy: c_int = @intCast(@min(y + oy, @as(u32, @intCast(win_h -| 1))));
        if (sy >= surf_h) break;
        for (0..w) |ox| {
            const sx: c_int = @intCast(@min(x + ox, @as(u32, @intCast(win_w -| 1))));
            if (sx >= surf_w) continue;
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            var a: f32 = 0;
            if (!sdl.surface.readSurfacePixelFloat(surface, sx, sy, &r, &g, &b, &a)) continue;
            const luma = r * 0.2126 + g * 0.7152 + b * 0.0722;
            r = luma + (r - luma) * saturation;
            g = luma + (g - luma) * saturation;
            b = luma + (b - luma) * saturation;
            _ = sdl.surface.writeSurfacePixelFloat(surface, sx, sy, r, g, b, a);
        }
    }
}

fn fillRect(self: *Window, area: lu.Area, color: lu.Color) void {
    if (area.size.w == 0 or area.size.h == 0) return;
    self.emitQuad(null, .{
        .x = @floatFromInt(area.pos.x),
        .y = @floatFromInt(area.pos.y),
        .w = @floatFromInt(area.size.w),
        .h = @floatFromInt(area.size.h),
    }, null, toFColor(color));
}

/// Fills a rectangle with rounded corners using a triangle fan.
fn fillRoundedRect(self: *Window, area: lu.Area, radius: lu.Corners, color: lu.Color) void {
    if (area.size.w == 0 or area.size.h == 0) return;
    self.renderMasked(
        area,
        radius,
        null,
        undefined,
        null,
        .{
            .r = @as(f32, @floatFromInt(color.r)) / 255.0,
            .g = @as(f32, @floatFromInt(color.g)) / 255.0,
            .b = @as(f32, @floatFromInt(color.b)) / 255.0,
            .a = @as(f32, @floatFromInt(color.a)) / 255.0,
        },
    );
}

/// Renders the rounded-rect mask of `area`, sampling `tex` (or the given
/// color when `tex` is null) inside it.
///
/// When `screen` is null, `src` is the region of the texture, in texture
/// pixels, that maps onto `area`. When `screen` is set (a backdrop texture that
/// spans the whole render output, like the blur chain), `src` is ignored and
/// UVs are computed in screen space.
fn renderMasked(
    self: *Window,
    area: lu.Area,
    radius: lu.Corners,
    tex: ?*sdl.SDL_Texture,
    src: sdl.SDL_FRect,
    screen: ?lu.Rect,
    color: sdl.SDL_FColor,
) void {
    if (area.size.w == 0 or area.size.h == 0) return;
    if (radius.top_left == 0 and radius.top_right == 0 and radius.bottom_left == 0 and radius.bottom_right == 0) {
        if (tex == null) {
            self.fillRect(area, colorFromF(color));
            return;
        }
    }

    var verts: [mask_verts]sdl.SDL_Vertex = undefined;
    const n = buildMask(area, radius, &verts);
    const segs = n - 1;

    if (tex) |t| {
        var tex_w: f32 = 1;
        var tex_h: f32 = 1;
        _ = sdl.textureSize(t, &tex_w, &tex_h);
        const ax: f32 = @floatFromInt(area.pos.x);
        const ay: f32 = @floatFromInt(area.pos.y);
        const aw: f32 = @floatFromInt(area.size.w);
        const ah: f32 = @floatFromInt(area.size.h);
        if (screen) |ss| {
            const sw: f32 = @floatFromInt(ss.w);
            const sh: f32 = @floatFromInt(ss.h);
            for (verts[0..n]) |*v| {
                v.tex_coord = .{
                    .x = @min(v.position.x / sw, 0.9999),
                    .y = @min(v.position.y / sh, 0.9999),
                };
            }
        } else {
            for (verts[0..n]) |*v| {
                v.tex_coord = .{
                    .x = (src.x + (v.position.x - ax) * (src.w / aw)) / tex_w,
                    .y = (src.y + (v.position.y - ay) * (src.h / ah)) / tex_h,
                };
            }
        }
    }

    for (verts[0..n]) |*v| v.color = color;

    var indices: [mask_indices]c_int = undefined;
    for (0..segs) |k| {
        indices[k * 3 + 0] = 0;
        indices[k * 3 + 1] = @intCast(k + 1);
        indices[k * 3 + 2] = @intCast(if (k + 2 > segs) 1 else k + 2);
    }

    // Everything routes through the per-frame batch so the whole frame (shadows,
    // fills, textures, blur) draws in one pass in painter's order.
    self.emitPrim(tex, self.currentClip(), verts[0..n], indices[0 .. segs * 3]);
}

/// Builds the rounded-rect triangle fan for `area` into `verts`, returning the
/// number of vertices. `verts[0]` is the center, the rest trace the outline.
fn buildMask(area: lu.Area, radius: lu.Corners, verts: *[mask_verts]sdl.SDL_Vertex) usize {
    const segs = mask_segs;

    const w: f32 = @floatFromInt(area.size.w);
    const h: f32 = @floatFromInt(area.size.h);
    const cx: f32 = @as(f32, @floatFromInt(area.pos.x)) + w / 2.0;
    const cy: f32 = @as(f32, @floatFromInt(area.pos.y)) + h / 2.0;
    const hw = w / 2.0;
    const hh = h / 2.0;
    const max_r = @min(hw, hh);

    const corner_radius = [4]f32{
        @min(@as(f32, @floatFromInt(radius.bottom_right)), max_r),
        @min(@as(f32, @floatFromInt(radius.bottom_left)), max_r),
        @min(@as(f32, @floatFromInt(radius.top_left)), max_r),
        @min(@as(f32, @floatFromInt(radius.top_right)), max_r),
    };
    const sign_x = [4]f32{ 1, -1, -1, 1 };
    const sign_y = [4]f32{ 1, 1, -1, -1 };
    const start_deg = [4]f32{ 0.0, 90.0, 180.0, 270.0 };

    verts[0] = .{
        .position = .{ .x = cx, .y = cy },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .tex_coord = .{ .x = 0, .y = 0 },
    };

    var v: usize = 1;
    for (0..4) |corner| {
        const r = corner_radius[corner];
        const sx = sign_x[corner];
        const sy = sign_y[corner];
        for (0..segs) |seg| {
            const t = @as(f32, @floatFromInt(seg)) / @as(f32, @floatFromInt(segs));
            const angle = (start_deg[corner] + t * 90.0) * std.math.pi / 180.0;
            verts[v] = .{
                .position = .{
                    .x = cx + sx * (hw - r) + r * @cos(angle),
                    .y = cy + sy * (hh - r) + r * @sin(angle),
                },
                .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
                .tex_coord = .{ .x = 0, .y = 0 },
            };
            v += 1;
        }
    }
    return v;
}

fn colorFromF(c: sdl.SDL_FColor) lu.Color {
    return .{
        .r = @intFromFloat(@min(c.r * 255.0, 255.0)),
        .g = @intFromFloat(@min(c.g * 255.0, 255.0)),
        .b = @intFromFloat(@min(c.b * 255.0, 255.0)),
        .a = @intFromFloat(@min(c.a * 255.0, 255.0)),
    };
}
