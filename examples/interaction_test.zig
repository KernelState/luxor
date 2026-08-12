const std = @import("std");
const lu = @import("luxor");
const sdl = @import("sdl");

/// Counters the hook handlers fill in; reset between scenarios.
const TestState = struct {
    hover_enter: u32 = 0,
    hover_leave: u32 = 0,
    click_press: u32 = 0,
    click_release: u32 = 0,
    drag_activates: u32 = 0,
    drag_ends: u32 = 0,
    key_down: u32 = 0,
    key_up: u32 = 0,
};

fn onHover(data: *anyopaque, _: void, enter: bool) void {
    const s: *TestState = @ptrCast(@alignCast(data));
    if (enter) s.hover_enter += 1 else s.hover_leave += 1;
}

fn onClick(data: *anyopaque, _: void, pressed: bool) void {
    const s: *TestState = @ptrCast(@alignCast(data));
    if (pressed) s.click_press += 1 else s.click_release += 1;
}

/// Drag hooks fire once per edge: `activate` when a drag starts, `deactivate`
/// when it ends. There is no per-frame streaming; the app follows the mouse via
/// `ctx.events.dragged` + `ctx.events.pointer` during its build.
fn onDrag(data: *anyopaque, _: u32, active: bool) void {
    const s: *TestState = @ptrCast(@alignCast(data));
    if (active) s.drag_activates += 1 else s.drag_ends += 1;
}

fn onKey(data: *anyopaque, _: lu.Key, down: bool) void {
    const s: *TestState = @ptrCast(@alignCast(data));
    if (down) s.key_down += 1 else s.key_up += 1;
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("FAIL: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn check(ok: bool, comptime name: []const u8) void {
    if (!ok) fail("check '{s}'", .{name});
}

fn pushMotion(win_id: u32, x: f32, y: f32) void {
    var ev: sdl.SDL_Event = undefined;
    ev.type = sdl.SDL_EVENT_MOUSE_MOTION;
    ev.motion = .{ .type = sdl.SDL_EVENT_MOUSE_MOTION, .reserved = 0, .timestamp = 0, .windowID = win_id, .which = 0, .state = 0, .x = x, .y = y, .xrel = 0, .yrel = 0 };
    if (!sdl.pushEvent(&ev)) fail("pushMotion", .{});
}

fn pushButton(win_id: u32, x: f32, y: f32, down: bool) void {
    var ev: sdl.SDL_Event = undefined;
    ev.type = if (down) sdl.SDL_EVENT_MOUSE_BUTTON_DOWN else sdl.SDL_EVENT_MOUSE_BUTTON_UP;
    ev.button = .{ .type = ev.type, .reserved = 0, .timestamp = 0, .windowID = win_id, .which = 0, .button = sdl.SDL_BUTTON_LEFT, .down = down, .clicks = 1, .padding = 0, .x = x, .y = y };
    if (!sdl.pushEvent(&ev)) fail("pushButton", .{});
}

fn pushKey(win_id: u32, down: bool) void {
    var ev: sdl.SDL_Event = undefined;
    ev.type = if (down) sdl.SDL_EVENT_KEY_DOWN else sdl.SDL_EVENT_KEY_UP;
    ev.key = .{ .type = ev.type, .reserved = 0, .timestamp = 0, .windowID = win_id, .which = 0, .scancode = sdl.keycode.SDL_SCANCODE_ESCAPE, .key = sdl.keycode.SDLK_ESCAPE, .mod = 0, .raw = 0, .down = down, .repeat = false };
    if (!sdl.pushEvent(&ev)) fail("pushKey", .{});
}

fn frame(window: *lu.Window, root: *lu.Element) void {
    window.update();
    window.render(root);
}

fn reset(window: *lu.Window, s: *TestState) void {
    s.* = .{};
    window.ctx.?.events = .{};
    window.left_pressed = false;
    window.left_released = false;
    window.pointer_inside = false;
    window.pointer = .{ .x = 0, .y = 0 };
    window.mouse_moved = false;
    window.resized = null;
    window.key = null;
    window.drag_button = 0;
}

pub fn main() !void {
    const ctx = try std.heap.page_allocator.create(lu.Context);
    @memset(std.mem.asBytes(ctx), 0);
    ctx.flags = .{};
    ctx.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    ctx.frame_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    ctx.freetype = try lu.Context.Freetype.init();
    ctx.leaf_layout = .{ .vtable = &lu.Layout.leaf, .parent = null };
    defer std.heap.page_allocator.destroy(ctx);
    defer ctx.freetype.deinit();
    defer ctx.arena.deinit();
    defer ctx.frame_arena.deinit();

    ctx.fonts[0] = try ctx.freetype.createFont(
        "/usr/share/fonts/TTF/IBMPlexSans-Regular.ttf",
        32,
    );
    ctx.font_count = 1;
    defer ctx.fonts[0].deinit();

    if (!sdl.init(sdl.SDL_INIT_VIDEO))
        return error.SDLInitFailed;
    defer sdl.quit();

    var window = try lu.Window.init(.{
        .min_size = .{ .w = 800, .h = 600 },
        .title = "interaction test",
        .transparent = false,
        .decorated = true,
    });
    defer window.deinit();
    window.plugCache(ctx);
    const win_id = sdl.getWindowID(window.window);

    var state = TestState{};

    // One full-window column with a single 300x100 box in the top-left corner.
    // Built once; the tree is re-laid-out and re-processed on every render.
    // Handlers ride in through the overrides, as in a real app.
    var root_cfg = lu.Layout.FlexConfig{ .direction = .column, .gap = 12, .align_items = .flex_start };
    var root = lu.Element{
        .size = .{ .w = 800, .h = 600 },
        .pos = .{ .x = 0, .y = 0 },
        .background = lu.Background.solid(.{ .r = 0xDC, .g = 0xE4, .b = 0xF0, .a = 0xFF }),
        .layout = .{ .vtable = &lu.Layout.flex, .parent = null, .data = &root_cfg },
        .ctx = ctx,
        .events = lu.Context.noEvents,
    };
    root.layout.?.element = &root;
    root.layout.?.start();
    const box = ctx.box(.{ .w = 300, .h = 100 }, .{
        .events = .{
            .hover = .{ .handle = .{ .fptrs = &.{.{ .data = &state, .func = &onHover } } } },
            .click = .{ .handle = .{ .fptrs = &.{.{ .data = &state, .func = &onClick } } } },
        },
    }, @src());
    const box_id = box.id;
    root.layout.?.end();

    // ---------- Scenario A: press + release inside completes a click. ----------
    reset(&window, &state);
    pushMotion(win_id, 10, 10);
    frame(&window, &root);
    check(state.hover_enter == 1, "A hover enter");
    check(state.click_press == 0, "A no press yet");
    pushButton(win_id, 10, 10, true);
    frame(&window, &root);
    check(state.click_press == 1, "A click press");
    check(ctx.events.clicked != null and ctx.events.clicked.? == box_id, "A view clicked is box");
    check(state.drag_activates == 0, "A no drag hook");
    pushButton(win_id, 10, 10, false);
    frame(&window, &root);
    check(state.click_release == 1, "A click release inside");
    check(ctx.events.clicked == null, "A view clicked cleared");
    pushMotion(win_id, 400, 400);
    frame(&window, &root);
    check(state.hover_leave == 1, "A hover leave on exit");

    // ------- Scenario B: release outside does not complete the click. --------
    reset(&window, &state);
    pushButton(win_id, 10, 10, true);
    frame(&window, &root);
    check(state.click_press == 1, "B click press");
    pushButton(win_id, 400, 400, false);
    frame(&window, &root);
    check(state.click_release == 0, "B no release outside");
    check(ctx.events.clicked == null, "B view clicked cleared");
    check(state.hover_leave == 1, "B hover left when released outside");

    // ---- Scenario C: drag activates once, state tracks the mouse, ends on release. ----
    reset(&window, &state);
    box.events.drag = .{ .handle = .{ .fptrs = &.{.{ .data = &state, .func = &onDrag } } } };
    pushButton(win_id, 10, 10, true);
    frame(&window, &root);
    check(state.drag_activates == 1, "C drag activates once on press");
    check(ctx.events.dragged != null and ctx.events.dragged.? == box_id, "C view dragged is box");
    pushMotion(win_id, 100, 10);
    frame(&window, &root);
    check(state.drag_activates == 1, "C no streamed drag calls");
    check(ctx.events.dragged != null and ctx.events.dragged.? == box_id, "C drag persists");
    check(ctx.events.pointer.x == 100 and ctx.events.pointer.y == 10, "C view pointer tracks motion");
    check(ctx.events.mouse_moved, "C mouse_moved flag");
    pushMotion(win_id, 200, 10);
    frame(&window, &root);
    check(ctx.events.pointer.x == 200, "C view pointer keeps tracking");
    pushButton(win_id, 200, 10, false);
    frame(&window, &root);
    check(state.drag_ends == 1, "C drag ends on release");
    check(ctx.events.dragged == null, "C view dragged cleared");
    check(state.click_release == 0, "C drag supersedes click release");

    // ---------- Scenario D: keyboard edges fire activate/deactivate. ----------
    reset(&window, &state);
    box.events.drag = .{ .handle = null };
    window.events.key = .{ .handle = .{ .fptrs = &.{.{ .data = &state, .func = &onKey } } } };
    pushKey(win_id, true);
    frame(&window, &root);
    check(state.key_down == 1, "D key down");
    check(ctx.events.key == .escape and ctx.events.key_down, "D view key reported");
    pushKey(win_id, false);
    frame(&window, &root);
    check(state.key_up == 1, "D key up");
    check(ctx.events.key == .escape and !ctx.events.key_down, "D view key up reported");

    std.debug.print("interaction test OK\n", .{});
}
