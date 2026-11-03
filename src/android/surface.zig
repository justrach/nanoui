//! Native UI on Android: a window's frames, drawn into the activity's
//! window when it is the top one, with OpenGL ES 3 (the Linux renderer's
//! shaders, in GLSL ES) or, without it, the CPU renderer copied into the
//! window's buffer. Frames run on input, when the screen changes, or at
//! each refresh while something moves (the app's choreographer); idle,
//! nothing runs. Touches become the pointer (`touch.zig`), keys and the
//! software keyboard's text input (`keys.zig`). The view is laid out
//! inside the safe area unless the window is `full_bleed`; either way
//! `Context.safe_area` says what the bars, the cutout and the keyboard
//! cover.
const std = @import("std");
const ndk = @import("ndk.zig");
const activity = @import("activity.zig");
const types = @import("../ui/types.zig");
const gpu = @import("../ui/gpu.zig");
const canvas = @import("../ui/canvas.zig");
const opengl = @import("../ui/opengl.zig");
const text = @import("../ui/text.zig");
const frame_mod = @import("../ui/frame.zig");
const clock = @import("../ui/clock.zig");
const Theme = @import("../ui/theme.zig").Theme;
const Context = @import("../ui/context.zig").Context;
const ui = @import("../ui/ui.zig");
const Window = @import("window.zig").Window;
const App = @import("app.zig").App;
const touch = @import("touch.zig");
const keys = @import("keys.zig");

pub const Surface = struct {
    gpa: std.mem.Allocator,
    /// Its window, until the window goes (`dead`); the app, which outlives it.
    window: *Window,
    app: *App,
    text: text.TextSystem,
    ctx: Context,
    view: ui.View,
    instances: std.ArrayList(gpu.Instance) = .empty,
    /// The GPU's renderer, made on the first frame OpenGL ES draws.
    renderer: ?opengl.Renderer = null,
    /// The CPU's pixels, where it draws.
    pixels: canvas.Canvas = .{},
    size: types.Size = .{},
    scale: f32 = 2,
    /// What the bars and the cutout cover, and the keyboard over the
    /// view's bottom, in points.
    insets: types.Edges = .{},
    keyboard: f32 = 0,
    last_frame_time: f64 = 0,
    start_time: f64,
    theme_override: ?Theme,
    full_bleed: bool,
    touch: touch.State = .{},
    keys: keys.State,
    /// A frame was wanted while none could run (no screen, covered, or
    /// during another frame: a dialog waits inside it). It runs when it can.
    pending: bool = false,
    in_frame: bool = false,
    /// The screen changed during a frame: the next frame takes it.
    stale_geometry: bool = false,
    /// Input handlers running now: a surface destroyed by one (a tap that
    /// closes its window) is freed when the last returns.
    depth: u32 = 0,
    dead: bool = false,

    pub fn create(window: *Window, view: ui.View, theme_override: ?Theme, full_bleed: bool) !*Surface {
        const gpa = window.app.gpa;
        const self = try gpa.create(Surface);
        self.* = .{
            .gpa = gpa,
            .window = window,
            .app = window.app,
            .text = .init(gpa),
            .ctx = undefined,
            .view = view,
            .theme_override = theme_override,
            .full_bleed = full_bleed,
            .start_time = clock.now(),
            .keys = .init(gpa),
        };
        self.ctx = .init(gpa, &self.text);
        self.ctx.reduced_motion = window.app.reduced_motion;
        self.updateGeometry();
        return self;
    }

    /// For one input event: pair with `leave`. After a frame, a handler
    /// checks `dead` before touching the surface again.
    pub fn enter(s: *Surface) *Surface {
        s.depth += 1;
        return s;
    }

    pub fn leave(s: *Surface) void {
        s.depth -= 1;
        if (s.depth == 0 and s.dead and !s.in_frame) s.free();
    }

    /// Frees the surface, or marks it to be freed once the handler or
    /// frame running now returns.
    pub fn destroy(self: *Surface) void {
        if (self.depth > 0 or self.in_frame) {
            self.dead = true;
            return;
        }
        self.free();
    }

    fn free(self: *Surface) void {
        if (self.renderer) |*r| if (self.app.makeCurrent()) r.deinit();
        keys.detach(self);
        self.instances.deinit(self.gpa);
        self.pixels.deinit(self.gpa);
        self.keys.deinit(self.gpa);
        self.ctx.deinit();
        self.text.deinit();
        self.gpa.destroy(self);
    }

    /// The screen's size, scale and insets, as the app last read them.
    pub fn updateGeometry(self: *Surface) void {
        // In a frame (a dialog waits inside it): its sizes stay until it
        // ends, and the next frame takes the new ones.
        if (self.in_frame) {
            self.stale_geometry = true;
            self.pending = true;
            return;
        }
        self.stale_geometry = false;
        const app = self.app;
        if (app.screen_w <= 0 or app.screen_h <= 0) return;
        const k = app.scale;
        self.scale = k;
        self.size = .{ .w = @as(f32, @floatFromInt(app.screen_w)) / k, .h = @as(f32, @floatFromInt(app.screen_h)) / k };
        const i = activity.insets;
        self.insets = .{ .top = px(i.bars[0], k), .left = px(i.bars[1], k), .bottom = px(i.bars[2], k), .right = px(i.bars[3], k) };
        self.keyboard = px(i.keyboard, k);
        self.text.setScale(k);
    }

    fn px(v: i32, scale: f32) f32 {
        return @as(f32, @floatFromInt(v)) / scale;
    }

    /// What the system covers: the bars, and the keyboard over them.
    pub fn safeArea(self: *Surface) types.Edges {
        var e = self.insets;
        e.bottom = @max(e.bottom, self.keyboard);
        return e;
    }

    fn theme(self: *Surface) Theme {
        if (self.theme_override) |t| return t;
        return if (self.app.dark) Theme.dark_theme else Theme.light;
    }

    fn canDraw(self: *Surface) bool {
        return self.window.shown and self.app.screen != null and self.size.w > 0 and self.size.h > 0;
    }

    /// Builds, lays out, paints and draws one frame.
    pub fn frame(self: *Surface) void {
        if (self.dead) return;
        if (self.stale_geometry) self.updateGeometry();
        if (self.in_frame or !self.canDraw()) {
            // Waits: the frame running (a dialog's wait is inside it) asks
            // for another as it ends; a screen coming back draws it.
            self.pending = true;
            return;
        }
        self.pending = false;
        self.in_frame = true;
        const c = &self.ctx;
        const now = clock.now();
        const dt: f32 = if (self.last_frame_time > 0) @floatCast(@min(now - self.last_frame_time, 0.1)) else 1.0 / 60.0;
        self.last_frame_time = now;
        c.safe_area = self.safeArea();
        const root: ui.View = if (self.full_bleed) self.view else .init(self, insideSafeArea);
        const r = frame_mod.run(c, root, &self.text, &self.instances, self.size, self.scale, self.theme(), dt, now - self.start_time);
        if (self.dead) {
            // The view closed its window: nothing left to draw into.
            self.in_frame = false;
            if (self.depth == 0) self.free();
            return;
        }
        // A dialog waited inside the frame, and another window may cover
        // this one since: the frame waits for it to show again.
        if (self.canDraw()) self.present() else self.pending = true;
        self.in_frame = false;
        const app = self.app;
        app.barsFor(!c.theme.dark);
        // No hover on a touch screen: what changed under a finger already drew.
        const more = c.animating or r.hot_changed or self.touch.flinging();
        if (more or self.pending) app.wantFrame() else if (c.frame_in) |s| app.wantFrameIn(s);
        if (!c.animating) self.last_frame_time = 0;
        // After the pace: the keyboard coming or going changes the insets.
        keys.syncFocus(self);
    }

    /// The app's view inside the safe area; the view sees none left.
    fn insideSafeArea(self: *Surface, c: *Context) void {
        const box = ui.div(c).column().sizeFull().safeArea();
        defer box.end();
        c.safe_area = .{};
        defer c.safe_area = self.safeArea();
        self.view.build(self.view.ptr, c);
    }

    /// Puts the frame painted on the screen.
    fn present(self: *Surface) void {
        const app = self.app;
        if (app.gl) |*g| {
            // OpenGL ES failing once it worked (a lost context) would leave
            // the screen as it was while the app goes on: the CPU draws.
            if (!g.makeCurrent()) {
                app.cpuFromNow();
                return self.presentCpu();
            }
            if (self.renderer == null) {
                self.renderer = opengl.Renderer.initEs() catch {
                    std.log.warn("nanoui: OpenGL ES renderer failed: drawing on the CPU", .{});
                    app.cpuFromNow();
                    return self.presentCpu();
                };
                self.ctx.renderer = "OpenGL ES";
            }
            const r = &self.renderer.?;
            r.sync(self.text.atlas.mask(), self.text.atlas.generation, self.text.images.pictures(), self.text.images.generation);
            r.draw(self.instances.items, self.size, self.scale, self.ctx.theme.background, 0, self.ctx.time);
            if (g.swap()) return;
            app.cpuFromNow();
        }
        self.presentCpu();
    }

    /// The CPU's frame, drawn where it changed, copied into the window.
    fn presentCpu(self: *Surface) void {
        const win = self.app.screen orelse return;
        self.pixels.draw(self.gpa, .{
            .instances = self.instances.items,
            .text = &self.text,
            .clear = self.ctx.theme.background,
            .size = self.size,
            .scale = self.scale,
            .textures = self.ctx.textures.items,
        });
        const p = &self.pixels;
        if (p.bytes.len == 0) return;
        var buf: ndk.ANativeWindow_Buffer = undefined;
        if (ndk.ANativeWindow_lock(win, &buf, null) != 0) return;
        defer _ = ndk.ANativeWindow_unlockAndPost(win);
        const bits = buf.bits orelse return;
        const w = @min(p.width, @as(usize, @intCast(@max(0, buf.width))));
        const h = @min(p.height, @as(usize, @intCast(@max(0, buf.height))));
        const stride: usize = @intCast(@max(0, buf.stride));
        for (0..h) |y| bgraToRgba(bits[y * stride * 4 ..][0 .. w * 4], p.bytes[y * p.width * 4 ..][0 .. w * 4]);
    }

    /// A frame at the display's next refresh: for changes from outside
    /// the view (a process's output, a network reply). Covered, it waits.
    pub fn requestFrame(self: *Surface) void {
        if (self.dead) return;
        if (!self.window.shown) {
            self.pending = true;
            return;
        }
        self.app.wantFrame();
    }

    /// Another window covers this one: a touch it had goes, and the
    /// keyboard (it comes back with the next frame, if a field still has
    /// the focus).
    pub fn covered(self: *Surface) void {
        keys.detach(self);
        self.touch.stop();
        self.touch = .{};
        self.ctx.input.mouse = .{ .x = -1e6, .y = -1e6 };
        if (self.ctx.input.down) self.ctx.pointerUp();
    }

    /// The app went to the background: what moves stops, to go on later.
    pub fn stopMotion(self: *Surface) void {
        self.touch.stop();
        self.pending = true;
    }
};

/// The renderer's BGRA, as the window's RGBA.
fn bgraToRgba(dst: []u8, src: []const u8) void {
    const V = @Vector(16, u8);
    const swap = [16]i32{ 2, 1, 0, 3, 6, 5, 4, 7, 10, 9, 8, 11, 14, 13, 12, 15 };
    var i: usize = 0;
    while (i + 16 <= src.len) : (i += 16) {
        const v: V = src[i..][0..16].*;
        dst[i..][0..16].* = @shuffle(u8, v, undefined, swap);
    }
    while (i + 4 <= src.len) : (i += 4) {
        dst[i..][0..4].* = .{ src[i + 2], src[i + 1], src[i], src[i + 3] };
    }
}

test "BGRA becomes RGBA" {
    var src: [40]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);
    var dst: [40]u8 = undefined;
    bgraToRgba(&dst, &src);
    for (0..10) |p| try std.testing.expectEqualSlices(u8, &.{ src[p * 4 + 2], src[p * 4 + 1], src[p * 4], src[p * 4 + 3] }, dst[p * 4 ..][0..4]);
}
