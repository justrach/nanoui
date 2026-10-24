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

const runFor = @import("../platform.zig").runFor;

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

    /// Initializes in place (the context points into the tester) and runs
    /// the first frame.
    pub fn init(t: *Tester, gpa: std.mem.Allocator, view: View, opts: Options) !void {
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
        t.frame();
    }

    fn clipWrite(ctx: ?*anyopaque, text_: []const u8) void {
        const t: *Tester = @ptrCast(@alignCast(ctx));
        t.clipboard.clearRetainingCapacity();
        t.clipboard.appendSlice(t.gpa, text_) catch {};
    }

    pub fn deinit(t: *Tester) void {
        t.clipboard.deinit(t.gpa);
        t.instances.deinit(t.gpa);
        t.ctx.deinit();
        t.text.deinit();
        if (!portable) t.renderer.deinit();
    }

    pub fn frame(t: *Tester) void {
        _ = frame_mod.run(&t.ctx, t.view, &t.text, &t.instances, t.size, t.scale, t.theme, t.dt, t.time);
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
        } else if (t.ctx.wants_wheel) {
            t.ctx.input.scroll = .{ .y = dy };
            t.frame();
        }
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

    /// The rectangle of the text `s` in the last frame.
    pub fn findText(t: *Tester, s: []const u8) ?types.Rect {
        for (t.ctx.nodes.items) |n| switch (n.content) {
            .text => |tx| if (std.mem.eql(u8, tx.str, s)) return n.rect,
            .icon, .image, .texture, .canvas, .none => {},
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
            .icon, .image, .texture, .canvas, .none => {},
        };
        return false;
    }

    /// Clicks the middle of the text `s`.
    pub fn clickText(t: *Tester, s: []const u8) !void {
        const r = t.findText(s) orelse return error.TextNotFound;
        t.click(r.x + r.w / 2, r.y + r.h / 2);
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
        if (!portable) return t.renderer.drawOffscreen(gpa, t.instances.items, t.text.texture(), t.size, t.scale, t.theme.background);
        const w: usize = @intFromFloat(@max(1, @round(t.size.w * t.scale)));
        const h: usize = @intFromFloat(@max(1, @round(t.size.h * t.scale)));
        const out: gpu.Pixels = .{ .bytes = try gpa.alloc(u8, w * h * 4), .width = w, .height = h };
        var pictures = t.text.images.pictures();
        pictures.textures = t.ctx.textures.items;
        raster.draw(out, t.instances.items, t.text.atlas.mask(), pictures, t.scale, t.theme.background);
        return out;
    }

    /// Runs a script of steps separated by `;`: `click:TEXT`, `move:TEXT`,
    /// `type:TEXT`, `key:enter|backspace|tab|escape|left|right`,
    /// `scroll:DY` (at the pointer), `wait:SECONDS` (simulated time),
    /// `live:SECONDS` (the real event loop: replies, processes, timers),
    /// `resize:WxH`; `at:X,Y` and `hover:X,Y` (a click, or the pointer, at
    /// points), `chord:cmd+shift+n` (a key combination, as a window offers
    /// it), `snap:PNG` (the frame so far, written: one per step of a run).
    pub fn runScript(t: *Tester, script: []const u8) !void {
        var steps = std.mem.splitScalar(u8, script, ';');
        while (steps.next()) |raw| {
            const step = std.mem.trim(u8, raw, " ");
            if (step.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, step, ':') orelse step.len;
            const op = step[0..colon];
            const arg = if (colon < step.len) step[colon + 1 ..] else "";
            if (std.mem.eql(u8, op, "click")) {
                try t.clickText(arg);
            } else if (std.mem.eql(u8, op, "move")) {
                const r = t.findText(arg) orelse return error.TextNotFound;
                t.moveTo(r.x + r.w / 2, r.y + r.h / 2);
            } else if (std.mem.eql(u8, op, "type")) {
                t.typeText(arg);
            } else if (std.mem.eql(u8, op, "key")) {
                t.key(std.meta.stringToEnum(ctx_mod.Key, arg) orelse return error.UnknownKey);
            } else if (std.mem.eql(u8, op, "scroll")) {
                t.scroll(t.ctx.input.mouse.x, t.ctx.input.mouse.y, try std.fmt.parseFloat(f32, arg));
            } else if (std.mem.eql(u8, op, "wait")) {
                t.advance(try std.fmt.parseFloat(f32, arg));
            } else if (std.mem.eql(u8, op, "live")) {
                const seconds = try std.fmt.parseFloat(f64, arg);
                var waited: f64 = 0;
                while (waited < seconds) : (waited += 0.05) {
                    runFor(0.05);
                    t.frame();
                }
            } else if (std.mem.eql(u8, op, "at") or std.mem.eql(u8, op, "hover")) {
                const comma = std.mem.indexOfScalar(u8, arg, ',') orelse return error.BadPoint;
                const x = try std.fmt.parseFloat(f32, std.mem.trim(u8, arg[0..comma], " "));
                const y = try std.fmt.parseFloat(f32, std.mem.trim(u8, arg[comma + 1 ..], " "));
                if (op[0] == 'a') t.click(x, y) else t.moveTo(x, y);
            } else if (std.mem.eql(u8, op, "chord")) {
                const s = ctx_mod.Shortcut.parse(arg) orelse return error.UnknownKey;
                _ = t.shortcut(s.native());
            } else if (std.mem.eql(u8, op, "snap")) {
                t.settle(2);
                try t.screenshot(arg);
                continue;
            } else if (std.mem.eql(u8, op, "resize")) {
                const x = std.mem.indexOfScalar(u8, arg, 'x') orelse return error.BadSize;
                t.resize(try std.fmt.parseFloat(f32, arg[0..x]), try std.fmt.parseFloat(f32, arg[x + 1 ..]));
            } else return error.UnknownStep;
            t.settle(2);
        }
    }
};
