//! The macOS surface's pace: its CAMetalDisplayLink (made, dropped, and
//! its tick), the link's cap at the screen's rate (or an app's `setFpsCap`),
//! and how a live resize's steps are drawn (in the window's transaction, or
//! by the link while the drag moves).
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const Surface = @import("surface.zig").Surface;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" const NSRunLoopCommonModes: objc.Object;

/// The CAMetalDisplayLink that paces frames and hands out drawables.
pub fn startLink(self: *Surface) void {
    if (self.display_link != null) return;
    const link = objc.msg(objc.Object, objc.alloc("CAMetalDisplayLink"), "initWithMetalLayer:", .{self.renderer.layer});
    objc.msg(void, link, "setDelegate:", .{self.nsview});
    objc.msg(void, link, "setPaused:", .{objc.YES});
    const loop = objc.msg(objc.Object, objc.class("NSRunLoop"), "mainRunLoop", .{});
    objc.msg(void, link, "addToRunLoop:forMode:", .{ loop, NSRunLoopCommonModes });
    self.display_link = link;
    self.paced = false;
    self.link_fps = -1;
}

/// Drops the link: a layer with one attached refuses `nextDrawable`,
/// and a live resize draws its steps in the window's transaction with
/// drawables taken from the layer.
pub fn stopLink(self: *Surface) void {
    const link = self.display_link orelse return;
    objc.msg(void, link, "setDelegate:", .{@as(?objc.Object, null)});
    objc.msg(void, link, "invalidate", .{});
    objc.release(link);
    self.display_link = null;
    self.paced = false;
}

pub fn updateMaxFps(self: *Surface) void {
    const screen = objc.msg(?objc.Object, self.window.nswindow, "screen", .{});
    const screen_fps: f32 = if (screen) |sc| @floatFromInt(@max(60, objc.msg(objc.NSInteger, sc, "maximumFramesPerSecond", .{}))) else 60;
    const fps = if (self.fps_cap > 0) @min(self.fps_cap, screen_fps) else screen_fps;
    if (fps != self.max_fps) {
        self.max_fps = fps;
        const cur = self.link_fps;
        self.link_fps = -1;
        if (cur >= 0) self.setRate(if (cur == 0) null else 1 / cur);
    }
}

/// Caps the display link's pace at `fps` (0 lifts the cap).
pub fn setFpsCap(self: *Surface, fps: f32) void {
    self.fps_cap = fps;
    self.updateMaxFps();
}

/// How long the link keeps running after a live-resize step: a drag's
/// next step lands on a running link, and a held mouse stops it.
const resize_grace = 0.25;

/// A live resize is changing the size now: a held mouse is not.
pub fn resizeStepping(self: *Surface) bool {
    return self.ctx.live_resizing and cf.CACurrentMediaTime() - self.resize_step_at < resize_grace;
}

/// One live-resize step drawn in the window's own transaction: the
/// frame is laid out and presented at this size before Core Animation
/// composites the step, so the window never shows a stale one. False
/// when it can't (hidden, or `NANOUI_RESIZE_SYNC=0`): the link draws.
pub fn resizeSyncEnabled(_: *Surface) bool {
    if (getenv("NANOUI_RESIZE_SYNC")) |v| if (std.mem.eql(u8, std.mem.span(v), "0")) return false;
    return true;
}

pub fn resizeInTransaction(self: *Surface) bool {
    if (self.in_frame or self.dead or !self.visible() or self.display_link != null) return false;
    if (!self.resizeSyncEnabled()) return false;
    const drawable = objc.msg(?objc.Object, self.renderer.layer, "nextDrawable", .{}) orelse return false;
    self.renderer.given_drawable = drawable;
    defer self.renderer.given_drawable = null;
    self.pending_sync = true;
    self.full_pending = true;
    const now = @max(cf.CACurrentMediaTime(), self.last_frame_time);
    const fallback_dur = 1.0 / @as(f64, @max(60.0, self.max_fps));
    self.frameAt(.input, now, if (self.link_duration > 0) self.link_duration else fallback_dur);
    return true;
}

pub fn metalDisplayLinkNeedsUpdate(obj: objc.Object, _: objc.SEL, _: objc.Object, update: objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    if (s.dead or s.in_frame) return;
    s.wake.last_tick = cf.CACurrentMediaTime();
    const target = objc.msg(f64, update, "targetPresentationTimestamp", .{});
    const frame_in_due = s.ctx.frame_in != null and target >= s.frame_in_due - 0.001;
    if (!s.full_pending and !frame_in_due and !s.ctx.animating and !s.geometry_changed and !s.retained_ready and !s.pending_sync and s.ctx.time_driven == .none) {
        s.updatePacing(target, false);
        return;
    }
    const drawable = objc.msg(?objc.Object, update, "drawable", .{}) orelse return;
    const duration: f64 = if (s.link_fps > 0) 1.0 / @as(f64, s.link_fps) else 1.0 / @as(f64, @max(60.0, s.max_fps));
    s.renderer.given_drawable = drawable;
    defer s.renderer.given_drawable = null;
    if (!s.full_pending and !frame_in_due and !s.ctx.animating and !s.geometry_changed and (s.retained_ready or (!s.pending_sync and s.ctx.time_driven != .none))) {
        s.redrawRetained(target, duration);
        return;
    }
    s.frameAt(.link, target, duration);
}

pub fn liveResizeStart(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    objc.msgSuper(void, obj, objc.class("NSView"), "viewWillStartLiveResize", .{});
    const s = objc.getZig(Surface, obj) orelse return;
    // Each step is laid out and presented in the resize's own transaction
    // (`resizeInTransaction`, from `setFrameSize`), so the window never
    // composites a stale frame, and the link stops meanwhile. With that
    // off (`NANOUI_RESIZE_SYNC=0`) the link draws each step instead; held
    // still, it stops after a moment (`resizeStepping`).
    s.ctx.live_resizing = true;
    s.resize_step_at = cf.CACurrentMediaTime();
    if (s.resizeSyncEnabled()) s.stopLink();
    s.requestFrame();
}

pub fn liveResizeEnd(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    objc.msgSuper(void, obj, objc.class("NSView"), "viewDidEndLiveResize", .{});
    const s = objc.getZig(Surface, obj) orelse return;
    s.ctx.live_resizing = false;
    s.startLink();
    s.requestFrame();
}

pub fn setFrameSize(obj: objc.Object, _: objc.SEL, size: objc.CGSize) callconv(.c) void {
    objc.msgSuper(void, obj, objc.class("NSView"), "setFrameSize:", .{size});
    const s = objc.getZig(Surface, obj) orelse return;
    s.updateGeometry();
    // In a drag the link's next frame lays out at this size: a frame now
    // would have no drawable to present.
    if (s.ctx.live_resizing) {
        s.resize_step_at = cf.CACurrentMediaTime();
        if (s.resizeInTransaction()) return;
        return s.requestFrame();
    }
    s.frame();
}
