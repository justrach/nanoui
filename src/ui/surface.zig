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
const wake = @import("surface_wake.zig");
const thread_wake = @import("surface_thread_wake.zig");
const pointer = @import("surface_pointer.zig");
const frame_log_mod = @import("frame_log.zig");
pub const FrameLog = frame_log_mod.FrameLog;
pub const KeysReleased = struct { ctx: ?*anyopaque, func: *const fn (ctx: ?*anyopaque, s: *Surface) void };
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
const pacing = @import("pacing.zig");
const link_pace = @import("surface_pacing.zig");
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
    /// Another thread asked for a frame and the main queue hasn't run it.
    wake_pending: std.atomic.Value(bool) = .init(false),
    /// Paces animation frames at the display's refresh (CADisplayLink).
    display_link: ?objc.Object = null,
    /// The pace asked of the link: 0 is the display's, -1 unset.
    link_fps: f32 = -1,
    max_fps: f32 = 60,
    /// The most frames a second the app wants (0: the screen's maximum):
    /// a 120 Hz budget on a 240 Hz screen, or a battery saver.
    fps_cap: f32 = 0,
    link_duration: f64 = 0,
    last_present_target: f64 = 0,
    paced: bool = false,
    in_frame: bool = false,
    full_pending: bool = false,
    retained_ready: bool = false,
    frame_in_due: f64 = 0,
    wake: wake.Wake = .{},
    pending_sync: bool = false,
    /// A frame was wanted while the window was hidden: run it once visible.
    pending: bool = false,
    dead: bool = false,
    /// `destroy` ran after the app's run loop stopped: queued ticks and
    /// wakes will never fire, so the surface must not wait for them.
    force_destroy: bool = false,
    torn_down: bool = false,
    /// The window is being resized: only its size changes draw (each when
    /// the layer is displayed); the link waits, and what else asks for a
    /// frame (output, an animation) gets the resize's next one.
    resizing: bool = false,
    cursor: ctx_mod.Cursor = .arrow,
    custom_cursor: ?*anyopaque = null,
    /// The app's GPU passes before each frame's (`gpu.BeforeEncode`).
    before_encode: ?@import("gpu.zig").BeforeEncode = null,
    cursor_dirty: bool = false,
    theme_override: ?Theme = null,
    cached_theme: Theme = Theme.light,
    reduce_motion: bool = false,
    is_visible: bool = false,
    released: bool = false,
    /// When the live resize last changed the size: the link stays awake a
    /// little after it (`resizeStepping`), not for the whole drag.
    resize_step_at: f64 = 0,
    geometry_changed: bool = false,
    transparent: bool = false,
    after_frame_ctx: ?*anyopaque = null,
    after_frame: ?*const fn (ctx: ?*anyopaque, s: *Surface) bool = null,
    keys_released: ?KeysReleased = null,
    a11y_cache: a11y.State = .{},
    /// Behind a stage (`attachBackdrop`): presents in a transaction when
    /// native views or geometry move.
    hosted: bool = false,
    /// The focused box after the last frame, and the tooltip shown.
    last_focus: u64 = 0,
    tip: ?[]const u8 = null,
    frame_log: ?FrameLog = null,
    frame_kind: frame_log_mod.Kind = .input,
    /// Scrolling gathered for the link's next frame, and main's frame log.
    scroll: pacing.Scroll = .{},
    pacing_log: pacing.FrameLog = .{},
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
        // Before anything can queue a tick or a wake, which find it by id.
        wake.register(self);
        errdefer wake.unregister(self);
        if (text.portable and !window.app.flags.hidden) self.text.enablePersistence(window.app.options.name);
        self.ctx = .init(gpa, &self.text);
        self.ctx.waker = .{ .ctx = self, .wake = thread_wake.fromContext };
        // Pictures go straight to the GPU before any view callback can run a frame.
        self.text.images.sink = .{ .ctx = &self.renderer, .upload = @import("metal.zig").Renderer.uploadImage };
        self.refreshAppearance();
        if (getenv("NANOUI_FRAMES")) |raw| {
            const p = std.mem.span(raw);
            if (p.len > 0) self.frame_log = FrameLog.init(gpa, p) catch null;
        }
        self.pacing_log = .open();
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
        self.startLink();
        {
            const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
            self.reduce_motion = objc.msg(objc.BOOL, ws, "accessibilityDisplayShouldReduceMotion", .{});
            const center = objc.msg(objc.Object, ws, "notificationCenter", .{});
            objc.msg(void, center, "addObserver:selector:name:object:", .{ nsview, objc.sel("accessibilityChanged:"), objc.nsString("NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification"), @as(?objc.Object, null) });
        }
        self.refreshAppearance();
        self.is_visible = objc.msg(objc.BOOL, window.nswindow, "isVisible", .{}) and (objc.msg(objc.NSUInteger, window.nswindow, "occlusionState", .{}) & 2 != 0);
        self.updateGeometry();
        self.frame();
        return self;
    }
    pub const startLink = link_pace.startLink;
    pub const stopLink = link_pace.stopLink;

    pub fn destroy(self: *Surface) void {
        self.dead = true;
        self.ctx.changed = false;
        self.force_destroy = !self.window.app.running;
        if (!self.in_frame) self.finishDestroy();
    }
    pub fn token(self: *const Surface) ?*anyopaque {
        return wake.token(self);
    }
    pub fn alive(tok: ?*anyopaque) bool {
        const s = wake.find(tok) orelse return false;
        return !s.dead;
    }
    pub fn finishDestroy(self: *Surface) void {
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
            objc.autorelease(self.nsview);
            self.instances.deinit(self.gpa);
            self.pasted.deinit(self.gpa);
            if (self.tip) |t| self.gpa.free(t);
            self.text_queue.deinit(self.gpa);
            self.ctx.deinit();
            self.text.deinit();
            if (self.atlas_texture) |t| objc.release(t);
            self.renderer.deinit();
            self.pacing_log.close();
            if (self.frame_log) |*fl| fl.deinit();
        }
        // Else the last tick or wake to run frees it. Closed while the app
        // ran, it may stop before they do: `App.destroy` frees it then
        // (`wake.sweep`).
        if (self.force_destroy or (!self.tick_scheduled and !self.wake_pending.load(.acquire) and self.wake.pending == 0)) wake.free(self);
    }

    /// From any thread: a frame at the display's next refresh (`surface_thread_wake.zig`).
    pub const requestFrameFromAnyThread = thread_wake.request;

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

    const updateMaxFps = link_pace.updateMaxFps;
    /// Caps the display link's pace at `fps` (0 lifts the cap).
    pub const setFpsCap = link_pace.setFpsCap;

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
        a11y.beforeFrame(self);
        c.input.window_active = self.window.isFocused();
        c.window_focused = c.input.window_active;
        self.pacing_log.note(now);
        // What scrolling gathered since the last frame, applied at once.
        const dy = self.scroll.take();
        if (dy != 0 and !c.applyScroll(dy) and (c.wants_wheel or c.wheelAt())) c.input.scroll.y += dy;
        const r = frame_mod.run(c, self.view, &self.text, &self.instances, self.size, self.scale, a11y.themed(self, self.theme()), dt, now - self.start_time);
        if (self.dead) return;
        a11y.afterFrame(self);
        @import("../play.zig").paint(self.gpa, &self.instances);
        self.frame_in_due = if (c.frame_in) |fi| now + @as(f64, fi) else 0;
        if (c.frame_in == null) self.wake.due = 0;
        const t_af0 = if (self.frame_log != null) cf.CACurrentMediaTime() else 0;
        const native_changed = if (self.after_frame) |af| af(self.after_frame_ctx, self) else false;
        if (self.dead) return;
        const after_frame_ms = if (self.frame_log != null) (cf.CACurrentMediaTime() - t_af0) * 1000 else 0;
        // In the window's transaction only when native views moved with
        // the frame: a resize alone presents on the link's schedule.
        const sync = native_changed or self.pending_sync;
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
        if (dy != 0) c.updateHot();
        self.updatePacing(now, r.hot_changed);
    }

    pub fn updatePacing(self: *Surface, now: f64, hot_changed: bool) void {
        const c = &self.ctx;
        const more = self.resizeStepping() or c.animating or hot_changed or c.input.down or self.scroll.active(now);
        if (self.display_link != null) {
            if (more) {
                self.setRate(null);
                self.setPaced(true);
            } else if (c.frame_in != null) {
                wake.at(self, self.frame_in_due); // not a slowed link: see there
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

    pub const resizeStepping = link_pace.resizeStepping;
    pub const resizeSyncEnabled = link_pace.resizeSyncEnabled;
    pub const resizeInTransaction = link_pace.resizeInTransaction;

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
        self.renderer.gradients = c.gradients.items;
        self.renderer.before_encode = self.before_encode;
        const clear = if (self.transparent) types.Color.transparent else c.theme.background;
        self.renderer.setBackdrop(clear);
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
        if (presented) wake.presented(self);
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
            self.ctx.frame_in = null;
            self.setRate(null);
            self.setPaced(true);
        } else self.scheduleTick();
    }

    /// The display link's pace: the display's (null), or one frame every
    /// `seconds`.
    pub fn setRate(self: *Surface, seconds: ?f32) void {
        const link = self.display_link orelse return;
        const fps: f32 = if (seconds) |s| (if (s < 0.009) 0 else std.math.clamp(1 / @max(s, 0.001), 1, 60)) else 0;
        if (fps == self.link_fps) return;
        const faster = (fps == 0 and self.link_fps > 0) or (fps > self.link_fps and self.link_fps > 0);
        if (fps == 0 and self.link_fps > 0) {
            if (self.frame_log) |*fl| fl.last_t = 0;
        }
        self.link_fps = fps;
        if (self.paced and faster) objc.msg(void, link, "setPaused:", .{objc.YES});
        objc.msg(void, link, "setPreferredFrameRateRange:", .{pacing.range(fps, self.max_fps)});
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

    pub fn setPaced(self: *Surface, on: bool) void {
        if (on) wake.watch(self);
        if (self.paced == on) return;
        self.paced = on;
        if (!on and self.frame_log != null) self.frame_log.?.last_t = 0;
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

    pub const updateCursor = pointer.updateCursor;
    pub const applyCursor = pointer.applyCursor;
    const afterFocus = pointer.afterFocus;
    pub const refreshTip = pointer.refreshTip;

    /// The native view the surface draws into (`nsview`): the parent a
    /// docked page goes in, as Windows' surface names its HWND.
    pub fn nativeHandle(self: *Surface) ?*anyopaque {
        return @ptrCast(self.nsview);
    }

    const scheduleTick = thread_wake.scheduleTick;
    pub fn toView(self: *Surface, p: objc.CGPoint) types.Point {
        const local = objc.msg(objc.CGPoint, self.nsview, "convertPoint:fromView:", .{ p, @as(?objc.Object, null) });
        return .{ .x = @floatCast(local.x), .y = @floatCast(local.y) };
    }
};
