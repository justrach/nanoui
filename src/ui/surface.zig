//! The connection between a window and its native UI: an NSView hosting
//! the Metal layer, turning AppKit events into input and drawing frames on
//! demand. Nothing polls: a frame runs on input, on resize, or while an
//! animation moves, at most every display refresh.
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
    /// Checks for a live snapshot's request (live_snapshot.zig).
    live_timer: ?objc.Object = null,
    /// The pace asked of the link: 0 is the display's.
    link_fps: f32 = 0,
    /// A frame was wanted while the window was hidden: run it once visible.
    pending: bool = false,
    dead: bool = false,
    /// The window is being resized: only its size changes draw (each when
    /// the layer is displayed); the link waits, and what else asks for a
    /// frame (output, an animation) gets the resize's next one.
    resizing: bool = false,
    cursor: ctx_mod.Cursor = .arrow,
    theme_override: ?Theme = null,

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
            .methods = &view_methods,
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
        objc.setZig(nsview, self);
        // A layer-hosting view: the Metal layer is ours.
        objc.msg(void, nsview, "setLayer:", .{renderer.layer});
        objc.msg(void, nsview, "setWantsLayer:", .{objc.YES});
        // As GPUI's: a layer whose bounds change asks the view to display it
        // (`displayLayer:`), in the transaction that changes the window's
        // frame, whatever changed it: a drag, a zoom, tiling, full screen.
        objc.msg(void, renderer.layer, "setDelegate:", .{nsview});
        objc.msg(void, renderer.layer, "setNeedsDisplayOnBoundsChange:", .{objc.YES});
        objc.msg(void, renderer.layer, "setAutoresizingMask:", .{@as(c_uint, 2 | 16)}); // width, height sizable
        objc.msg(void, window.nswindow, "setContentView:", .{nsview});
        objc.msg(void, window.nswindow, "setAcceptsMouseMovedEvents:", .{objc.YES});
        _ = objc.msg(objc.BOOL, window.nswindow, "makeFirstResponder:", .{nsview});
        if (objc.msg(objc.BOOL, nsview, "respondsToSelector:", .{objc.sel("displayLinkWithTarget:selector:")})) {
            const link = objc.retain(objc.msg(objc.Object, nsview, "displayLinkWithTarget:selector:", .{ nsview, objc.sel("displayLinkFired:") }));
            objc.msg(void, link, "setPaused:", .{objc.YES});
            const loop = objc.msg(objc.Object, objc.class("NSRunLoop"), "mainRunLoop", .{});
            objc.msg(void, link, "addToRunLoop:forMode:", .{ loop, NSRunLoopCommonModes });
            self.display_link = link;
        }
        self.live_timer = @import("live_snapshot.zig").start(nsview);
        // Pictures go straight to the GPU: no copy of their atlas in memory.
        self.text.images.sink = .{ .ctx = &self.renderer, .upload = @import("metal.zig").Renderer.uploadImage };
        self.updateGeometry();
        self.frame();
        return self;
    }

    pub fn destroy(self: *Surface) void {
        objc.setZig(self.nsview, null);
        if (self.live_timer) |t| {
            objc.msg(void, t, "invalidate", .{});
            objc.release(t);
        }
        if (self.display_link) |link| {
            // The link retains its target, the view: break the cycle.
            objc.msg(void, link, "invalidate", .{});
            objc.release(link);
        }
        if (self.tracking) |t| objc.release(t);
        objc.release(self.nsview);
        self.instances.deinit(self.gpa);
        self.pasted.deinit(self.gpa);
        self.text_queue.deinit(self.gpa);
        self.ctx.deinit();
        self.text.deinit();
        if (self.atlas_texture) |t| objc.release(t);
        self.renderer.deinit();
        if (self.tick_scheduled) self.dead = true else self.gpa.destroy(self);
    }

    fn updateGeometry(self: *Surface) void {
        const b = objc.msg(objc.CGRect, self.nsview, "bounds", .{});
        self.size = .{ .w = @floatCast(b.size.width), .h = @floatCast(b.size.height) };
        self.scale = @floatCast(objc.msg(f64, self.window.nswindow, "backingScaleFactor", .{}));
        self.text.setScale(self.scale);
        self.renderer.resize(self.size, self.scale);
    }

    fn theme(self: *Surface) Theme {
        if (self.theme_override) |t| return t;
        const appearance = objc.msg(objc.Object, self.nsview, "effectiveAppearance", .{});
        const name = objc.fromNSString(objc.msg(?objc.Object, appearance, "name", .{}));
        return if (std.mem.indexOf(u8, name, "Dark") != null) Theme.dark_theme else Theme.light;
    }

    /// Builds, lays out, paints and draws one frame.
    /// The atlas texture the renderer samples: CoreText's, or the one
    /// nanoui's own text rasterized into memory, uploaded when it changed.
    pub fn atlasTexture(self: *Surface) objc.Object {
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
            objc.msg(void, t, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
                Region{ .x = 0, .y = 0, .z = 0, .w = side, .h = side, .d = 1 }, @as(objc.NSUInteger, 0), @as(*const anyopaque, a.pixels.ptr), side,
            });
            self.atlas_generation = a.generation;
        }
        return t;
    }

    pub fn frame(self: *Surface) void {
        // Nothing to show while hidden (another Space, covered, minimized):
        // the frame runs once the window is visible again. The first frame
        // runs at once, so the window opens with its content drawn.
        if (self.ctx.frame > 0 and !self.visible()) {
            self.pending = true;
            self.setPaced(false);
            return;
        }
        self.pending = false;
        const pool = objc.Pool.push();
        defer pool.pop();
        const c = &self.ctx;
        const now = cf.CACurrentMediaTime();
        const dt: f32 = if (self.last_frame_time > 0) @floatCast(@min(now - self.last_frame_time, 0.1)) else 1.0 / 60.0;
        self.last_frame_time = now;
        c.reduced_motion = reduceMotion();
        const r = frame_mod.run(c, self.view, &self.text, &self.instances, self.size, self.scale, self.theme(), dt, now - self.start_time);
        @import("../play.zig").paint(self.gpa, &self.instances);
        self.renderer.syncImages(&self.text.images);
        self.renderer.textures = c.textures.items;
        self.renderer.draw(self.instances.items, self.atlasTexture(), self.size, c.theme.background);
        self.updateCursor();
        // Something moved under a still pointer, or a value is animating.
        const more = c.animating or r.hot_changed;
        if (self.resizing) {
            // The resize's next step draws again; its end catches up.
            self.setPaced(false);
        } else if (self.display_link != null) {
            // Something changes now and then: the link, at that pace.
            self.setRate(if (more) null else c.frame_in);
            self.setPaced(more or c.frame_in != null);
        } else if (more or c.frame_in != null) self.scheduleTick();
        if (!c.animating) self.last_frame_time = 0;
    }

    /// Draws a frame at the display's next refresh: for changes from
    /// outside the view (a process's output, a network reply).
    pub fn requestFrame(self: *Surface) void {
        if (self.resizing) return;
        if (self.display_link != null) {
            self.setRate(null);
            self.setPaced(true);
        } else self.scheduleTick();
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

    fn visible(self: *Surface) bool {
        return objc.msg(objc.NSUInteger, self.window.nswindow, "occlusionState", .{}) & 2 != 0;
    }

    fn setPaced(self: *Surface, on: bool) void {
        if (self.display_link) |link| objc.msg(void, link, "setPaused:", .{!on});
    }

    /// The window was shown, uncovered or covered.
    pub fn occlusionChanged(self: *Surface) void {
        if (self.visible() and self.pending) self.frame();
    }

    fn updateCursor(self: *Surface) void {
        const want: ctx_mod.Cursor = self.ctx.cursor orelse if (self.ctx.cursor_text) .text else if (self.ctx.cursor_hand) .hand else .arrow;
        if (want == self.cursor) return;
        self.cursor = want;
        const name: [:0]const u8 = switch (want) {
            .arrow => "arrowCursor",
            .hand => "pointingHandCursor",
            .text => "IBeamCursor",
            .resize_left_right => "resizeLeftRightCursor",
            .resize_up_down => "resizeUpDownCursor",
        };
        objc.msg(void, objc.msg(objc.Object, objc.class("NSCursor"), name, .{}), "set", .{});
    }

    fn scheduleTick(self: *Surface) void {
        if (self.tick_scheduled) return;
        self.tick_scheduled = true;
        objc.dispatchAfter(std.time.ns_per_s / 120, self, tick);
    }

    fn tick(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(ptr));
        self.tick_scheduled = false;
        if (self.dead) return self.gpa.destroy(self);
        self.frame();
    }

    fn setMouse(self: *Surface, event: objc.Object) void {
        const p = objc.msg(objc.CGPoint, event, "locationInWindow", .{});
        const local = objc.msg(objc.CGPoint, self.nsview, "convertPoint:fromView:", .{ p, @as(?objc.Object, null) });
        self.ctx.input.mouse = .{ .x = @floatCast(local.x), .y = @floatCast(local.y) };
        const flags = objc.msg(objc.NSUInteger, event, "modifierFlags", .{});
        self.ctx.input.shift = flags & (1 << 17) != 0;
        self.ctx.input.cmd = flags & (1 << 20) != 0;
        self.ctx.input.ctrl = flags & (1 << 18) != 0;
        self.ctx.input.alt = flags & (1 << 19) != 0;
    }
};

// The run loop knows its common modes by this object, not by its name.
extern "c" const NSRunLoopCommonModes: objc.Object;

const view_methods = [_]objc.Method{
                .{ .name = "isFlipped", .imp = &yes, .types = "c@:" },
                .{ .name = "acceptsFirstResponder", .imp = &yes, .types = "c@:" },
                .{ .name = "acceptsFirstMouse:", .imp = &yes1, .types = "c@:@" },
                .{ .name = "mouseDown:", .imp = &mouseDown, .types = "v@:@" },
                .{ .name = "mouseUp:", .imp = &mouseUp, .types = "v@:@" },
                .{ .name = "rightMouseDown:", .imp = &rightMouseDown, .types = "v@:@" },
                .{ .name = "mouseDragged:", .imp = &mouseDragged, .types = "v@:@" },
                .{ .name = "mouseMoved:", .imp = &mouseMoved, .types = "v@:@" },
                .{ .name = "mouseExited:", .imp = &mouseExited, .types = "v@:@" },
                .{ .name = "scrollWheel:", .imp = &scrollWheel, .types = "v@:@" },
                .{ .name = "magnifyWithEvent:", .imp = &magnify, .types = "v@:@" },
                .{ .name = "keyDown:", .imp = &keyDown, .types = "v@:@" },
                .{ .name = "paste:", .imp = &paste, .types = "v@:@" },
                .{ .name = "setFrameSize:", .imp = &setFrameSize, .types = "v@:{CGSize=dd}" },
                .{ .name = "displayLayer:", .imp = &displayLayer, .types = "v@:@" },
                .{ .name = "viewDidChangeBackingProperties", .imp = &backingChanged, .types = "v@:" },
                .{ .name = "viewDidChangeEffectiveAppearance", .imp = &backingChanged, .types = "v@:" },
                .{ .name = "updateTrackingAreas", .imp = &updateTrackingAreas, .types = "v@:" },
                .{ .name = "displayLinkFired:", .imp = &displayLinkFired, .types = "v@:@" },
                .{ .name = "liveSnapshotTick:", .imp = &liveSnapshotTick, .types = "v@:@" },
                .{ .name = "viewWillStartLiveResize", .imp = &liveResizeStart, .types = "v@:" },
                .{ .name = "viewDidEndLiveResize", .imp = &liveResizeEnd, .types = "v@:" },
} ++ textinput.methods;

fn surfaceOf(obj: objc.Object) ?*Surface {
    return objc.getZig(Surface, obj);
}

fn yes(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn yes1(_: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn mouseDown(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    _ = objc.msg(objc.BOOL, s.window.nswindow, "makeFirstResponder:", .{obj});
    s.setMouse(event);
    s.ctx.updateHot();
    // A Control-click is the Mac's secondary click.
    if (s.ctx.input.ctrl) {
        s.ctx.secondaryDown();
        return s.frame();
    }
    s.ctx.input.click_count = @intCast(objc.msg(objc.NSInteger, event, "clickCount", .{}));
    // Under a hidden title bar, the top strip moves the window as a title bar would.
    if (s.window.title_bar == .hidden and s.ctx.input.mouse.y < s.ctx.title_bar_height and s.ctx.hot == 0) {
        if (s.ctx.input.click_count == 2) s.window.zoom() else objc.msg(void, s.window.nswindow, "performWindowDragWithEvent:", .{event});
        return;
    }
    s.ctx.pointerDown();
    s.frame();
}

fn rightMouseDown(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.setMouse(event);
    s.ctx.updateHot();
    s.ctx.secondaryDown();
    s.frame();
}

fn mouseUp(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.setMouse(event);
    s.ctx.updateHot();
    s.ctx.pointerUp();
    s.frame();
}

fn mouseDragged(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.setMouse(event);
    s.ctx.updateHot();
    s.frame();
}

fn mouseMoved(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.setMouse(event);
    const before = s.ctx.hot;
    s.ctx.updateHot();
    if (s.ctx.hot != before or s.ctx.wants_moves) return s.frame();
    // Onto or off text that selects, inside the same box: the cursor only.
    const over = s.ctx.pointerOverText();
    if (over != s.ctx.cursor_text) {
        s.ctx.cursor_text = over;
        s.updateCursor();
    }
}

fn mouseExited(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.ctx.input.mouse = .{ .x = -1e6, .y = -1e6 };
    if (s.ctx.hot != 0) {
        s.ctx.updateHot();
        s.frame();
    }
}

fn scrollWheel(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.setMouse(event);
    var dy: f32 = @floatCast(objc.msg(f64, event, "scrollingDeltaY", .{}));
    if (!objc.msg(objc.BOOL, event, "hasPreciseScrollingDeltas", .{})) dy *= 12;
    if (s.ctx.applyScroll(dy)) {
        s.frame();
        s.ctx.updateHot();
    } else if (s.ctx.wants_wheel) {
        s.ctx.input.scroll = .{ .y = dy };
        s.frame();
    }
}

/// A trackpad's pinch: `input.zoom`, about the pointer.
fn magnify(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.setMouse(event);
    s.ctx.input.zoom = @floatCast(@max(0.1, 1 + objc.msg(f64, event, "magnification", .{})));
    s.frame();
}

fn keyDown(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    const code = objc.msg(u16, event, "keyCode", .{});
    const flags = objc.msg(objc.NSUInteger, event, "modifierFlags", .{});
    const in = &s.ctx.input;
    in.cmd = flags & (1 << 20) != 0;
    in.shift = flags & (1 << 17) != 0;
    in.ctrl = flags & (1 << 18) != 0;
    in.alt = flags & (1 << 19) != 0;
    // Key combinations go to the view first, which may take them.
    const ign = objc.fromNSString(objc.msg(?objc.Object, event, "charactersIgnoringModifiers", .{}));
    if (ign.len > 0) {
        const cp = std.unicode.utf8Decode(ign[0..cf.seqLen(ign[0])]) catch 0;
        const key: u21 = if (cp < 128) std.ascii.toLower(@intCast(cp)) else cp;
        const ctrl = flags & (1 << 18) != 0;
        const alt = flags & (1 << 19) != 0;
        const special = key == 0xF700 or key == 0xF701 or key == '\t' or key == 0x1b;
        // Option too: a text field with Emacs's keys takes ⌥B, ⌥F, ⌥D.
        if (in.cmd or ctrl or alt or special) {
            s.ctx.shortcut_taken = false;
            in.shortcut = .{ .key = key, .cmd = in.cmd, .ctrl = ctrl, .alt = alt, .shift = in.shift };
            s.frame();
            in.shortcut = null;
            if (s.ctx.shortcut_taken) return;
        }
    }
    // A focused text field gets the event through the input system:
    // accents, input methods, the system's key bindings.
    if (textinput.interpret(s, event)) return;
    in.key = switch (code) {
        51 => .backspace,
        117 => .delete,
        123 => .left,
        124 => .right,
        125 => .down,
        126 => .up,
        115 => .home,
        119 => .end,
        36, 76 => .enter,
        48 => .tab,
        53 => .escape,
        116 => .page_up,
        121 => .page_down,
        122 => .f1,
        120 => .f2,
        99 => .f3,
        118 => .f4,
        96 => .f5,
        97 => .f6,
        98 => .f7,
        100 => .f8,
        101 => .f9,
        109 => .f10,
        103 => .f11,
        111 => .f12,
        else => null,
    };
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    if (in.key == null and !in.cmd and flags & (1 << 18) == 0) {
        const chars = objc.fromNSString(objc.msg(?objc.Object, event, "characters", .{}));
        // Printable text only: no controls, no function keys (U+F700…).
        var i: usize = 0;
        while (i < chars.len) {
            const len = cf.seqLen(chars[i]);
            const seq = chars[i..@min(chars.len, i + len)];
            const printable = seq[0] >= 0x20 and seq[0] != 0x7f and !(seq.len == 3 and seq[0] == 0xef and seq[1] >= 0x9c and seq[1] <= 0x9f);
            if (printable and n + seq.len <= buf.len) {
                @memcpy(buf[n .. n + seq.len], seq);
                n += seq.len;
            }
            i += len;
        }
    }
    in.chars = buf[0..n];
    if (in.key == null and n == 0) return;
    s.frame();
}

fn paste(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    // ⌘V goes to the view first, as other shortcuts do: it may paste what
    // is not text (an image).
    s.ctx.shortcut_taken = false;
    s.ctx.input.shortcut = .{ .key = 'v', .cmd = true };
    s.frame();
    s.ctx.input.shortcut = null;
    if (s.ctx.shortcut_taken) return;
    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
    const str = objc.msg(?objc.Object, pb, "stringForType:", .{objc.nsString("public.utf8-plain-text")});
    const bytes = objc.fromNSString(str);
    // One line: newlines become spaces.
    s.pasted.clearRetainingCapacity();
    s.pasted.appendSlice(s.gpa, bytes) catch return;
    for (s.pasted.items) |*ch| if (ch.* == '\n' or ch.* == '\r') {
        ch.* = ' ';
    };
    textinput.paste(s, s.pasted.items);
}

fn liveSnapshotTick(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    @import("live_snapshot.zig").tick(surfaceOf(obj) orelse return);
}

fn displayLinkFired(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    // While resizing, the resize draws: a frame of the link's would take
    // a drawable its next step waits for.
    if (s.resizing) return s.setPaced(false);
    s.frame();
}

fn liveResizeStart(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    objc.msgSuper(void, obj, objc.class("NSView"), "viewWillStartLiveResize", .{});
    const s = surfaceOf(obj) orelse return;
    s.resizing = true;
    s.setPaced(false);
    s.renderer.setLiveResize(true);
}

fn liveResizeEnd(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    objc.msgSuper(void, obj, objc.class("NSView"), "viewDidEndLiveResize", .{});
    const s = surfaceOf(obj) orelse return;
    s.resizing = false;
    s.renderer.setLiveResize(false);
    // What changed meanwhile, and the link's pace again.
    s.frame();
}

fn setFrameSize(obj: objc.Object, _: objc.SEL, size: objc.CGSize) callconv(.c) void {
    const old = objc.msg(objc.CGRect, obj, "frame", .{}).size;
    if (old.width == size.width and old.height == size.height) return;
    objc.msgSuper(void, obj, objc.class("NSView"), "setFrameSize:", .{size});
    const s = surfaceOf(obj) orelse return;
    s.updateGeometry();
    // The frame is drawn when the layer is displayed (`displayLayer:`), in
    // this resize's transaction; a hidden window's waits until it shows.
    if (s.visible()) objc.msg(void, s.renderer.layer, "setNeedsDisplay", .{}) else s.frame();
}

/// Core Animation displays the layer (its bounds changed): a frame now,
/// presented in the same transaction, as GPUI's `display_layer`.
fn displayLayer(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.renderer.setInTransaction(true);
    s.setPaced(false);
    s.frame();
    s.renderer.setInTransaction(false);
}

fn backingChanged(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.updateGeometry();
    s.frame();
}

fn updateTrackingAreas(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    objc.msgSuper(void, obj, objc.class("NSView"), "updateTrackingAreas", .{});
    const s = surfaceOf(obj) orelse return;
    if (s.tracking) |t| {
        objc.msg(void, obj, "removeTrackingArea:", .{t});
        objc.release(t);
    }
    // Entered and exited, moved, always active, in the visible rect.
    const opts: objc.NSUInteger = 0x01 | 0x02 | 0x80 | 0x200;
    const area = objc.msg(objc.Object, objc.alloc("NSTrackingArea"), "initWithRect:options:owner:userInfo:", .{
        objc.CGRect{}, opts, obj, @as(?objc.Object, null),
    });
    objc.msg(void, obj, "addTrackingArea:", .{area});
    s.tracking = area;
}

/// System Settings, Accessibility, Display, Reduce motion.
fn reduceMotion() bool {
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    return objc.msg(objc.BOOL, ws, "accessibilityDisplayShouldReduceMotion", .{});
}
