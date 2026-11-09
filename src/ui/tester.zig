//! Views tested without a window: the same frames a window runs, input
//! simulated in process, time advanced by hand, and frames rendered
//! offscreen to PNG files (by Metal on macOS, by the CPU renderer where
//! text is nanoui's own). Nothing reaches the screen, the mouse or the
//! keyboard.
//!
//!     var t: ui.Tester = undefined;
//!     try t.init(gpa, .init(&state, State.view), .{});
//!     defer t.deinit();
//!     try t.clickText("Increment");
//!     try std.testing.expect(t.hasText("1"));
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const text = @import("text.zig");
const raster = @import("raster.zig");
const portable = text.portable;
const metal = if (portable) struct {
    pub const Renderer = void;
} else @import("metal.zig");
const image = if (portable) void else @import("image.zig");
const frame_mod = @import("frame.zig");
const Theme = @import("theme.zig").Theme;
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const View = @import("ui.zig").View;

const platform = @import("../platform.zig");
const runFor = platform.runFor;
const script = @import("tester_script.zig");

pub const Options = struct {
    width: f32 = 480,
    height: f32 = 360,
    scale: f32 = 2,
    dark: bool = false,
    /// Colors of its own, as a window's `theme` option gives.
    theme: ?Theme = null,
};

pub const Tester = struct {
    gpa: std.mem.Allocator,
    renderer: metal.Renderer,
    text: text.TextSystem,
    ctx: Context,
    view: View,
    size: types.Size,
    scale: f32,
    theme: Theme,
    instances: std.ArrayList(gpu.Instance) = .empty,
    /// Seconds each frame advances animations by.
    dt: f32 = 1.0 / 60.0,
    /// What copy and cut wrote: tests never touch the system's clipboard.
    clipboard: std.ArrayList(u8) = .empty,
    /// The simulated clock, advanced by `dt` each frame.
    time: f64 = 0,
    /// The app's own script steps (`cmd:…`), tried after nanoui's.
    app_verbs: ?AppVerbs = null,
    /// Another thread asked for a frame (`requestFrameFromAnyThread`).
    woken: std.atomic.Value(bool) = .init(false),

    /// A script step nanoui doesn't know, offered to the app: true if it
    /// ran it (`op` is before the colon, `arg` after).
    pub const AppVerbs = struct {
        ctx: ?*anyopaque = null,
        run: *const fn (ctx: ?*anyopaque, t: *Tester, op: []const u8, arg: []const u8) anyerror!bool,
    };

    /// Initializes in place (the context points into the tester) and runs
    /// the first frame.
    pub fn init(t: *Tester, gpa: std.mem.Allocator, view: View, opts: Options) !void {
        if (@import("../rt.zig").enabled) {
            const Ext = struct { extern fn nanoui_rt_tester_init(t: *Tester, gpa_ptr: *const std.mem.Allocator, view_ptr: *const View, opts_ptr: *const Options) callconv(.c) u8; };
            if (Ext.nanoui_rt_tester_init(t, &gpa, &view, &opts) != 0) return error.TesterInitFailed;
            return;
        }
        return t.initImpl(gpa, view, opts);
    }

    pub fn initImpl(t: *Tester, gpa: std.mem.Allocator, view: View, opts: Options) !void {
        var renderer: metal.Renderer = if (portable) {} else try metal.Renderer.init();
        errdefer if (!portable) renderer.deinit();
        t.* = .{
            .gpa = gpa,
            .renderer = renderer,
            .text = if (portable) .init(gpa) else .init(gpa, renderer.device),
            .ctx = undefined,
            .view = view,
            .size = .{ .w = opts.width, .h = opts.height },
            .scale = opts.scale,
            .theme = opts.theme orelse if (opts.dark) Theme.dark_theme else Theme.light,
        };
        t.text.setScale(opts.scale);
        t.ctx = .init(gpa, &t.text);
        t.ctx.clipboard = .{ .ctx = t, .write = clipWrite };
        t.ctx.waker = .{ .ctx = t, .wake = wakeFrom };
        t.frame();
    }

    fn wakeFrom(ctx: *anyopaque) void {
        const t: *Tester = @ptrCast(@alignCast(ctx));
        t.requestFrameFromAnyThread();
    }

    /// From any thread (a decoder's): a frame is wanted. `pump` returns
    /// early to run it.
    pub fn requestFrameFromAnyThread(t: *Tester) void {
        if (t.woken.swap(true, .acq_rel)) return;
        platform.wakeMain();
    }

    fn clipWrite(ctx: ?*anyopaque, text_: []const u8) void {
        const t: *Tester = @ptrCast(@alignCast(ctx));
        t.clipboard.clearRetainingCapacity();
        t.clipboard.appendSlice(t.gpa, text_) catch {};
    }

    pub fn deinit(t: *Tester) void {
        if (@import("../rt.zig").enabled) {
            const Ext = struct { extern fn nanoui_rt_tester_deinit(t: *Tester) callconv(.c) void; };
            return Ext.nanoui_rt_tester_deinit(t);
        }
        t.deinitImpl();
    }

    pub fn deinitImpl(t: *Tester) void {
        t.clipboard.deinit(t.gpa);
        t.instances.deinit(t.gpa);
        t.ctx.deinit();
        t.text.deinit();
        if (!portable) t.renderer.deinit();
    }

    pub fn frame(t: *Tester) void {
        if (@import("../rt.zig").enabled) {
            const Ext = struct { extern fn nanoui_rt_tester_frame(t: *Tester) callconv(.c) void; };
            return Ext.nanoui_rt_tester_frame(t);
        }
        t.frameImpl();
    }

    pub fn frameImpl(t: *Tester) void {
        _ = frame_mod.run(&t.ctx, t.view, &t.text, &t.instances, t.size, t.scale, t.theme, t.dt, t.time);
        // The simulated clock is the real one here: a view reads its rate off it.
        t.ctx.frame_time = t.dt;
        t.time += t.dt;
    }

    /// Runs frames until animations settle (at most `max_seconds` of them).
    pub fn settle(t: *Tester, max_seconds: f32) void {
        var elapsed: f32 = 0;
        t.frame();
        while (t.ctx.animating and elapsed < max_seconds) : (elapsed += t.dt) t.frame();
    }

    /// Advances time by `seconds`, a frame at a time.
    pub fn advance(t: *Tester, seconds: f32) void {
        var elapsed: f32 = 0;
        while (elapsed < seconds) : (elapsed += t.dt) t.frame();
    }

    pub fn resize(t: *Tester, w: f32, h: f32) void {
        t.size = .{ .w = w, .h = h };
        t.frame();
    }

    pub fn moveTo(t: *Tester, x: f32, y: f32) void {
        t.ctx.input.mouse = .{ .x = x, .y = y };
        t.ctx.updateHot();
        t.frame();
    }

    /// Two clicks in quick succession: the second is a double click.
    pub fn doubleClick(t: *Tester, x: f32, y: f32) void {
        t.click(x, y);
        t.moveTo(x, y);
        t.ctx.input.click_count = 2;
        t.ctx.pointerDown();
        t.frame();
        t.ctx.pointerUp();
        t.frame();
        t.ctx.input.click_count = 1;
    }

    pub fn click(t: *Tester, x: f32, y: f32) void {
        t.moveTo(x, y);
        t.ctx.input.click_count = 1;
        t.ctx.pointerDown();
        t.frame();
        t.ctx.pointerUp();
        t.frame();
    }

    /// A right-click at (x, y): a box's context menu.
    pub fn secondaryClick(t: *Tester, x: f32, y: f32) void {
        t.moveTo(x, y);
        t.ctx.secondaryDown();
        t.frame();
    }

    pub fn drag(t: *Tester, x1: f32, y1: f32, x2: f32, y2: f32) void {
        t.moveTo(x1, y1);
        t.ctx.pointerDown();
        t.frame();
        var i: f32 = 1;
        while (i <= 8) : (i += 1) {
            t.ctx.input.mouse = .{ .x = x1 + (x2 - x1) * i / 8, .y = y1 + (y2 - y1) * i / 8 };
            t.frame();
        }
        t.ctx.pointerUp();
        t.frame();
    }

    /// The pointer goes down at (x, y) and stays down (`move`, `up`), with
    /// the modifier keys `setMods` left.
    pub fn down(t: *Tester, x: f32, y: f32) void {
        t.moveTo(x, y);
        t.ctx.input.click_count = 1;
        t.ctx.pointerDown();
        t.frame();
    }

    /// The pointer moves to (x, y), held down or not.
    pub fn move(t: *Tester, x: f32, y: f32) void {
        t.ctx.input.mouse = .{ .x = x, .y = y };
        if (!t.ctx.input.down) t.ctx.updateHot();
        t.frame();
    }

    pub fn up(t: *Tester) void {
        t.ctx.pointerUp();
        t.frame();
        t.ctx.updateHot();
    }

    pub fn typeText(t: *Tester, s: []const u8) void {
        t.ctx.input.chars = s;
        t.frame();
    }

    /// Sends text input operations, as AppKit's input system would.
    pub fn textOps(t: *Tester, ops: []const ctx_mod.TextOp) void {
        t.ctx.input.ops = ops;
        t.frame();
        t.ctx.input.ops = &.{};
    }

    /// Offers a key combination, as a window does before text editing;
    /// true if the view took it.
    pub fn shortcut(t: *Tester, s: ctx_mod.Shortcut) bool {
        t.ctx.shortcut_taken = false;
        t.ctx.input.shortcut = s;
        t.frame();
        t.ctx.input.shortcut = null;
        return t.ctx.shortcut_taken;
    }

    pub fn key(t: *Tester, k: ctx_mod.Key) void {
        t.ctx.input.key = k;
        t.frame();
    }

    pub fn scroll(t: *Tester, x: f32, y: f32, dy: f32) void {
        t.ctx.input.mouse = .{ .x = x, .y = y };
        if (t.ctx.applyScroll(dy)) {
            t.frame();
        } else if (t.ctx.wants_wheel or t.ctx.wheelAt()) {
            t.ctx.input.scroll = .{ .y = dy };
            t.frame();
        }
        t.ctx.updateHot();
    }

    /// A click with the right button (a context menu) or the middle one.
    pub fn rightClick(t: *Tester, x: f32, y: f32) void {
        t.clickWith(.right, x, y);
    }

    pub fn middleClick(t: *Tester, x: f32, y: f32) void {
        t.clickWith(.middle, x, y);
    }

    fn clickWith(t: *Tester, button: @import("input.zig").Button, x: f32, y: f32) void {
        t.ctx.input.button = button;
        t.click(x, y);
        t.ctx.input.button = .left;
    }

    /// The modifier keys change alone, as a window's `flagsChanged:`.
    pub fn setMods(t: *Tester, m: struct { cmd: bool = false, ctrl: bool = false, alt: bool = false, shift: bool = false }) void {
        t.ctx.input.cmd = m.cmd;
        t.ctx.input.ctrl = m.ctrl;
        t.ctx.input.alt = m.alt;
        t.ctx.input.shift = m.shift;
        t.ctx.input.mods_changed = true;
        t.frame();
    }

    /// A sideways scroll of `dx` at `x`, `y` (`input.scroll.x`).
    pub fn hscroll(t: *Tester, x: f32, y: f32, dx: f32) void {
        t.ctx.input.mouse = .{ .x = x, .y = y };
        t.ctx.input.scroll = .{ .x = dx };
        t.frame();
        t.ctx.updateHot();
    }

    /// Pinches about (x, y): spread by `factor`, the fingers moved together
    /// by (dx, dy), as two fingers on a touch screen do.
    pub fn pinch(t: *Tester, x: f32, y: f32, factor: f32, dx: f32, dy: f32) void {
        t.ctx.input.mouse = .{ .x = x, .y = y };
        t.ctx.input.zoom = factor;
        t.ctx.input.pan = .{ .x = dx, .y = dy };
        t.frame();
        t.ctx.updateHot();
    }

    /// Drops links (`urls`) or `text` at `x`, `y`, as from another app.
    pub fn drop(t: *Tester, x: f32, y: f32, urls: []const []const u8, text_: []const u8) void {
        t.ctx.input.drag_over = .{ .x = x, .y = y };
        t.frame();
        t.ctx.input.drag_over = null;
        t.ctx.input.drop = .{ .point = .{ .x = x, .y = y }, .urls = urls, .text = text_ };
        t.frame();
    }
    /// The rectangle of the text `s` in the last frame.
    pub fn findText(t: *Tester, s: []const u8) ?types.Rect {
        for (t.ctx.nodes.items) |n| switch (n.content) {
            .text => |tx| if (std.mem.eql(u8, tx.str, s)) return n.rect,
            .icon, .image, .texture, .hole, .canvas, .none => {},
        };
        return null;
    }

    pub fn hasText(t: *Tester, s: []const u8) bool {
        return t.findText(s) != null;
    }

    /// Whether a text drawn contains `s` (a terminal's row, a paragraph).
    pub fn containsText(t: *Tester, s: []const u8) bool {
        for (t.ctx.nodes.items) |n| switch (n.content) {
            .text => |tx| if (std.mem.indexOf(u8, tx.str, s) != null) return true,
            .icon, .image, .texture, .hole, .canvas, .none => {},
        };
        return false;
    }

    /// Puts the pointer on the middle of text `s`, without a click.
    pub fn hoverText(t: *Tester, s: []const u8) !void {
        const r = t.findText(s) orelse return error.TextNotFound;
        t.moveTo(r.x + r.w / 2, r.y + r.h / 2);
    }

    /// The tooltip in the last frame (empty text for custom drawn content).
    pub fn tooltipText(t: *Tester) ?[]const u8 {
        return if (t.ctx.tooltip.shown) |s| s.text else null;
    }

    pub fn tooltipRect(t: *Tester) ?types.Rect {
        const s = t.ctx.tooltip.shown orelse return null;
        return t.ctx.rects.get(s.id);
    }

    /// Clicks the middle of the text `s`.
    pub fn clickText(t: *Tester, s: []const u8) !void {
        const r = t.findText(s) orelse return error.TextNotFound;
        t.click(r.x + r.w / 2, r.y + r.h / 2);
    }

    /// Runs the real event loop for `seconds` (replies, timers, work posted
    /// to the main queue from other threads), then a frame; sooner if
    /// another thread asks for a frame (`requestFrameFromAnyThread`).
    pub fn pump(t: *Tester, seconds: f64) void {
        platform.runUntil(seconds, &t.woken);
        t.woken.store(false, .release);
        t.frame();
    }

    /// Renders the last frame offscreen and writes it to a PNG file.
    pub fn screenshot(t: *Tester, path: []const u8) !void {
        const pixels = try t.render(t.gpa);
        defer pixels.deinit(t.gpa);
        if (portable) {
            try @import("png.zig").writePng(t.gpa, std.Io.Threaded.global_single_threaded.io(), path, pixels);
        } else try image.writePng(path, pixels);
    }

    /// The last frame's pixels (BGRA, premultiplied); free with `deinit`.
    pub fn render(t: *Tester, gpa: std.mem.Allocator) !gpu.Pixels {
        if (!portable) t.renderer.syncImages(&t.text.images);
        if (!portable) t.renderer.textures = t.ctx.textures.items;
        if (!portable) t.renderer.gradients = t.ctx.gradients.items;
        if (!portable) return t.renderer.drawOffscreen(gpa, t.instances.items, t.text.texture(), t.size, t.scale, t.ctx.theme.background);
        const w: usize = @intFromFloat(@max(1, @round(t.size.w * t.scale)));
        const h: usize = @intFromFloat(@max(1, @round(t.size.h * t.scale)));
        const out: gpu.Pixels = .{ .bytes = try gpa.alloc(u8, w * h * 4), .width = w, .height = h };
        var pictures = t.text.images.pictures();
        pictures.textures = t.ctx.textures.items;
        pictures.gradients = t.ctx.gradients.items;
        raster.draw(out, t.instances.items, t.text.atlas.mask(), pictures, t.scale, t.ctx.theme.background);
        return out;
    }

    /// Runs a script of steps separated by `;` (`tester_script.zig` lists
    /// them): `click:TEXT`, `at:X,Y`, `down:X,Y`/`move:X,Y`/`up`,
    /// `mods:cmd+shift`, `drop:X,Y,PATH|PATH`, `type:TEXT`, `key:enter`,
    /// `chord:cmd+shift+n`, `wait:SECONDS`, `snap:PNG`, and the app's own
    /// (`app_verbs`).
    pub fn runScript(t: *Tester, steps: []const u8) !void {
        return script.run(t, steps);
    }
};
