const std = @import("std");
const sg = @import("sokol").gfx;
const sgl = @import("sokol").gl;
const sapp = @import("sokol").app;

const VTable = @import("../Platform.zig").renderer.VTable;
const Surface = @import("../Platform.zig").renderer.Surface;
const ObjectId = @import("../Platform.zig").renderer.ObjectId;
const SurfaceInfo = @import("../Platform.zig").renderer.SurfaceInfo;
const TextureInfo = @import("../Platform.zig").renderer.TextureInfo;
const TextureFormat = @import("../Platform.zig").renderer.TextureFormat;
const Rect = @import("../Platform.zig").renderer.Rect;
const Pos = @import("../Platform.zig").renderer.Pos;
const Size = @import("../Platform.zig").renderer.Size;
const Corners = @import("../Platform.zig").renderer.Corners;
const Background = @import("../Platform.zig").renderer.Background;
const Mask = @import("../Platform.zig").renderer.Mask;

const max_surfaces = 16;
const max_textures = 64;
const max_clip_depth = 32;

const Renderer = @This();

allocator: std.mem.Allocator,
initialized: bool,
surfaces: [max_surfaces]SurfaceState,
textures: [max_textures]TextureState,
clip_stack: [max_clip_depth]ClipState,
clip_depth: u32,

const SurfaceState = struct {
    width: u32 = 0,
    height: u32 = 0,
    active: bool = false,
};

const TextureState = struct {
    image: sg.Image = .{},
    sampler: sg.Sampler = .{},
    width: u32 = 0,
    height: u32 = 0,
    format: TextureFormat = .rgba8,
    active: bool = false,
};

const ClipState = struct {
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
};

pub const vtable = VTable{
    .init = init,
    .deinit = deinitFn,
    .createSurface = createSurface,
    .destroySurface = destroySurface,
    .getSurfaceInfo = getSurfaceInfo,
    .resizeSurface = resizeSurface,
    .uploadTexture = uploadTexture,
    .destroyTexture = destroyTexture,
    .getTextureInfo = getTextureInfo,
    .beginFrame = beginFrame,
    .endFrame = endFrame,
    .drawRect = drawRect,
    .drawCircle = drawCircle,
    .drawTriangle = drawTriangle,
    .drawSvg = drawSvg,
    .drawMask = drawMask,
    .pushClip = pushClip,
    .popClip = popClip,
};

fn init(alloc: std.mem.Allocator) anyerror!*anyopaque {
    sg.setup(.{});
    sgl.setup(.{});
    const self = try alloc.create(Renderer);
    self.* = .{
        .allocator = alloc,
        .initialized = true,
        .surfaces = @splat(.{}),
        .textures = @splat(.{}),
        .clip_stack = @splat(.{}),
        .clip_depth = 0,
    };
    return self;
}

fn deinitFn(ctx: *anyopaque) void {
    const self: *Renderer = @alignCast(@ptrCast(ctx));
    if (!self.initialized) return;
    for (&self.textures) |*tex| {
        if (tex.active) {
            sg.destroyImage(tex.image);
            sg.destroySampler(tex.sampler);
        }
    }
    sgl.shutdown();
    sg.shutdown();
    self.initialized = false;
    self.allocator.destroy(self);
}

fn createSurface(ctx: *anyopaque, native_surface: Surface) anyerror!ObjectId {
    const self: *Renderer = @alignCast(@ptrCast(ctx));
    _ = native_surface;
    for (0..max_surfaces) |i| {
        if (!self.surfaces[i].active) {
            self.surfaces[i] = .{
                .width = @intCast(sapp.width()),
                .height = @intCast(sapp.height()),
                .active = true,
            };
            return @intCast(i);
        }
    }
    return error.TooManySurfaces;
}

fn destroySurface(ctx: *anyopaque, id: ObjectId) void {
    const self: *Renderer = @alignCast(@ptrCast(ctx));
    if (id < max_surfaces) {
        self.surfaces[id] = .{};
    }
}

fn getSurfaceInfo(ctx: *anyopaque, id: ObjectId) SurfaceInfo {
    const self: *Renderer = @alignCast(@ptrCast(ctx));
    if (id < max_surfaces and self.surfaces[id].active) {
        const s = self.surfaces[id];
        return .{
            .width = s.width,
            .height = s.height,
            .format = .rgba8,
            .vsync = true,
        };
    }
    return .{
        .width = @intCast(sapp.width()),
        .height = @intCast(sapp.height()),
        .format = .rgba8,
        .vsync = true,
    };
}

fn resizeSurface(ctx: *anyopaque, id: ObjectId, width: u32, height: u32) anyerror!void {
    const self: *Renderer = @alignCast(@ptrCast(ctx));
    if (id < max_surfaces and self.surfaces[id].active) {
        self.surfaces[id].width = width;
        self.surfaces[id].height = height;
    }
}

fn uploadTexture(ctx: *anyopaque, data: []const u8, width: u32, height: u32, format: TextureFormat) anyerror!ObjectId {
    const self: *Renderer = @alignCast(@ptrCast(ctx));
    for (0..max_textures) |i| {
        if (!self.textures[i].active) {
            var img_data: sg.ImageData = .{};
            img_data.mip_levels[0] = .{ .ptr = data.ptr, .size = data.len };
            const img = sg.makeImage(.{
                .width = @intCast(width),
                .height = @intCast(height),
                .pixel_format = texFmtToSg(format),
                .data = img_data,
            });
            const smp = sg.makeSampler(.{
                .min_filter = .LINEAR,
                .mag_filter = .LINEAR,
            });
            self.textures[i] = .{
                .image = img,
                .sampler = smp,
                .width = width,
                .height = height,
                .format = format,
                .active = true,
            };
            return @intCast(i);
        }
    }
    return error.TooManyTextures;
}

fn destroyTexture(ctx: *anyopaque, id: ObjectId) void {
    const self: *Renderer = @alignCast(@ptrCast(ctx));
    if (id < max_textures and self.textures[id].active) {
        sg.destroyImage(self.textures[id].image);
        sg.destroySampler(self.textures[id].sampler);
        self.textures[id] = .{};
    }
}

fn getTextureInfo(ctx: *anyopaque, id: ObjectId) TextureInfo {
    const self: *Renderer = @alignCast(@ptrCast(ctx));
    if (id < max_textures and self.textures[id].active) {
        const t = self.textures[id];
        return .{ .width = t.width, .height = t.height, .format = t.format };
    }
    return .{ .width = 0, .height = 0, .format = .rgba8 };
}

fn beginFrame(ctx: *anyopaque, surface: ObjectId) anyerror!void {
    const self: *Renderer = @alignCast(@ptrCast(ctx));
    const w: u32 = if (surface < max_surfaces and self.surfaces[surface].active)
        self.surfaces[surface].width
    else
        @intCast(sapp.width());
    const h: u32 = if (surface < max_surfaces and self.surfaces[surface].active)
        self.surfaces[surface].height
    else
        @intCast(sapp.height());

    sg.beginPass(.{
        .action = .{
            .colors = @splat(.{
                .load_action = .CLEAR,
                .clear_value = .{ .r = 0.15, .g = 0.15, .b = 0.2, .a = 1.0 },
            }),
        },
        .swapchain = .{
            .width = @intCast(w),
            .height = @intCast(h),
        },
    });

    sgl.defaults();
    sgl.matrixModeProjection();
    sgl.loadIdentity();
    sgl.ortho(0, @floatFromInt(w), @floatFromInt(h), 0, -1, 1);

    self.clip_depth = 0;
}

fn endFrame(ctx: *anyopaque) anyerror!void {
    _ = ctx;
    sgl.draw();
    sg.endPass();
    sg.commit();
}

fn drawRect(ctx: *anyopaque, rect: Rect, pos: Pos, corners: Corners, bg: Background) void {
    _ = ctx;
    _ = corners;

    const x: f32 = @floatFromInt(pos.x);
    const y: f32 = @floatFromInt(pos.y);
    const w: f32 = @floatFromInt(rect.w);
    const h: f32 = @floatFromInt(rect.h);

    sgl.beginQuads();
    switch (bg) {
        .solid => |c| {
            sgl.c4f(c.r, c.g, c.b, c.a);
            sgl.v3f(x, y, 0);
            sgl.v3f(x + w, y, 0);
            sgl.v3f(x + w, y + h, 0);
            sgl.v3f(x, y + h, 0);
        },
        .vertex_colors => |vc| {
            sgl.c4f(vc[0].r, vc[0].g, vc[0].b, vc[0].a);
            sgl.v3f(x, y, 0);
            sgl.c4f(vc[1].r, vc[1].g, vc[1].b, vc[1].a);
            sgl.v3f(x + w, y, 0);
            sgl.c4f(vc[2].r, vc[2].g, vc[2].b, vc[2].a);
            sgl.v3f(x + w, y + h, 0);
            sgl.c4f(vc[0].r, vc[0].g, vc[0].b, vc[0].a);
            sgl.v3f(x, y + h, 0);
        },
        .texture => |t| {
            _ = t;
            sgl.c4f(1, 1, 1, 1);
            sgl.v3f(x, y, 0);
            sgl.v3f(x + w, y, 0);
            sgl.v3f(x + w, y + h, 0);
            sgl.v3f(x, y + h, 0);
        },
        .gradient => |g| {
            _ = g;
            sgl.c4f(1, 1, 1, 1);
            sgl.v3f(x, y, 0);
            sgl.v3f(x + w, y, 0);
            sgl.v3f(x + w, y + h, 0);
            sgl.v3f(x, y + h, 0);
        },
    }
    sgl.end();
}

fn drawCircle(ctx: *anyopaque, radius: f32, pos: Pos, bg: Background) void {
    _ = ctx;

    const cx: f32 = @floatFromInt(pos.x);
    const cy: f32 = @floatFromInt(pos.y);
    const segments = 32;

    sgl.beginTriangles();
    switch (bg) {
        .solid => |c| {
            sgl.c4f(c.r, c.g, c.b, c.a);
            for (0..segments) |i| {
                const a0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments)) * std.math.pi * 2.0;
                const a1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segments)) * std.math.pi * 2.0;
                sgl.v3f(cx, cy, 0);
                sgl.v3f(cx + @cos(a0) * radius, cy + @sin(a0) * radius, 0);
                sgl.v3f(cx + @cos(a1) * radius, cy + @sin(a1) * radius, 0);
            }
        },
        else => {
            sgl.c4f(1, 1, 1, 1);
            for (0..segments) |i| {
                const a0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments)) * std.math.pi * 2.0;
                const a1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segments)) * std.math.pi * 2.0;
                sgl.v3f(cx, cy, 0);
                sgl.v3f(cx + @cos(a0) * radius, cy + @sin(a0) * radius, 0);
                sgl.v3f(cx + @cos(a1) * radius, cy + @sin(a1) * radius, 0);
            }
        },
    }
    sgl.end();
}

fn drawTriangle(ctx: *anyopaque, a: Pos, b: Pos, c: Pos, bg: Background) void {
    _ = ctx;

    const ax: f32 = @floatFromInt(a.x);
    const ay: f32 = @floatFromInt(a.y);
    const bx: f32 = @floatFromInt(b.x);
    const by: f32 = @floatFromInt(b.y);
    const cx: f32 = @floatFromInt(c.x);
    const cy: f32 = @floatFromInt(c.y);

    sgl.beginTriangles();
    switch (bg) {
        .solid => |color| {
            sgl.c4f(color.r, color.g, color.b, color.a);
            sgl.v3f(ax, ay, 0);
            sgl.v3f(bx, by, 0);
            sgl.v3f(cx, cy, 0);
        },
        .vertex_colors => |vc| {
            sgl.v3fC3f(ax, ay, 0, vc[0].r, vc[0].g, vc[0].b);
            sgl.v3fC3f(bx, by, 0, vc[1].r, vc[1].g, vc[1].b);
            sgl.v3fC3f(cx, cy, 0, vc[2].r, vc[2].g, vc[2].b);
        },
        .texture => {
            sgl.c4f(1, 1, 1, 1);
            sgl.v3f(ax, ay, 0);
            sgl.v3f(bx, by, 0);
            sgl.v3f(cx, cy, 0);
        },
        .gradient => |g| {
            if (g.stops.len > 0) {
                const c0 = g.stops[0].color;
                sgl.c4f(c0.r, c0.g, c0.b, c0.a);
            } else {
                sgl.c4f(1, 1, 1, 1);
            }
            sgl.v3f(ax, ay, 0);
            sgl.v3f(bx, by, 0);
            sgl.v3f(cx, cy, 0);
        },
    }
    sgl.end();
}

fn drawSvg(ctx: *anyopaque, svg_id: ObjectId, pos: Pos, size: Size) void {
    _ = ctx;
    _ = svg_id;
    _ = pos;
    _ = size;
}

fn drawMask(ctx: *anyopaque, mask: Mask, pos: Pos, bg: Background) void {
    const self: *Renderer = @alignCast(@ptrCast(ctx));
    switch (mask) {
        .rect => |r| {
            pushClipRect(self, pos.x, pos.y, r.rect.w, r.rect.h);
            drawRect(ctx, r.rect, pos, r.corners, bg);
            popClipRect(self);
        },
        .circle => |circ| {
            const diameter: u32 = @intFromFloat(circ.radius * 2);
            const offset: u32 = @intFromFloat(circ.radius);
            const x = if (pos.x > offset) pos.x - offset else 0;
            const y = if (pos.y > offset) pos.y - offset else 0;
            pushClipRect(self, x, y, diameter, diameter);
            drawCircle(ctx, circ.radius, pos, bg);
            popClipRect(self);
        },
        .triangle => |tri| {
            const min_x = @min(tri.a.x, tri.b.x, tri.c.x);
            const min_y = @min(tri.a.y, tri.b.y, tri.c.y);
            const max_x = @max(tri.a.x, tri.b.x, tri.c.x);
            const max_y = @max(tri.a.y, tri.b.y, tri.c.y);
            pushClipRect(self, pos.x + min_x, pos.y + min_y, max_x - min_x, max_y - min_y);
            drawTriangle(ctx, .{ .x = pos.x + tri.a.x, .y = pos.y + tri.a.y }, .{ .x = pos.x + tri.b.x, .y = pos.y + tri.b.y }, .{ .x = pos.x + tri.c.x, .y = pos.y + tri.c.y }, bg);
            popClipRect(self);
        },
        .svg => {},
    }
}

fn pushClip(ctx: *anyopaque, rect: Rect) void {
    const self: *Renderer = @alignCast(@ptrCast(ctx));
    pushClipRect(self, 0, 0, rect.w, rect.h);
}

fn popClip(ctx: *anyopaque) void {
    const self: *Renderer = @alignCast(@ptrCast(ctx));
    popClipRect(self);
}

fn pushClipRect(self: *Renderer, x: u32, y: u32, w: u32, h: u32) void {
    if (self.clip_depth < max_clip_depth) {
        self.clip_stack[self.clip_depth] = .{ .x = x, .y = y, .w = w, .h = h };
        self.clip_depth += 1;
    }
    sgl.scissorRect(@intCast(x), @intCast(y), @intCast(w), @intCast(h), true);
}

fn popClipRect(self: *Renderer) void {
    if (self.clip_depth > 0) {
        self.clip_depth -= 1;
    }
    if (self.clip_depth > 0) {
        const prev = self.clip_stack[self.clip_depth - 1];
        sgl.scissorRect(@intCast(prev.x), @intCast(prev.y), @intCast(prev.w), @intCast(prev.h), true);
    } else {
        const w = sapp.width();
        const h = sapp.height();
        sgl.scissorRect(0, 0, w, h, true);
    }
}

fn texFmtToSg(fmt: TextureFormat) sg.PixelFormat {
    return switch (fmt) {
        .rgba8 => .RGBA8,
        .bgra8 => .BGRA8,
        .rgb8 => .RGBA8,
        .rgba16f => .RGBA16F,
        .r8 => .R8,
    };
}
