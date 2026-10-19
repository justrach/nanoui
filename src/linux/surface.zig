//! Native UI on Linux: a GtkGLArea that the OpenGL renderer draws
//! (`glarea.zig`), or, without OpenGL 3.3, a GtkDrawingArea showing frames
//! the CPU renderer draws (cairo puts them on screen, at the monitor's
//! scale); fed the pointer, the wheel, keys and an input method's text.
//! Frames run on input and while something animates (a tick callback);
//! idle, nothing runs.
const std = @import("std");
const gtk = @import("gtk.zig");
const ui = @import("../ui/ui.zig");
const types = @import("../ui/types.zig");
const gpu = @import("../ui/gpu.zig");
const canvas = @import("../ui/canvas.zig");
const glarea = @import("glarea.zig");
const opengl = @import("../ui/opengl.zig");
const text = @import("../ui/text.zig");
const frame_mod = @import("../ui/frame.zig");
const ctx_mod = @import("../ui/context.zig");
const clock = @import("../ui/clock.zig");
const Theme = @import("../ui/theme.zig").Theme;
const Context = ctx_mod.Context;
const Window = @import("window.zig").Window;

pub const Surface = struct {
    gpa: std.mem.Allocator,
    window: *Window,
    area: *gtk.Widget,
    im: *anyopaque,
    text: text.TextSystem,
    ctx: Context,
    view: ui.View,
    instances: std.ArrayList(gpu.Instance) = .empty,
    pixels: canvas.Canvas = .{},
    /// The area is a GL area: OpenGL draws it, once it is realized.
    gl: bool,
    renderer: ?opengl.Renderer = null,
    /// OpenGL failed: the drawing area replaces the GL area soon.
    fallback: c_uint = 0,
    size: types.Size = .{},
    scale: f32 = 1,
    last_frame_time: f64 = 0,
    start_time: f64,
    tick: c_uint = 0,
    idle: c_uint = 0,
    /// A frame asked for later (`frameIn`).
    later: c_uint = 0,
    theme_override: ?Theme = null,
    cursor: ctx_mod.Cursor = .arrow,
    /// Text the input method committed during this key event.
    committed: std.ArrayList(u8) = .empty,
    /// The press that started a double or triple click was already sent.
    pressed: bool = false,

    pub fn create(window: *Window, view: ui.View, theme_override: ?Theme) !*Surface {
        const gpa = window.app.gpa;
        const self = try gpa.create(Surface);
        errdefer gpa.destroy(self);
        const g = &gtk.api;
        const gl_area = if (window.app.cpu_only) null else glarea.new();
        const area = gl_area orelse g.gtk_drawing_area_new();
        self.* = .{
            .gpa = gpa,
            .window = window,
            .area = area,
            .gl = gl_area != null,
            .im = g.gtk_im_multicontext_new(),
            .text = .init(gpa),
            .ctx = undefined,
            .view = view,
            .theme_override = theme_override,
            .start_time = clock.now(),
        };
        self.ctx = .init(gpa, &self.text);
        self.attach(area);
        gtk.connect(self.im, "commit", @ptrCast(&onCommit), self);
        g.gtk_container_add(window.gtkwindow.?, area);
        return self;
    }

    /// Feeds `area`'s events to the surface, and draws it.
    fn attach(self: *Surface, area: *gtk.Widget) void {
        const g = &gtk.api;
        g.gtk_widget_set_can_focus(area, 1);
        g.gtk_widget_add_events(area, gtk.pointer_motion_mask | gtk.button_press_mask | gtk.button_release_mask | gtk.key_press_mask | gtk.leave_notify_mask | gtk.focus_change_mask | gtk.scroll_mask | gtk.smooth_scroll_mask);
        if (self.gl) {
            gtk.connect(area, "render", @ptrCast(&onRender), self);
        } else gtk.connect(area, "draw", @ptrCast(&onDraw), self);
        gtk.connect(area, "size-allocate", @ptrCast(&onSize), self);
        gtk.connect(area, "button-press-event", @ptrCast(&onPress), self);
        gtk.connect(area, "button-release-event", @ptrCast(&onRelease), self);
        gtk.connect(area, "motion-notify-event", @ptrCast(&onMotion), self);
        gtk.connect(area, "leave-notify-event", @ptrCast(&onLeave), self);
        gtk.connect(area, "scroll-event", @ptrCast(&onScroll), self);
        gtk.connect(area, "key-press-event", @ptrCast(&onKey), self);
        gtk.connect(area, "focus-in-event", @ptrCast(&onFocusIn), self);
        gtk.connect(area, "focus-out-event", @ptrCast(&onFocusOut), self);
        gtk.connect(area, "realize", @ptrCast(&onRealize), self);
    }

    pub fn destroy(self: *Surface) void {
        const g = &gtk.api;
        if (self.tick != 0) g.gtk_widget_remove_tick_callback(self.area, self.tick);
        if (self.idle != 0) _ = g.g_source_remove(self.idle);
        if (self.later != 0) _ = g.g_source_remove(self.later);
        if (self.fallback != 0) _ = g.g_source_remove(self.fallback);
        // While the area is still realized: its context frees the renderer's.
        if (self.renderer) |*r| {
            glarea.api.gtk_gl_area_make_current(self.area);
            r.deinit();
        }
        g.g_object_unref(self.im);
        self.instances.deinit(self.gpa);
        self.committed.deinit(self.gpa);
        self.pixels.deinit(self.gpa);
        self.ctx.deinit();
        self.text.deinit();
        self.gpa.destroy(self);
    }

    fn theme(self: *Surface) Theme {
        if (self.theme_override) |t| return t;
        return if (@import("desktop.zig").isDark()) Theme.dark_theme else Theme.light;
    }

    /// Builds, lays out and paints a frame; what it changed is drawn when
    /// GTK draws.
    pub fn frame(self: *Surface) void {
        if (self.size.w <= 0 or self.size.h <= 0) return;
        const c = &self.ctx;
        const now = clock.now();
        const dt: f32 = if (self.last_frame_time > 0) @floatCast(@min(now - self.last_frame_time, 0.1)) else 1.0 / 60.0;
        self.last_frame_time = now;
        const r = frame_mod.run(c, self.view, &self.text, &self.instances, self.size, self.scale, self.theme(), dt, now - self.start_time);
        if (self.gl) {
            glarea.api.gtk_gl_area_queue_render(self.area);
        } else if (self.pixels.damage(self.shown())) |d| {
            // The points around those pixels.
            const x0 = @floor(@as(f32, @floatFromInt(d[0])) / self.scale);
            const y0 = @floor(@as(f32, @floatFromInt(d[1])) / self.scale);
            const x1 = @ceil(@as(f32, @floatFromInt(d[2])) / self.scale);
            const y1 = @ceil(@as(f32, @floatFromInt(d[3])) / self.scale);
            gtk.api.gtk_widget_queue_draw_area(self.area, @intFromFloat(x0), @intFromFloat(y0), @intFromFloat(x1 - x0), @intFromFloat(y1 - y0));
        }
        self.updateCursor();
        const more = c.animating or r.hot_changed;
        if (more and self.tick == 0) {
            self.tick = gtk.api.gtk_widget_add_tick_callback(self.area, onTick, self, null);
        } else if (!more and self.later == 0) if (c.frame_in) |s| {
            // Something changes now and then: one frame, that much later.
            self.later = gtk.api.g_timeout_add(@intFromFloat(@max(1, s * 1000)), onLater, self);
        };
        if (!c.animating) self.last_frame_time = 0;
    }

    /// A frame soon, for changes from outside the view (a process's output).
    pub fn requestFrame(self: *Surface) void {
        if (self.idle == 0) self.idle = gtk.api.g_idle_add(onIdle, self);
    }

    fn onLater(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Surface = @ptrCast(@alignCast(data));
        self.later = 0;
        self.frame();
        return 0;
    }

    fn onIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Surface = @ptrCast(@alignCast(data));
        self.idle = 0;
        self.frame();
        return 0;
    }

    fn onTick(_: *gtk.Widget, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Surface = @ptrCast(@alignCast(data));
        self.frame();
        if (self.ctx.animating) return 1;
        self.tick = 0;
        return 0;
    }

    fn shown(self: *Surface) canvas.Frame {
        return .{ .instances = self.instances.items, .text = &self.text, .clear = self.ctx.theme.background, .size = self.size, .scale = self.scale };
    }

    fn updateCursor(self: *Surface) void {
        const want: ctx_mod.Cursor = self.ctx.cursor orelse if (self.ctx.cursor_text) .text else if (self.ctx.cursor_hand) .hand else .arrow;
        if (want == self.cursor) return;
        self.cursor = want;
        const g = &gtk.api;
        const win = g.gtk_widget_get_window(self.area) orelse return;
        const name: [*:0]const u8 = switch (want) {
            .arrow => "default",
            .hand => "pointer",
            .text => "text",
            .resize_left_right => "col-resize",
            .resize_up_down => "row-resize",
        };
        g.gdk_window_set_cursor(win, g.gdk_cursor_new_from_name(g.gdk_display_get_default(), name));
    }

    fn setMouse(self: *Surface, e: *gtk.Event) void {
        const g = &gtk.api;
        var x: f64 = 0;
        var y: f64 = 0;
        _ = g.gdk_event_get_coords(e, &x, &y);
        self.ctx.input.mouse = .{ .x = @floatCast(x), .y = @floatCast(y) };
        var state: c_uint = 0;
        _ = g.gdk_event_get_state(e, &state);
        self.ctx.input.shift = state & gtk.shift_mask != 0;
        self.ctx.input.cmd = false;
        self.ctx.input.ctrl = state & gtk.control_mask != 0;
    }
};

fn of(data: ?*anyopaque) *Surface {
    return @ptrCast(@alignCast(data));
}

fn onRealize(_: *gtk.Widget, data: ?*anyopaque) callconv(.c) void {
    const s = of(data);
    gtk.api.gtk_im_context_set_client_window(s.im, gtk.api.gtk_widget_get_window(s.area));
    if (!s.gl) return;
    s.renderer = glarea.start(s.area);
    if (s.renderer != null) {
        s.ctx.renderer = "OpenGL";
        s.requestFrame();
        if (s.window.app.debug) std.debug.print("nanoui: window {x} draws with OpenGL on {s}\n", .{ @intFromPtr(s.window), glarea.gpuName() });
    } else if (s.fallback == 0) {
        // Not from inside the area's own signal: the area is replaced soon.
        s.fallback = gtk.api.g_idle_add(useCpu, s);
    }
}

/// OpenGL failed: a drawing area, which the CPU renderer draws, replaces
/// the GL area.
fn useCpu(data: ?*anyopaque) callconv(.c) c_int {
    const s = of(data);
    const g = &gtk.api;
    s.fallback = 0;
    if (s.tick != 0) g.gtk_widget_remove_tick_callback(s.area, s.tick);
    s.tick = 0;
    g.gtk_widget_destroy(s.area);
    s.gl = false;
    s.area = g.gtk_drawing_area_new();
    s.attach(s.area);
    g.gtk_container_add(s.window.gtkwindow.?, s.area);
    glarea.api.gtk_widget_show(s.area);
    g.gtk_widget_grab_focus(s.area);
    return 0;
}

fn onRender(_: *gtk.Widget, _: *anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    const s = of(data);
    if (s.renderer) |*r| {
        r.sync(s.text.atlas.mask(), s.text.atlas.generation, s.text.images.pictures(), s.text.images.generation);
        r.draw(s.instances.items, s.size, s.scale, s.ctx.theme.background, glarea.target());
        return 1;
    }
    return 0;
}

fn onDraw(_: *gtk.Widget, cr: *anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    const s = of(data);
    const g = &gtk.api;
    s.pixels.draw(s.gpa, s.shown());
    const px = &s.pixels;
    if (px.bytes.len == 0) return 0;
    // ARGB32 on a little-endian machine is BGRA: the renderer's order.
    const surf = g.cairo_image_surface_create_for_data(px.bytes.ptr, 0, @intCast(px.width), @intCast(px.height), @intCast(px.width * 4));
    defer g.cairo_surface_destroy(surf);
    g.cairo_surface_set_device_scale(surf, s.scale, s.scale);
    g.cairo_set_source_surface(cr, surf, 0, 0);
    g.cairo_paint(cr);
    return 1;
}

fn onSize(w: *gtk.Widget, _: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const s = of(data);
    const g = &gtk.api;
    const size: types.Size = .{ .w = @floatFromInt(g.gtk_widget_get_allocated_width(w)), .h = @floatFromInt(g.gtk_widget_get_allocated_height(w)) };
    const scale: f32 = @floatFromInt(@max(1, g.gtk_widget_get_scale_factor(w)));
    if (size.w == s.size.w and size.h == s.size.h and scale == s.scale) return;
    s.size = size;
    s.scale = scale;
    s.text.setScale(scale);
    s.frame();
}

fn onPress(w: *gtk.Widget, e: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    const s = of(data);
    const g = &gtk.api;
    g.gtk_widget_grab_focus(w);
    var button: c_uint = 0;
    _ = g.gdk_event_get_button(e, &button);
    if (button != 1) return 0;
    s.setMouse(e);
    var count: c_uint = 1;
    _ = g.gdk_event_get_click_count(e, &count);
    const kind = g.gdk_event_get_event_type(e);
    s.ctx.input.click_count = count;
    // GTK sends a press for each click and then one more for a double
    // or triple click: that one only tells the count.
    if (kind == gtk.double_press or kind == gtk.triple_press) {
        s.ctx.input.pressed = true;
        s.frame();
        return 1;
    }
    s.ctx.updateHot();
    s.ctx.pointerDown();
    s.frame();
    return 1;
}

fn onRelease(_: *gtk.Widget, e: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    const s = of(data);
    var button: c_uint = 0;
    _ = gtk.api.gdk_event_get_button(e, &button);
    if (button != 1) return 0;
    s.setMouse(e);
    s.ctx.updateHot();
    s.ctx.pointerUp();
    s.frame();
    return 1;
}

fn onMotion(_: *gtk.Widget, e: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    const s = of(data);
    s.setMouse(e);
    const before = s.ctx.hot;
    s.ctx.updateHot();
    if (s.ctx.input.down or s.ctx.hot != before or s.ctx.wants_moves) {
        s.frame();
    } else if (s.ctx.pointerOverText() != s.ctx.cursor_text) {
        // Onto or off text that selects: the cursor only.
        s.ctx.cursor_text = !s.ctx.cursor_text;
        s.updateCursor();
    }
    return 1;
}

fn onLeave(_: *gtk.Widget, _: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    const s = of(data);
    s.ctx.input.mouse = .{ .x = -1e6, .y = -1e6 };
    if (s.ctx.hot != 0) {
        s.ctx.updateHot();
        s.frame();
    }
    return 0;
}

fn onScroll(_: *gtk.Widget, e: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    const s = of(data);
    const g = &gtk.api;
    s.setMouse(e);
    var dx: f64 = 0;
    var dy: f64 = 0;
    var delta: f32 = 0;
    if (g.gdk_event_get_scroll_deltas(e, &dx, &dy) != 0) {
        // Smooth deltas are in lines of about 40 pixels; up is negative.
        delta = @floatCast(-dy * 40);
    } else {
        var dir: c_int = 0;
        _ = g.gdk_event_get_scroll_direction(e, &dir);
        delta = if (dir == 0) 48 else if (dir == 1) -48 else 0;
    }
    if (s.ctx.applyScroll(delta)) {
        s.frame();
        s.ctx.updateHot();
    } else if (s.ctx.wants_wheel) {
        s.ctx.input.scroll = .{ .y = delta };
        s.frame();
    }
    return 1;
}

fn onFocusIn(_: *gtk.Widget, _: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    gtk.api.gtk_im_context_focus_in(of(data).im);
    return 0;
}

fn onFocusOut(_: *gtk.Widget, _: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    gtk.api.gtk_im_context_focus_out(of(data).im);
    return 0;
}

fn onCommit(_: *anyopaque, str: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const s = of(data);
    s.committed.appendSlice(s.gpa, std.mem.span(str)) catch {};
}

/// GDK key values of the keys that are not text.
fn keyOf(keyval: c_uint) ?ctx_mod.Key {
    return switch (keyval) {
        0xff08 => .backspace,
        0xffff => .delete,
        0xff51 => .left,
        0xff52 => .up,
        0xff53 => .right,
        0xff54 => .down,
        0xff50 => .home,
        0xff57 => .end,
        0xff0d, 0xff8d => .enter,
        0xff09, 0xfe20 => .tab,
        0xff1b => .escape,
        0xff55 => .page_up,
        0xff56 => .page_down,
        0xffbe...0xffc9 => @enumFromInt(@intFromEnum(ctx_mod.Key.f1) + (keyval - 0xffbe)),
        else => null,
    };
}

fn onKey(_: *gtk.Widget, e: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    const s = of(data);
    const g = &gtk.api;
    var keyval: c_uint = 0;
    var state: c_uint = 0;
    _ = g.gdk_event_get_keyval(e, &keyval);
    _ = g.gdk_event_get_state(e, &state);
    const in = &s.ctx.input;
    in.shift = state & gtk.shift_mask != 0;
    in.cmd = false;
    const ctrl = state & gtk.control_mask != 0;
    const alt = state & gtk.alt_mask != 0;
    in.ctrl = ctrl;
    in.alt = alt;
    const key = keyOf(keyval);
    // Key combinations go to the menus' accelerators, then the view.
    const special: ?u21 = if (key) |k| switch (k) {
        .up => ui.Shortcut.up,
        .down => ui.Shortcut.down,
        .left => ui.Shortcut.left,
        .right => ui.Shortcut.right,
        .tab => ui.Shortcut.tab,
        .escape => ui.Shortcut.escape,
        .enter => ui.Shortcut.enter,
        else => null,
    } else null;
    const cp: u21 = @intCast(g.gdk_keyval_to_unicode(keyval));
    const base: u21 = special orelse if (cp < 128) std.ascii.toLower(@intCast(cp)) else cp;
    if (base != 0 and (ctrl or alt or (special != null and (base == ui.Shortcut.up or base == ui.Shortcut.down or base == ui.Shortcut.tab or base == ui.Shortcut.escape)))) {
        const sc: ui.Shortcut = .{ .key = base, .ctrl = ctrl, .alt = alt, .shift = in.shift };
        if (s.window.app.accelerator(sc)) return 1;
        if (ctrl and s.ctx.focused_text != null and editShortcut(s, base)) return 1;
        s.ctx.shortcut_taken = false;
        in.shortcut = sc;
        s.frame();
        in.shortcut = null;
        if (s.ctx.shortcut_taken) return 1;
    }
    if (key) |k| {
        in.key = k;
        s.frame();
        return 1;
    }
    if (ctrl) return 0;
    s.committed.clearRetainingCapacity();
    if (g.gtk_im_context_filter_keypress(s.im, e) == 0 and cp >= 0x20 and cp != 0x7f) {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return 0;
        s.committed.appendSlice(s.gpa, buf[0..n]) catch {};
    }
    if (s.committed.items.len == 0) return 1;
    in.chars = s.committed.items;
    s.frame();
    return 1;
}

/// Ctrl+C, X, V and A in a text field: copy, cut, paste, select all.
fn editShortcut(s: *Surface, key: u21) bool {
    const op: ctx_mod.TextOp = switch (key) {
        'c' => .{ .command = .copy },
        'x' => .{ .command = .cut },
        'a' => .{ .command = .select_all },
        'v' => {
            const pasted = @import("desktop.zig").clipboard.readText(s.gpa) catch return true;
            // No text: the view may take Ctrl+V for something else (an image).
            const t = pasted orelse return false;
            defer s.gpa.free(t);
            for (t) |*ch| if (ch.* == '\n' or ch.* == '\r') {
                ch.* = ' ';
            };
            var ops = [1]ctx_mod.TextOp{.{ .insert = t }};
            s.ctx.input.ops = &ops;
            s.frame();
            s.ctx.input.ops = &.{};
            return true;
        },
        else => return false,
    };
    var ops = [1]ctx_mod.TextOp{op};
    s.ctx.input.ops = &ops;
    s.frame();
    s.ctx.input.ops = &.{};
    return true;
}
