//! The connection between a window and its native UI: an NSView hosting
//! the Metal layer, drawing frames on demand (its events: surface_events.zig).
//! Nothing polls: a frame runs on input, on resize, or while an animation
//! moves, at most every display refresh.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const types = @import("types.zig");
const metal = @import("metal.zig");
const text = @import("text.zig");
const frame_mod = @import("frame.zig");
const textinput = @import("textinput.zig");
const Theme = @import("theme.zig").Theme;
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const ui = @import("ui.zig");
const Window = @import("../window.zig").Window;
const a11y = @import("a11y.zig");
const events = @import("surface_events.zig");
const frame_log_mod = @import("frame_log.zig");
pub const FrameLog = frame_log_mod.FrameLog;
pub const KeysReleased = struct { ctx: ?*anyopaque, func: *const fn (ctx: ?*anyopaque, s: *Surface) void };
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
pub const Surface = struct {
    gpa: std.mem.Allocator,
    window: *Window,
    nsview: objc.Object,
    tracking: ?objc.Object = null,
    renderer: metal.Renderer,
    text: text.TextSystem,
    /// Built with `-Dportable=true`: the atlas nanoui rasterized, uploaded.
    atlas_texture: ?objc.Object = null,
    atlas_generation: u64 = std.math.maxInt(u64),
    ctx: Context,
    view: ui.View,
    instances: std.ArrayList(metal.Instance) = .empty,
    pasted: std.ArrayList(u8) = .empty,
    text_queue: textinput.Queue,
    size: types.Size = .{},
    scale: f32 = 2,
    last_frame_time: f64 = 0,
    start_time: f64 = 0,
    tick_scheduled: bool = false,
    /// Paces animation frames at the display's refresh (CADisplayLink).
    display_link: ?objc.Object = null,
    /// The pace asked of the link: 0 is the display's, -1 unset.
    link_fps: f32 = -1,
    max_fps: f32 = 60,
    link_duration: f64 = 0,
    last_present_target: f64 = 0,
    paced: bool = false,
    in_frame: bool = false,
    full_pending: bool = false,
    retained_ready: bool = false,
    frame_in_due: f64 = 0,
    pending_sync: bool = false,
    /// A frame was wanted while the window was hidden: run it once visible.
    pending: bool = false,
    dead: bool = false,
    torn_down: bool = false,
    /// The window is being resized: only its size changes draw (each when
    /// the layer is displayed); the link waits, and what else asks for a
    /// frame (output, an animation) gets the resize's next one.
    resizing: bool = false,
    cursor: ctx_mod.Cursor = .arrow,
    cursor_dirty: bool = false,
    theme_override: ?Theme = null,
    cached_theme: Theme = Theme.light,
    reduce_motion: bool = false,
    is_visible: bool = false,
    released: bool = false,
    in_live_resize: bool = false,
    geometry_changed: bool = false,
    transparent: bool = false,
    after_frame_ctx: ?*anyopaque = null,
    after_frame: ?*const fn (ctx: ?*anyopaque, s: *Surface) bool = null,
    keys_released: ?KeysReleased = null,
    a11y_cache: std.AutoHashMapUnmanaged(u64, objc.Object) = .empty,
    /// Behind a stage (`attachBackdrop`): presents in a transaction when
    /// native views or geometry move.
    hosted: bool = false,
    /// The focused box after the last frame, and the tooltip shown.
    last_focus: u64 = 0,
    tip: ?[]const u8 = null,
    frame_log: ?FrameLog = null,
    frame_kind: frame_log_mod.Kind = .input,

    pub fn create(window: *Window, view: ui.View, theme_override: ?Theme) !*Surface {
        const gpa = window.app.gpa;
        const self = try gpa.create(Surface);
        errdefer gpa.destroy(self);
        var renderer = try metal.Renderer.init();
        errdefer renderer.deinit();

        const view_class = objc.defineClass(.{
            .name = "NanoUIView",
            .superclass = "NSView",
            .protocols = &.{"NSTextInputClient"},
            .methods = &events.methods,
        });
        const content = objc.msg(objc.Object, window.nswindow, "contentView", .{});
        const bounds = objc.msg(objc.CGRect, content, "bounds", .{});
        const nsview = objc.msg(objc.Object, objc.msg(objc.Object, view_class, "alloc", .{}), "initWithFrame:", .{bounds});

        self.* = .{
            .gpa = gpa,
            .window = window,
            .nsview = nsview,
            .renderer = renderer,
            .text = if (text.portable) .init(gpa) else .init(gpa, renderer.device),
            .ctx = undefined,
            .view = view,
            .text_queue = .init(gpa),
            .theme_override = theme_override,
            // Before anything can run a frame: setContentView: resizes the view.
            .start_time = cf.CACurrentMediaTime(),
        };
        self.ctx = .init(gpa, &self.text);
        // Pictures go straight to the GPU before any view callback can run a frame.
        self.text.images.sink = .{ .ctx = &self.renderer, .upload = @import("metal.zig").Renderer.uploadImage };
        self.refreshAppearance();
        if (getenv("NANOUI_FRAMES")) |raw| {
            const p = std.mem.span(raw);
            if (p.len > 0) self.frame_log = FrameLog.init(gpa, p) catch null;
        }
        objc.setZig(nsview, self);
        // A layer-hosting view: the Metal layer is ours.
        objc.msg(void, nsview, "setLayer:", .{renderer.layer});
        objc.msg(void, nsview, "setWantsLayer:", .{objc.YES});
        objc.msg(void, renderer.layer, "setAutoresizingMask:", .{@as(c_uint, 2 | 16)}); // width, height sizable
        objc.msg(void, window.nswindow, "setContentView:", .{nsview});
        objc.msg(void, window.nswindow, "setAcceptsMouseMovedEvents:", .{objc.YES});
        _ = objc.msg(objc.BOOL, window.nswindow, "makeFirstResponder:", .{nsview});
        {
            const pool = objc.Pool.push();
            defer pool.pop();
            const arr = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
            for (events.drag_types) |t| objc.msg(void, arr, "addObject:", .{objc.nsString(t)});
            objc.msg(void, nsview, "registerForDraggedTypes:", .{arr});
        }
        {
            const link = objc.msg(objc.Object, objc.alloc("CAMetalDisplayLink"), "initWithMetalLayer:", .{self.renderer.layer});
            objc.msg(void, link, "setDelegate:", .{nsview});
            objc.msg(void, link, "setPaused:", .{objc.YES});
            const loop = objc.msg(objc.Object, objc.class("NSRunLoop"), "mainRunLoop", .{});
            objc.msg(void, link, "addToRunLoop:forMode:", .{ loop, NSRunLoopCommonModes });
            self.display_link = link;
        }
        {
            const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
            self.reduce_motion = objc.msg(objc.BOOL, ws, "accessibilityDisplayShouldReduceMotion", .{});
            const center = objc.msg(objc.Object, ws, "notificationCenter", .{});
            objc.msg(void, center, "addObserver:selector:name:object:", .{
                nsview, objc.sel("accessibilityChanged:"), objc.nsString("NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification"), @as(?objc.Object, null),
            });
        }
        self.refreshAppearance();
        self.is_visible = objc.msg(objc.BOOL, window.nswindow, "isVisible", .{}) and (objc.msg(objc.NSUInteger, window.nswindow, "occlusionState", .{}) & 2 != 0);
        self.updateGeometry();
        self.frame();
        return self;
    }

    pub fn destroy(self: *Surface) void {
        self.dead = true;
        if (!self.in_frame) self.finishDestroy();
    }

    fn finishDestroy(self: *Surface) void {
        if (!self.torn_down) {
            self.torn_down = true;
            objc.setZig(self.nsview, null);
            const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
            objc.msg(void, objc.msg(objc.Object, ws, "notificationCenter", .{}), "removeObserver:", .{self.nsview});
            if (self.display_link) |link| {
                if (objc.msg(objc.BOOL, link, "respondsToSelector:", .{objc.sel("setDelegate:")}))
                    objc.msg(void, link, "setDelegate:", .{@as(?objc.Object, null)});
                objc.msg(void, link, "invalidate", .{});
                objc.release(link);
            }
            if (self.tracking) |t| objc.release(t);
            a11y.clearCache(self);
            objc.release(self.nsview);
            self.instances.deinit(self.gpa);
            self.pasted.deinit(self.gpa);
            if (self.tip) |t| self.gpa.free(t);
            self.text_queue.deinit(self.gpa);
            self.ctx.deinit();
            self.text.deinit();
            if (self.atlas_texture) |t| objc.release(t);
            self.renderer.deinit();
            if (self.frame_log) |*fl| fl.deinit();
        }
        if (!self.tick_scheduled) self.gpa.destroy(self);
    }

    fn finishFrame(self: *Surface) void {
        self.in_frame = false;
        if (self.dead) self.finishDestroy();
    }

    pub fn recordFrames(self: *Surface, gpa: std.mem.Allocator) !*FrameLog {
        if (self.frame_log == null) self.frame_log = try FrameLog.init(gpa, null);
        return &self.frame_log.?;
    }

    pub fn updateGeometry(self: *Surface) void {
        const b = objc.msg(objc.CGRect, self.nsview, "bounds", .{});
        self.size = .{ .w = @floatCast(b.size.width), .h = @floatCast(b.size.height) };
        self.scale = @floatCast(objc.msg(f64, self.window.nswindow, "backingScaleFactor", .{}));
        self.text.setScale(self.scale);
        self.renderer.resize(self.size, self.scale);
        self.geometry_changed = true;
        self.updateMaxFps();
    }

    pub fn screenChanged(self: *Surface) void {
        self.updateMaxFps();
    }

    fn updateMaxFps(self: *Surface) void {
        const screen = objc.msg(?objc.Object, self.window.nswindow, "screen", .{});
        const fps: f32 = if (screen) |sc| @floatFromInt(@max(60, objc.msg(objc.NSInteger, sc, "maximumFramesPerSecond", .{}))) else 60;
        if (fps != self.max_fps) {
            self.max_fps = fps;
            const cur = self.link_fps;
            self.link_fps = -1;
            if (cur >= 0) self.setRate(if (cur == 0) null else 1 / cur);
        }
    }

    pub fn refreshAppearance(self: *Surface) void {
        const appearance = objc.msg(objc.Object, self.nsview, "effectiveAppearance", .{});
        const name = objc.fromNSString(objc.msg(?objc.Object, appearance, "name", .{}));
        self.cached_theme = if (std.mem.indexOf(u8, name, "Dark") != null) Theme.dark_theme else Theme.light;
    }

    fn theme(self: *Surface) Theme {
        return self.theme_override orelse self.cached_theme;
    }

    /// The atlas texture the renderer samples: CoreText's, or the one
    /// nanoui's own text rasterized into memory, uploaded when it changed.
    fn atlasTexture(self: *Surface) objc.Object {
        if (!text.portable) return self.text.texture();
        const a = &self.text.atlas;
        const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
        const side: usize = a.size;
        if (self.atlas_texture) |t| if (objc.msg(objc.NSUInteger, t, "width", .{}) != side) {
            objc.release(t);
            self.atlas_texture = null;
        };
        if (self.atlas_texture == null) {
            const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
                @as(objc.NSUInteger, 10), side, side, objc.NO, // R8Unorm
            });
            self.atlas_texture = objc.msg(objc.Object, self.renderer.device, "newTextureWithDescriptor:", .{desc});
            self.atlas_generation = std.math.maxInt(u64);
        }
        const t = self.atlas_texture.?;
        if (self.atlas_generation != a.generation) {
            if (self.atlas_generation != std.math.maxInt(u64)) self.renderer.waitIdle();
            objc.msg(void, t, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
                Region{ .x = 0, .y = 0, .z = 0, .w = side, .h = side, .d = 1 }, @as(objc.NSUInteger, 0), @as(*const anyopaque, a.pixels.ptr), side,
            });
            self.atlas_generation = a.generation;
        }
        return t;
    }

    pub fn frame(self: *Surface) void {
        if (self.in_frame or self.dead) return;
        self.renderer.given_drawable = null;
        self.full_pending = true;
        const now = @max(cf.CACurrentMediaTime(), self.last_frame_time);
        const fallback_dur = 1.0 / @as(f64, @max(60.0, self.max_fps));
        self.frameAt(.input, now, if (self.link_duration > 0) self.link_duration else fallback_dur);
    }

    pub fn frameAt(self: *Surface, kind: frame_log_mod.Kind, target_in: f64, duration_in: f64) void {
        if (self.in_frame or self.dead) return;
        const vis = self.visible();
        self.pending = !vis;
        self.in_frame = true;
        defer self.finishFrame();
        self.full_pending = false;
        self.retained_ready = false;
        const pool = objc.Pool.push();
        defer pool.pop();
        const c = &self.ctx;
        const fallback_dur = 1.0 / @as(f64, @max(60.0, self.max_fps));
        const dur: f64 = if (duration_in > 0) duration_in else fallback_dur;
        if (duration_in > 0) self.link_duration = duration_in;
        const now = if (target_in > 0) @max(target_in, self.last_frame_time) else @max(cf.CACurrentMediaTime(), self.last_frame_time);
        const dt: f32 = if (self.last_frame_time > 0) @floatCast(std.math.clamp(now - self.last_frame_time, 0, 0.5)) else @floatCast(dur);
        self.last_frame_time = now;
        self.frame_kind = kind;
        self.ctx.transparent_root = self.transparent;
        c.reduce_motion = self.reduce_motion;
        c.reduced_motion = self.reduce_motion;
        c.window_focused = if (vis) self.window.isFocused() else true;
        const r = frame_mod.run(c, self.view, &self.text, &self.instances, self.size, self.scale, self.theme(), dt, now - self.start_time);
        if (self.dead) return;
        @import("../play.zig").paint(self.gpa, &self.instances);
        self.frame_in_due = if (c.frame_in) |fi| now + @as(f64, fi) else 0;
        const t_af0 = if (self.frame_log != null) cf.CACurrentMediaTime() else 0;
        const native_changed = if (self.after_frame) |af| af(self.after_frame_ctx, self) else false;
        if (self.dead) return;
        const after_frame_ms = if (self.frame_log != null) (cf.CACurrentMediaTime() - t_af0) * 1000 else 0;
        const sync = native_changed or self.in_live_resize or self.geometry_changed or self.pending_sync;
        self.geometry_changed = false;
        self.pending_sync = false;
        self.afterFocus();
        if (!vis or self.renderer.given_drawable == null) {
            self.retained_ready = vis and !c.animating and !c.changed and !r.hot_changed;
            self.pending_sync = sync;
            self.updateCursor();
            if (vis) {
                if (self.retained_ready) {
                    if (self.display_link != null) {
                        self.setRate(null);
                        self.setPaced(true);
                    } else self.scheduleTick();
                } else self.requestFrame();
            } else self.setPaced(false);
            return;
        }
        const presented = self.presentFrame(now, target_in, dur, sync, .{
            .t = now,
            .kind = kind,
            .interval_ms = 0,
            .duration = dur,
            .dt = dt,
            .build_ms = c.stats.build_ms,
            .layout_ms = c.stats.layout_ms,
            .paint_ms = c.stats.paint_ms,
            .after_frame_ms = after_frame_ms,
            .drawable_wait_ms = 0,
            .encode_ms = 0,
            .sync = sync,
            .nodes = c.stats.nodes,
            .instances = c.stats.instances,
            .atlas_reset = false,
            .animating = c.animating,
        });
        self.updateCursor();
        if (!presented) return self.requestFrame();
        self.updatePacing(now, r.hot_changed);
    }

    pub fn updatePacing(self: *Surface, now: f64, hot_changed: bool) void {
        const c = &self.ctx;
        const elapsed = (now - self.start_time) - c.caret_moved_at;
        const recent_typing = c.focused_text != null and c.caret_moved_at > 0 and elapsed >= 0 and elapsed < 0.35;
        const more = c.animating or hot_changed or c.input.down or recent_typing;
        if (self.display_link != null) {
            if (more) {
                self.setRate(null);
                self.setPaced(true);
            } else if (c.frame_in) |fi| {
                self.setRate(fi);
                self.setPaced(true);
            } else if (c.time_driven != .none) {
                self.setRate(if (c.time_driven == .fast) null else 1.0 / 24.0);
                self.setPaced(true);
            } else self.setPaced(false);
        } else if (more or c.frame_in != null or c.time_driven != .none) self.scheduleTick();
        if (!c.animating) {
            self.last_frame_time = 0;
            if (self.frame_log) |*fl| fl.last_t = 0;
        }
    }

    pub fn redrawRetained(self: *Surface, target_in: f64, duration_in: f64) void {
        if (self.in_frame or self.dead) return;
        if (!self.visible() or self.renderer.given_drawable == null) {
            self.setPaced(false);
            return;
        }
        self.in_frame = true;
        defer self.finishFrame();
        const pool = objc.Pool.push();
        defer pool.pop();
        const c = &self.ctx;
        const fallback_dur = 1.0 / @as(f64, @max(60.0, self.max_fps));
        const dur: f64 = if (duration_in > 0) duration_in else fallback_dur;
        if (duration_in > 0) self.link_duration = duration_in;
        const now = if (target_in > 0) target_in else cf.CACurrentMediaTime();
        const sync = self.pending_sync;
        self.pending_sync = false;
        const presented = self.presentFrame(now, target_in, dur, sync, .{
            .t = now,
            .kind = .retained,
            .interval_ms = 0,
            .duration = dur,
            .dt = @floatCast(dur),
            .build_ms = 0,
            .layout_ms = 0,
            .paint_ms = 0,
            .after_frame_ms = 0,
            .drawable_wait_ms = 0,
            .encode_ms = 0,
            .sync = sync,
            .nodes = c.stats.nodes,
            .instances = self.instances.items.len,
            .atlas_reset = false,
            .animating = c.time_driven == .fast,
        });
        if (!presented) return self.requestFrame();
        if (self.retained_ready) {
            self.retained_ready = false;
            self.updatePacing(now, false);
        }
    }

    fn presentFrame(self: *Surface, now: f64, target_in: f64, dur: f64, sync: bool, mut_rec: frame_log_mod.Record) bool {
        const c = &self.ctx;
        const wall_now = cf.CACurrentMediaTime();
        self.renderer.setLiveResize(sync);
        const atlas_reset = self.text.atlas.reset_during_frame or self.text.images.reset_during_frame;
        if (atlas_reset) self.renderer.waitIdle();
        self.renderer.syncImages(&self.text.images);
        self.renderer.textures = c.textures.items;
        const clear = if (self.transparent) types.Color.transparent else c.theme.background;
        const present_at = if (target_in > 0) target_in else if (self.last_present_target > 0) @max(wall_now, self.last_present_target + dur) else wall_now;
        self.renderer.present_at = present_at;
        self.renderer.time = @floatCast(now - self.start_time);
        var presented = true;
        if (self.frame_log) |*fl| {
            var rec = mut_rec;
            rec.interval_ms = if (fl.last_t > 0) @max(0, (now - fl.last_t) * 1000) else 0;
            rec.sync = sync;
            rec.atlas_reset = atlas_reset;
            const idx = fl.append(rec);
            const ds = self.renderer.drawLogged(self.instances.items, self.atlasTexture(), self.size, clear, fl, idx);
            presented = ds.presented;
            if (presented) fl.setDraw(idx, ds.drawable_wait_ms, ds.encode_ms, ds.sync, ds.queued) else fl.dropLast();
        } else {
            presented = self.renderer.drawLogged(self.instances.items, self.atlasTexture(), self.size, clear, null, 0).presented;
        }
        if (presented) self.last_present_target = present_at;
        return presented;
    }

    pub fn setTransparent(self: *Surface, on: bool) void {
        self.transparent = on;
        self.ctx.transparent_root = on;
        self.renderer.setOpaque(!on);
    }

    /// Places `stage_view` behind `self.nsview` inside a flipped host contentView,
    /// enabling transparent viewport holes over live WKWebView panes.
    pub const attachBackdrop = events.attachBackdrop;

    /// Draws a frame at the display's next refresh: for changes from
    pub fn requestFrame(self: *Surface) void {
        self.full_pending = true;
        if (!self.paced and !self.in_frame and cf.CACurrentMediaTime() >= self.last_present_target) {
            self.frame();
            return;
        }
        if (self.display_link != null and self.visible()) {
            self.setRate(null);
            self.setPaced(true);
        } else self.scheduleTick();
    }

    /// The display link's pace: the display's (null), or one frame every
    /// `seconds`.
    fn setRate(self: *Surface, seconds: ?f32) void {
        const link = self.display_link orelse return;
        const fps: f32 = if (seconds) |s| (if (s < 0.009) 0 else std.math.clamp(1 / @max(s, 0.001), 1, 60)) else 0;
        if (fps == self.link_fps) return;
        const faster = (fps == 0 and self.link_fps > 0) or (fps > self.link_fps and self.link_fps > 0);
        if (fps == 0 and self.link_fps > 0) {
            if (self.frame_log) |*fl| fl.last_t = 0;
        }
        self.link_fps = fps;
        const s = self.max_fps;
        const Range = extern struct { minimum: f32, maximum: f32, preferred: f32 };
        const range: Range = if (fps == 0) .{ .minimum = s, .maximum = s, .preferred = s } else .{ .minimum = fps, .maximum = fps, .preferred = fps };
        if (self.paced and faster) objc.msg(void, link, "setPaused:", .{objc.YES});
        objc.msg(void, link, "setPreferredFrameRateRange:", .{range});
        if (self.paced and faster) objc.msg(void, link, "setPaused:", .{objc.NO});
    }

    pub fn visible(self: *Surface) bool {
        if (!self.is_visible) {
            self.is_visible = objc.msg(objc.BOOL, self.window.nswindow, "isVisible", .{}) and (objc.msg(objc.NSUInteger, self.window.nswindow, "occlusionState", .{}) & 2 != 0);
            if (self.is_visible and self.released) {
                self.released = false;
                self.renderer.resize(self.size, self.scale);
            }
        }
        return self.is_visible;
    }

    fn setPaced(self: *Surface, on: bool) void {
        if (self.paced == on) return;
        self.paced = on;
        if (!on) if (self.frame_log) |*fl| {
            fl.last_t = 0;
        };
        if (self.display_link) |link| objc.msg(void, link, "setPaused:", .{!on});
    }

    pub fn occlusionChanged(self: *Surface) void {
        const was = self.is_visible;
        self.is_visible = objc.msg(objc.BOOL, self.window.nswindow, "isVisible", .{}) and (objc.msg(objc.NSUInteger, self.window.nswindow, "occlusionState", .{}) & 2 != 0);
        if (was and !self.is_visible) {
            self.pending = true;
            self.released = true;
            self.renderer.resize(.{ .w = 1, .h = 1 }, self.scale);
            self.text.images.trimDecoded();
            _ = self.ctx.arena.reset(.{ .retain_with_limit = 64 * 1024 });
        } else if (!was and self.is_visible) {
            if (self.released) {
                self.released = false;
                self.renderer.resize(self.size, self.scale);
            }
            if (self.pending) self.frame();
        }
    }

    pub fn updateCursor(self: *Surface) void {
        if (self.transparent and self.ctx.inStageHoleAt(self.ctx.input.mouse)) {
            self.cursor_dirty = true;
            return;
        }
        const want: ctx_mod.Cursor = self.ctx.cursor orelse if (self.ctx.cursor_text) .text else if (self.ctx.cursor_hand) .hand else .arrow;
        if (want == self.cursor and !self.cursor_dirty) return;
        self.cursor = want;
        self.cursor_dirty = false;
        self.applyCursor();
    }

    pub fn applyCursor(self: *Surface) void {
        const name: [:0]const u8 = switch (self.cursor) {
            .arrow => "arrowCursor",
            .hand => "pointingHandCursor",
            .text => "IBeamCursor",
            .resize_left_right => "resizeLeftRightCursor",
            .resize_up_down => "resizeUpDownCursor",
            .open_hand => "openHandCursor",
            .closed_hand => "closedHandCursor",
            .not_allowed => "operationNotAllowedCursor",
            .crosshair => "crosshairCursor",
        };
        objc.msg(void, objc.msg(objc.Object, objc.class("NSCursor"), name, .{}), "set", .{});
    }

    /// After a frame: a box newly focused takes the keyboard for the view
    /// (`focusNext` while a page had it), and the hot box's help shows.
    fn afterFocus(self: *Surface) void {
        const c = &self.ctx;
        if (c.focus != 0) {
            const first = objc.msg(?objc.Object, self.window.nswindow, "firstResponder", .{});
            if (first == null or first.? != self.nsview) _ = objc.msg(objc.BOOL, self.window.nswindow, "makeFirstResponder:", .{self.nsview});
        } else if (self.last_focus != 0 and c.focus == 0) {
            const first = objc.msg(?objc.Object, self.window.nswindow, "firstResponder", .{});
            if (first != null and first.? == self.nsview and c.selection.hit == null and !c.selection.dragging and c.selection.text.items.len == 0) {
                if (self.keys_released) |kr| kr.func(kr.ctx, self);
            }
        }
        self.last_focus = c.focus;
        self.refreshTip();
    }

    /// Shows the help under the pointer: after a frame, and on a move
    /// within one box onto a marker with its own.
    pub fn refreshTip(self: *Surface) void {
        const tip = self.ctx.hotHelp();
        const same = if (tip) |t| (if (self.tip) |old| std.mem.eql(u8, t, old) else false) else self.tip == null;
        if (same) return;
        if (self.tip) |old| self.gpa.free(old);
        self.tip = if (tip) |t| self.gpa.dupe(u8, t) catch null else null;
        objc.msg(void, self.nsview, "setToolTip:", .{if (self.tip) |t| objc.nsString(t) else @as(?objc.Object, null)});
    }

    fn scheduleTick(self: *Surface) void {
        if (self.tick_scheduled) return;
        self.tick_scheduled = true;
        objc.dispatchAfter(std.time.ns_per_s / 120, self, tick);
    }
    fn tick(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(ptr));
        self.tick_scheduled = false;
        if (self.dead) return self.finishDestroy();
        self.frame();
    }
    pub fn toView(self: *Surface, p: objc.CGPoint) types.Point {
        const local = objc.msg(objc.CGPoint, self.nsview, "convertPoint:fromView:", .{ p, @as(?objc.Object, null) });
        return .{ .x = @floatCast(local.x), .y = @floatCast(local.y) };
    }
};
extern "c" const NSRunLoopCommonModes: objc.Object;
