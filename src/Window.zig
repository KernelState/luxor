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

pub const ObjectId = u64;

pub const Texture = struct {
    texture: *sdl.SDL_Texture,
    id: ObjectId,

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
    if (config.decorated)
        flags |= sdl.SDL_WINDOW_BORDERLESS;
    if (config.transparent)
        flags |= sdl.video.SDL_WINDOW_TRANSPARENT;
    var self = Window{
        .transparent = (flags ^ sdl.video.SDL_WINDOW_TRANSPARENT != 0),
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
pub fn render(self: *Window, root: lu.Element) void {
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
        self.drawElement(item.node, item.area);
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
    switch (e.background.base) {
        .solid => |c| {
            self.fillRoundedRect(area, e.border_radius, tint(tint(c, &e.effects), e.background.effects));
        },
        .image, .gradient => {},
    }
}

fn drawBorder(self: *Window, e: lu.Element, area: lu.Area) void {
    const b = e.border;
    if (b.top == 0 and b.bottom == 0 and b.left == 0 and b.right == 0)
        return;

    const color = tint(tint(e.border_color, &e.effects), e.background.effects);
    switch (e.background.base) {
        .solid => |c| {
            const inner: lu.Area = .{
                .pos = .{ .x = area.pos.x + b.left, .y = area.pos.y + b.top },
                .size = .{ .w = area.size.w -| (b.left + b.right), .h = area.size.h -| (b.top + b.bottom) },
            };
            self.fillRoundedRect(area, e.border_radius, color);
            self.fillRoundedRect(inner, e.border_radius, tint(tint(c, &e.effects), e.background.effects));
        },
        .image, .gradient => {
            self.fillRect(.{ .pos = .{ .x = area.pos.x, .y = area.pos.y }, .size = .{ .w = area.size.w, .h = b.top } }, color);
            self.fillRect(.{ .pos = .{ .x = area.pos.x, .y = area.pos.y + area.size.h -| b.bottom }, .size = .{ .w = area.size.w, .h = b.bottom } }, color);
            self.fillRect(.{ .pos = .{ .x = area.pos.x, .y = area.pos.y + b.top }, .size = .{ .w = b.left, .h = area.size.h -| (b.top + b.bottom) } }, color);
            self.fillRect(.{ .pos = .{ .x = area.pos.x + area.size.w -| b.right, .y = area.pos.y + b.top }, .size = .{ .w = b.right, .h = area.size.h -| (b.top + b.bottom) } }, color);
        },
    }
}

/// Multiplies the alpha channel of `color` by the `opacity` effect value.
fn tint(color: lu.Color, effects: []const lu.Effect) lu.Color {
    var out = color;
    for (effects) |effect| {
        switch (effect) {
            .opacity => |o| {
                out.a = @intFromFloat(@min(@as(f64, @floatFromInt(out.a)) * o, 255.0));
            },
            .blur => {},
        }
    }
    return out;
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
    if (radius.top_left == 0 and radius.top_right == 0 and radius.bottom_left == 0 and radius.bottom_right == 0) {
        self.fillRect(area, color);
        return;
    }

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

    const segs: usize = 8;
    const n = segs * 4;
    var verts: [n + 1]sdl.SDL_Vertex = undefined;
    var indices: [3 * n]c_int = undefined;

    const fcolor = sdl.SDL_FColor{
        .r = @as(f32, @floatFromInt(color.r)) / 255.0,
        .g = @as(f32, @floatFromInt(color.g)) / 255.0,
        .b = @as(f32, @floatFromInt(color.b)) / 255.0,
        .a = @as(f32, @floatFromInt(color.a)) / 255.0,
    };
    verts[0] = .{ .position = .{ .x = cx, .y = cy }, .color = fcolor, .tex_coord = .{ .x = 0, .y = 0 } };

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
                .color = fcolor,
                .tex_coord = .{ .x = 0, .y = 0 },
            };
            v += 1;
        }
    }
    for (0..n) |k| {
        indices[k * 3 + 0] = 0;
        indices[k * 3 + 1] = @intCast(k + 1);
        indices[k * 3 + 2] = @intCast(if (k + 2 > n) 1 else k + 2);
    }

    _ = sdl.setRenderDrawBlendMode(self.renderer, sdl.SDL_BLENDMODE_BLEND);
    _ = sdl.renderGeometry(self.renderer, null, &verts, @intCast(verts.len), &indices, @intCast(indices.len));
}
