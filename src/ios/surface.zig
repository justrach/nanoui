//! Native UI on iOS: a UIView hosting the Metal layer, drawing frames on
//! demand as on the Mac: on a touch, a key, a resize, or while something
//! animates, paced by a CADisplayLink that is paused when nothing moves.
//! Touches become the pointer (`touch.zig`), keys and the software
//! keyboard text input (`keys.zig`). The view is laid out inside the safe
//! area unless the window is `full_bleed`; either way `Context.safe_area`
//! says what the status bar, the home indicator and the keyboard cover.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("../ui/cf.zig");
const types = @import("../ui/types.zig");
const metal = @import("../ui/metal.zig");
const text = @import("../ui/text.zig");
const frame_mod = @import("../ui/frame.zig");
const Theme = @import("../ui/theme.zig").Theme;
const ctx_mod = @import("../ui/context.zig");
const Context = ctx_mod.Context;
const ui = @import("../ui/ui.zig");
const Window = @import("window.zig").Window;
const touch = @import("touch.zig");
const keys = @import("keys.zig");
const fold = @import("fold.zig");

extern "c" fn UIAccessibilityIsReduceMotionEnabled() bool;
extern "c" const NSRunLoopCommonModes: objc.Object;

/// UIEdgeInsets.
const Insets = extern struct { top: f64, left: f64, bottom: f64, right: f64 };

pub const Surface = struct {
    gpa: std.mem.Allocator,
    window: *Window,
    uiview: objc.Object,
    renderer: metal.Renderer,
    text: text.TextSystem,
    ctx: Context,
    view: ui.View,
    instances: std.ArrayList(metal.Instance) = .empty,
    size: types.Size = .{},
    scale: f32 = 2,
    last_frame_time: f64 = 0,
    start_time: f64 = 0,
    display_link: ?objc.Object = null,
    link_fps: f32 = 0,
    /// A frame was wanted while none could run: in the background, or
    /// during another frame (a dialog's run loop). It runs when it can.
    pending: bool = false,
    in_frame: bool = false,
    theme_override: ?Theme = null,
    full_bleed: bool,
    /// What the system covers: the view's safe area insets, and the
    /// keyboard's height over the view's bottom.
    insets: types.Edges = .{},
    keyboard: f32 = 0,
    touch: touch.State = .{},
    keys: keys.State,
    /// Handlers of UIKit's events running now: a surface destroyed by one
    /// (a tap that closes its window) is freed when the last returns.
    depth: u32 = 0,
    dead: bool = false,
    /// The view's size changed during a frame: the next frame takes it.
    stale_geometry: bool = false,
    /// The UIHingeInteraction (iOS 27.1 foldables), if the system has one.
    hinge: ?objc.Object = null,
    /// UIKit moves the fold's reserved regions a little after the hinge
    /// reports, with no event of its own: frames read them until then.
    fold_until: f64 = 0,

    /// The surface of `obj`, for one event: pair with `leave`. After a
    /// frame, a handler checks `dead` before touching it again.
    pub fn enter(obj: objc.Object) ?*Surface {
        const s = objc.getZig(Surface, obj) orelse return null;
        s.depth += 1;
        return s;
    }

    pub fn leave(s: *Surface) void {
        s.depth -= 1;
        if (s.depth == 0 and s.dead) s.free();
    }

    pub fn create(window: *Window, view: ui.View, theme_override: ?Theme, full_bleed: bool) !*Surface {
        const gpa = window.app.gpa;
        const self = try gpa.create(Surface);
        errdefer gpa.destroy(self);
        var renderer = try metal.Renderer.init();
        errdefer renderer.deinit();

        const view_class = objc.defineClass(.{
            .name = "NanoUIView",
            .superclass = "UIView",
            .methods = &(view_methods ++ touch.methods ++ keys.view_methods),
        });
        const uiview = objc.msg(objc.Object, objc.msg(objc.Object, view_class, "alloc", .{}), "initWithFrame:", .{objc.CGRect{}});
        self.* = .{
            .gpa = gpa,
            .window = window,
            .uiview = uiview,
            .renderer = renderer,
            .text = .init(gpa, renderer.device),
            .ctx = undefined,
            .view = view,
            .theme_override = theme_override,
            .full_bleed = full_bleed,
            .start_time = cf.CACurrentMediaTime(),
            .keys = .init(gpa),
        };
        self.ctx = .init(gpa, &self.text);
        objc.setZig(uiview, self);
        objc.msg(void, uiview, "setMultipleTouchEnabled:", .{objc.YES});
        const layer = objc.msg(objc.Object, uiview, "layer", .{});
        objc.msg(void, layer, "addSublayer:", .{renderer.layer});
        keys.attach(self);
        self.hinge = fold.attach(self);

        const link = objc.retain(objc.msg(objc.Object, objc.class("CADisplayLink"), "displayLinkWithTarget:selector:", .{ uiview, objc.sel("displayLinkFired:") }));
        objc.msg(void, link, "setPaused:", .{objc.YES});
        const loop = objc.msg(objc.Object, objc.class("NSRunLoop"), "mainRunLoop", .{});
        objc.msg(void, link, "addToRunLoop:forMode:", .{ loop, NSRunLoopCommonModes });
        self.display_link = link;
        // Pictures go straight to the GPU: no copy of their atlas in memory.
        self.text.images.sink = .{ .ctx = &self.renderer, .upload = metal.Renderer.uploadImage };
        return self;
    }

    /// Cuts the surface off from UIKit at once; frees it when no handler
    /// is running (a tap that closes its window is still in its frame).
    pub fn destroy(self: *Surface) void {
        objc.setZig(self.uiview, null);
        keys.detach(self);
        if (self.hinge) |h| fold.detach(self, h);
        self.hinge = null;
        if (self.display_link) |link| {
            // The link retains its target, the view: break the cycle.
            objc.msg(void, link, "invalidate", .{});
            objc.release(link);
            self.display_link = null;
        }
        if (self.depth > 0 or self.in_frame) {
            self.dead = true;
            return;
        }
        self.free();
    }

    fn free(self: *Surface) void {
        objc.msg(void, self.renderer.layer, "removeFromSuperlayer", .{});
        objc.release(self.uiview);
        self.instances.deinit(self.gpa);
        self.keys.deinit(self.gpa);
        self.ctx.deinit();
        self.text.deinit();
        self.renderer.deinit();
        self.gpa.destroy(self);
    }

    fn updateGeometry(self: *Surface) void {
        // In a frame (a dialog's run loop inside it): its sizes stay until
        // it ends, and the next frame takes the new ones.
        if (self.in_frame) {
            self.stale_geometry = true;
            self.pending = true;
            return;
        }
        self.stale_geometry = false;
        const b = objc.msg(objc.CGRect, self.uiview, "bounds", .{});
        self.size = .{ .w = @floatCast(b.size.width), .h = @floatCast(b.size.height) };
        const traits = objc.msg(objc.Object, self.uiview, "traitCollection", .{});
        const scale = objc.msg(f64, traits, "displayScale", .{});
        self.scale = if (scale > 0) @floatCast(scale) else 2;
        const i = objc.msg(Insets, self.uiview, "safeAreaInsets", .{});
        self.insets = .{ .top = @floatCast(i.top), .left = @floatCast(i.left), .bottom = @floatCast(i.bottom), .right = @floatCast(i.right) };
        // The layer follows the view at once, not in an implicit animation.
        const tx = objc.class("CATransaction");
        objc.msg(void, tx, "begin", .{});
        objc.msg(void, tx, "setDisableActions:", .{objc.YES});
        objc.msg(void, self.renderer.layer, "setFrame:", .{b});
        objc.msg(void, tx, "commit", .{});
        self.text.setScale(self.scale);
        self.renderer.resize(self.size, self.scale);
        fold.read(self);
    }

    /// The screen changed (a fold, a tilt): reads it again and draws.
    pub fn geometryChanged(self: *Surface) void {
        self.updateGeometry();
        self.requestFrame();
    }

    /// The hinge moved: reads the screen now, and again each frame for a
    /// moment, as UIKit moves the fold's regions after it.
    pub fn hingeMoved(self: *Surface) void {
        self.fold_until = cf.CACurrentMediaTime() + 0.75;
        self.geometryChanged();
    }

    fn foldSettling(self: *Surface) bool {
        return self.fold_until > 0 and cf.CACurrentMediaTime() < self.fold_until;
    }

    /// What the system covers: the safe area, and the keyboard over it.
    pub fn safeArea(self: *Surface) types.Edges {
        var e = self.insets;
        e.bottom = @max(e.bottom, self.keyboard);
        return e;
    }

    fn theme(self: *Surface) Theme {
        if (self.theme_override) |t| return t;
        const traits = objc.msg(objc.Object, self.uiview, "traitCollection", .{});
        // UIUserInterfaceStyleDark
        return if (objc.msg(objc.NSInteger, traits, "userInterfaceStyle", .{}) == 2) Theme.dark_theme else Theme.light;
    }

    fn canDraw(self: *Surface) bool {
        if (!self.window.app.active or self.size.w <= 0 or self.size.h <= 0) return false;
        return objc.msg(?objc.Object, self.uiview, "window", .{}) != null;
    }

    /// Builds, lays out, paints and draws one frame.
    pub fn frame(self: *Surface) void {
        if (self.dead) return;
        if (self.stale_geometry) self.updateGeometry() else if (self.foldSettling()) fold.read(self);
        if (self.in_frame or !self.canDraw()) {
            // Waits: the frame running (a dialog's run loop is inside it)
            // restarts the display link for it as it ends, the return to
            // the foreground draws it.
            self.pending = true;
            self.setPaced(false);
            return;
        }
        self.pending = false;
        self.in_frame = true;
        const pool = objc.Pool.push();
        const c = &self.ctx;
        const now = cf.CACurrentMediaTime();
        const dt: f32 = if (self.last_frame_time > 0) @floatCast(@min(now - self.last_frame_time, 0.1)) else 1.0 / 60.0;
        self.last_frame_time = now;
        c.reduced_motion = UIAccessibilityIsReduceMotionEnabled();
        c.safe_area = self.safeArea();
        const root: ui.View = if (self.full_bleed) self.view else .init(self, insideSafeArea);
        const r = frame_mod.run(c, root, &self.text, &self.instances, self.size, self.scale, self.theme(), dt, now - self.start_time);
        @import("../play.zig").paint(self.gpa, &self.instances);
        c.device.rotated = false;
        c.device.posture_changed = false;
        if (self.dead) {
            // The view closed its window: nothing left to draw into.
            pool.pop();
            self.in_frame = false;
            if (self.depth == 0) self.free();
            return;
        }
        self.renderer.syncImages(&self.text.images);
        self.renderer.textures = c.textures.items;
        // The renderer draws into the drawable it is given (on the Mac, the
        // CAMetalDisplayLink's): here, the layer's next one.
        self.renderer.given_drawable = objc.msg(?objc.Object, self.renderer.layer, "nextDrawable", .{});
        self.renderer.draw(self.instances.items, self.text.texture(), self.size, c.theme.background);
        pool.pop();
        self.in_frame = false;
        // No hover on a touch screen: what changed under a finger already drew.
        const more = c.animating or r.hot_changed or self.touch.flinging() or self.foldSettling();
        self.setRate(if (more or self.pending) null else c.frame_in);
        self.setPaced(more or c.frame_in != null or self.pending);
        if (!c.animating) self.last_frame_time = 0;
        // After the pace: the keyboard coming or going asks for a frame.
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

    /// Draws a frame at the display's next refresh: for changes from
    /// outside the view (a process's output, a network reply).
    pub fn requestFrame(self: *Surface) void {
        if (self.dead) return;
        self.setRate(null);
        self.setPaced(true);
    }

    /// The display link's pace: the display's (null), or one frame every
    /// `seconds`.
    fn setRate(self: *Surface, seconds: ?f32) void {
        const link = self.display_link orelse return;
        const fps: f32 = if (seconds) |s| std.math.clamp(1 / @max(s, 0.001), 1, 60) else 0;
        if (fps == self.link_fps) return;
        self.link_fps = fps;
        const Range = extern struct { minimum: f32, maximum: f32, preferred: f32 };
        const range: Range = if (fps == 0) .{ .minimum = 0, .maximum = 0, .preferred = 0 } else .{ .minimum = fps, .maximum = fps, .preferred = fps };
        objc.msg(void, link, "setPreferredFrameRateRange:", .{range});
    }

    fn setPaced(self: *Surface, on: bool) void {
        if (self.display_link) |link| objc.msg(void, link, "setPaused:", .{!on});
    }

    /// The app came to the foreground or left it.
    pub fn activeChanged(self: *Surface, on: bool) void {
        if (!on) {
            self.touch.stop();
            // What moved goes on moving when the app comes back.
            self.pending = true;
            return self.setPaced(false);
        }
        self.depth += 1;
        defer self.leave();
        if (self.pending) self.frame();
    }
};

const view_methods = [_]objc.Method{
    .{ .name = "layoutSubviews", .imp = &layoutSubviews, .types = "v@:" },
    .{ .name = "safeAreaInsetsDidChange", .imp = &safeAreaChanged, .types = "v@:" },
    .{ .name = "traitCollectionDidChange:", .imp = &traitsChanged, .types = "v@:@" },
    .{ .name = "didMoveToWindow", .imp = &didMoveToWindow, .types = "v@:" },
    .{ .name = "displayLinkFired:", .imp = &displayLinkFired, .types = "v@:@" },
};

fn layoutSubviews(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    objc.msgSuper(void, obj, objc.class("UIView"), "layoutSubviews", .{});
    const s = Surface.enter(obj) orelse return;
    defer s.leave();
    s.updateGeometry();
    s.frame();
}

fn safeAreaChanged(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    objc.msgSuper(void, obj, objc.class("UIView"), "safeAreaInsetsDidChange", .{});
    const s = Surface.enter(obj) orelse return;
    defer s.leave();
    s.updateGeometry();
    s.requestFrame();
}

fn traitsChanged(obj: objc.Object, _: objc.SEL, previous: ?objc.Object) callconv(.c) void {
    objc.msgSuper(void, obj, objc.class("UIView"), "traitCollectionDidChange:", .{previous});
    const s = Surface.enter(obj) orelse return;
    defer s.leave();
    // Dark mode, or the screen's scale (another display).
    s.updateGeometry();
    s.requestFrame();
}

fn didMoveToWindow(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    objc.msgSuper(void, obj, objc.class("UIView"), "didMoveToWindow", .{});
    const s = Surface.enter(obj) orelse return;
    defer s.leave();
    if (objc.msg(?objc.Object, obj, "window", .{}) == null) return;
    // Keys from a hardware keyboard come to the first responder.
    keys.takeKeys(s);
    s.updateGeometry();
    s.frame();
}

fn displayLinkFired(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const s = Surface.enter(obj) orelse return;
    defer s.leave();
    touch.fling(s);
    if (!s.dead) s.frame();
}
