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

const max_textures = 1024;
const max_clips = 64;
/// Max blur downsample exponent: blur factor is `2^level`, `level` capped here.
const max_blur_levels = 5;

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
pub fn render(self: *Window, root: lu.Element) void {
    _ = sdl.getWindowSize(
        self.window,
        @ptrCast(&self.size.w),
        @ptrCast(&self.size.h),
    );
    self.drawElement(root, .{ .pos = root.pos, .size = root.size });
}

fn drawElement(self: *Window, e: lu.Element, area: lu.Area) void {
    self.pushClip(area);
    defer self.popClip();

    self.drawBackground(e, area);
    self.drawBorder(e, area);

    const content = contentArea(e, area);
    self.pushClip(content);
    defer self.popClip();

    for (e.layout.lay()) |item| {
        var child_area = item.area;
        child_area.pos.x += content.pos.x;
        child_area.pos.y += content.pos.y;
        self.drawElement(item.node, child_area);
    }
}

/// The usable box of an element after removing its border and padding.
fn contentArea(e: lu.Element, area: lu.Area) lu.Area {
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

fn drawBackground(self: *Window, e: lu.Element, area: lu.Area) void {
    const alpha = totalOpacity(e.effects) * totalOpacity(e.background.effects);
    if (hasBlur(e.background.effects))
        self.drawBlurBackdrop(area, e.border_radius, alpha, e.background.effects);
    switch (e.background.base) {
        .solid => |c| {
            self.fillRoundedRect(area, e.border_radius, tint(tint(c, e.effects), e.background.effects));
        },
        .image => |img| self.drawImageBackground(img, area, e.border_radius, alpha),
        .gradient => |g| self.drawGradientBackground(g, area, e.border_radius, alpha),
        .buffer => |pb| self.drawBufferBackground(pb, area, e.border_radius, alpha),
    }
}

fn drawBorder(self: *Window, e: lu.Element, area: lu.Area) void {
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
        .gradient => |g| self.drawGradientBorder(g, area, &bars),
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
                .image, .gradient, .buffer => {
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
fn drawBlurBackdrop(self: *Window, area: lu.Area, radius: lu.Corners, alpha: f32, effects: ?[]const lu.Effect) void {
    var blur_radius: u32 = 8;
    var found = false;
    for (effects orelse &.{}) |effect| {
        switch (effect) {
            .blur => |b| {
                blur_radius = b.radius;
                found = true;
            },
            .opacity => {},
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

    // Read the whole framebuffer (not just the region): the blur kernel
    // reaches ~blur_radius beyond the element, and reading the whole target
    // keeps whatever content is available even when the element is partially
    // clipped by a window edge.
    const surface = SDL_RenderReadPixels(self.renderer, null) orelse return;
    defer sdl.surface.destroySurface(surface);
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
    defer for (chain[1..count]) |tex| sdl.destroyTexture(tex);

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

    // Draw the full element rect from the final texture, masked to `radius`.
    // The window clip cuts off whatever sticks outside; the element itself
    // never shrinks. The texture is premultiplied, so modulate rgb by `alpha`
    // too to keep the premultiplied colors consistent when effects reduce
    // opacity.
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
    self.renderMasked(
        area,
        radius,
        prev,
        src,
        null,
        .{ .r = alpha, .g = alpha, .b = alpha, .a = alpha },
    );
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

/// Uploads a CPU pixel buffer to an SDL texture and draws it as the background.
fn drawBufferBackground(self: *Window, pb: lu.PixelBuffer, area: lu.Area, radius: lu.Corners, alpha: f32) void {
    if (pb.pixels.len == 0 or pb.width == 0 or pb.height == 0) return;
    const tex = sdl.createTexture(
        self.renderer,
        sdl.pixels.SDL_PIXELFORMAT_ABGR8888,
        sdl.SDL_TEXTUREACCESS_STREAMING,
        @intCast(pb.width),
        @intCast(pb.height),
    ) orelse return;
    defer sdl.destroyTexture(tex);

    _ = sdl.setTextureBlendMode(tex, sdl.SDL_BLENDMODE_BLEND);
    _ = sdl.updateTexture(tex, null, @ptrCast(pb.pixels.ptr), @intCast(pb.width * 4));

    var tex_w: f32 = 0;
    var tex_h: f32 = 0;
    _ = sdl.textureSize(tex, &tex_w, &tex_h);
    const src = sdl.SDL_FRect{ .x = 0, .y = 0, .w = tex_w, .h = tex_h };
    self.renderMasked(area, radius, tex, src, null, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = alpha });
}

/// Draws `g` as the background of `area`, masked to `radius`.
fn drawGradientBackground(self: *Window, g: lu.Gradient, area: lu.Area, radius: lu.Corners, alpha: f32) void {
    if (area.size.w == 0 or area.size.h == 0 or g.points.len == 0) return;
    const tex = self.gradientTexture(g, area.size.w, area.size.h) orelse return;
    defer sdl.destroyTexture(tex);
    var tex_w: f32 = 0;
    var tex_h: f32 = 0;
    _ = sdl.textureSize(tex, &tex_w, &tex_h);
    const src = sdl.SDL_FRect{ .x = 0, .y = 0, .w = tex_w, .h = tex_h };
    self.renderMasked(area, radius, tex, src, null, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = alpha });
}

/// Draws `g` over the border bars. The gradient coordinates are relative to
/// `area`, the smallest rectangle containing every border shape.
fn drawGradientBorder(self: *Window, g: lu.Gradient, area: lu.Area, bars: []const lu.Area) void {
    if (area.size.w == 0 or area.size.h == 0 or g.points.len == 0) return;
    const tex = self.gradientTexture(g, area.size.w, area.size.h) orelse return;
    defer sdl.destroyTexture(tex);
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
        _ = sdl.renderTexture(self.renderer, tex, &src, &dst);
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
        }
    }
    return out;
}

fn hasBlur(effects: ?[]const lu.Effect) bool {
    for (effects orelse &.{}) |effect| {
        switch (effect) {
            .blur => return true,
            .opacity => {},
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

fn fillRect(self: *Window, area: lu.Area, color: lu.Color) void {
    if (area.size.w == 0 or area.size.h == 0) return;
    _ = sdl.setRenderDrawBlendMode(self.renderer, sdl.SDL_BLENDMODE_BLEND);
    _ = sdl.setRenderDrawColor(self.renderer, color.r, color.g, color.b, color.a);
    const rect = sdl.SDL_FRect{
        .x = @floatFromInt(area.pos.x),
        .y = @floatFromInt(area.pos.y),
        .w = @floatFromInt(area.size.w),
        .h = @floatFromInt(area.size.h),
    };
    _ = sdl.renderFillRect(self.renderer, &rect);
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

    _ = sdl.setRenderDrawBlendMode(self.renderer, sdl.SDL_BLENDMODE_BLEND);
    _ = sdl.renderGeometry(self.renderer, tex, &verts, @intCast(n), &indices, @intCast(indices.len));
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
