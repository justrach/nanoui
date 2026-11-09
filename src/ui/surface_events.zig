//! NanoUIView's methods: AppKit's events become the context's input, each
//! running a frame. The pointer's buttons, the wheel, keys and modifiers,
//! the first responder, drags from other apps, and the view's geometry.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const types = @import("types.zig");
const textinput = @import("textinput.zig");
const a11y = @import("a11y.zig");
const input = @import("input.zig");
const Surface = @import("surface.zig").Surface;
const drop = @import("surface_drop.zig");
const link_pace = @import("surface_pacing.zig");
const keys = @import("surface_keys.zig");

pub const methods = [_]objc.Method{
    .{ .name = "isFlipped", .imp = &yes, .types = "c@:" },
    .{ .name = "acceptsFirstResponder", .imp = &yes, .types = "c@:" },
    .{ .name = "resignFirstResponder", .imp = &resignFirstResponder, .types = "c@:" },
    .{ .name = "acceptsFirstMouse:", .imp = &yes1, .types = "c@:@" },
    .{ .name = "hitTest:", .imp = &hitTest, .types = "@@:{CGPoint=dd}" },
    .{ .name = "mouseDown:", .imp = &mouseDown, .types = "v@:@" },
    .{ .name = "mouseUp:", .imp = &mouseUp, .types = "v@:@" },
    .{ .name = "mouseDragged:", .imp = &mouseDragged, .types = "v@:@" },
    .{ .name = "rightMouseDown:", .imp = &rightMouseDown, .types = "v@:@" },
    .{ .name = "rightMouseUp:", .imp = &rightMouseUp, .types = "v@:@" },
    .{ .name = "rightMouseDragged:", .imp = &mouseDragged, .types = "v@:@" },
    .{ .name = "otherMouseDown:", .imp = &otherMouseDown, .types = "v@:@" },
    .{ .name = "otherMouseUp:", .imp = &otherMouseUp, .types = "v@:@" },
    .{ .name = "otherMouseDragged:", .imp = &mouseDragged, .types = "v@:@" },
    .{ .name = "mouseMoved:", .imp = &mouseMoved, .types = "v@:@" },
    .{ .name = "mouseExited:", .imp = &mouseExited, .types = "v@:@" },
    .{ .name = "scrollWheel:", .imp = &scrollWheel, .types = "v@:@" },
    .{ .name = "magnifyWithEvent:", .imp = &magnify, .types = "v@:@" },
    .{ .name = "draggingEntered:", .imp = &drop.draggingUpdated, .types = "Q@:@" },
    .{ .name = "draggingUpdated:", .imp = &drop.draggingUpdated, .types = "Q@:@" },
    .{ .name = "draggingExited:", .imp = &drop.draggingExited, .types = "v@:@" },
    .{ .name = "performDragOperation:", .imp = &drop.performDragOperation, .types = "c@:@" },
    // Updates on movement only: nothing polls.
    .{ .name = "wantsPeriodicDraggingUpdates", .imp = &no, .types = "c@:" },
    .{ .name = "setFrameSize:", .imp = &link_pace.setFrameSize, .types = "v@:{CGSize=dd}" },
    .{ .name = "viewDidChangeBackingProperties", .imp = &backingChanged, .types = "v@:" },
    .{ .name = "viewDidChangeEffectiveAppearance", .imp = &appearanceChanged, .types = "v@:" },
    .{ .name = "accessibilityChanged:", .imp = &accessibilityChanged, .types = "v@:@" },
    .{ .name = "updateTrackingAreas", .imp = &updateTrackingAreas, .types = "v@:" },
    .{ .name = "cursorUpdate:", .imp = &cursorUpdate, .types = "v@:@" },
    .{ .name = "resetCursorRects", .imp = &resetCursorRects, .types = "v@:" },
    .{ .name = "draggingSession:sourceOperationMaskForDraggingContext:", .imp = &draggingSourceMask, .types = "Q@:@q" },
    .{ .name = "metalDisplayLink:needsUpdate:", .imp = &link_pace.metalDisplayLinkNeedsUpdate, .types = "v@:@@" },
    .{ .name = "viewWillStartLiveResize", .imp = &link_pace.liveResizeStart, .types = "v@:" },
    .{ .name = "viewDidEndLiveResize", .imp = &link_pace.liveResizeEnd, .types = "v@:" },
} ++ keys.methods ++ textinput.methods ++ a11y.methods;

/// What drags from other apps may bring.
pub const drag_types = [_][]const u8{ "public.url", "public.file-url", "public.utf8-plain-text" };

fn surfaceOf(obj: objc.Object) ?*Surface {
    return objc.getZig(Surface, obj);
}

pub fn yes(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn no(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.NO;
}

fn yes1(_: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) objc.BOOL {
    return objc.YES;
}

pub fn setMods(in: *input.Input, flags: objc.NSUInteger) void {
    in.shift = flags & (1 << 17) != 0;
    in.ctrl = flags & (1 << 18) != 0;
    in.alt = flags & (1 << 19) != 0;
    in.cmd = flags & (1 << 20) != 0;
}

fn setMouse(s: *Surface, event: objc.Object) void {
    const p = objc.msg(objc.CGPoint, event, "locationInWindow", .{});
    s.ctx.input.mouse = s.toView(p);
    setMods(&s.ctx.input, objc.msg(objc.NSUInteger, event, "modifierFlags", .{}));
}

fn hitTest(obj: objc.Object, _: objc.SEL, point: objc.CGPoint) callconv(.c) ?objc.Object {
    const s = surfaceOf(obj) orelse return null;
    const super = objc.msg(?objc.Object, obj, "superview", .{});
    const local = objc.msg(objc.CGPoint, obj, "convertPoint:fromView:", .{ point, super });
    const p: types.Point = .{ .x = @floatCast(local.x), .y = @floatCast(local.y) };
    if (p.x < 0 or p.y < 0 or p.x >= s.size.w or p.y >= s.size.h) return null;
    if (s.transparent and s.ctx.inStageHoleAt(p)) {
        s.cursor_dirty = true;
        return null;
    }
    return obj;
}

/// The view gives up the keyboard (a page took it): no box has the focus.
fn resignFirstResponder(obj: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    const s = surfaceOf(obj) orelse return objc.YES;
    s.last_focus = 0;
    if (s.ctx.focus != 0) {
        s.ctx.focus = 0;
        s.requestFrame();
    }
    return objc.YES;
}

/// A press of `button`: the view takes the keyboard, the box under the
/// pointer the press.
fn press(obj: objc.Object, event: objc.Object, button: input.Button) void {
    const s = surfaceOf(obj) orelse return;
    _ = objc.msg(objc.BOOL, s.window.nswindow, "makeFirstResponder:", .{obj});
    setMouse(s, event);
    s.ctx.updateHot();
    s.ctx.input.click_count = @intCast(std.math.clamp(objc.msg(objc.NSInteger, event, "clickCount", .{}), 0, 255));
    const eff_button: input.Button = if (button == .left and s.ctx.input.ctrl) .right else button;
    s.ctx.input.button = eff_button;
    if (eff_button == .left) {
        // Under a hidden title bar, the top strip moves the window as a title bar would.
        if (s.window.title_bar == .hidden and s.ctx.input.mouse.y < s.ctx.title_bar_height and s.ctx.hot == 0) {
            if (s.ctx.input.click_count == 2) s.window.zoom() else objc.msg(void, s.window.nswindow, "performWindowDragWithEvent:", .{event});
            return;
        }
        if (s.ctx.startsWindowDrag()) return objc.msg(void, s.window.nswindow, "performWindowDragWithEvent:", .{event});
    }
    s.ctx.text_menu = false;
    if (eff_button == .right) s.ctx.secondaryDown();
    s.ctx.pointerDown();
    const tok = s.token();
    s.frame();
    if (!Surface.alive(tok)) return;
    if (eff_button == .right and s.ctx.selection.text.items.len > 0) s.ctx.text_menu = true;
    if (s.ctx.focus == 0) {
        if (s.ctx.selection.hit != null or s.ctx.selection.dragging or s.ctx.selection.text.items.len > 0) {
            _ = objc.msg(objc.BOOL, s.window.nswindow, "makeFirstResponder:", .{obj});
        } else if (s.keys_released) |kr| kr.func(kr.ctx, s);
    }
    if (s.ctx.text_menu) {
        s.ctx.text_menu = false;
        textinput.popMenu(s);
    }
}

fn release(obj: objc.Object, event: objc.Object, button: input.Button) void {
    const s = surfaceOf(obj) orelse return;
    // Another button's release, or one whose press went elsewhere.
    if (s.ctx.input.button != button or !s.ctx.input.down) return;
    setMouse(s, event);
    s.ctx.updateHot();
    s.ctx.pointerUp();
    s.frame();
}

fn mouseDown(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    press(obj, event, .left);
}

fn mouseUp(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    release(obj, event, .left);
}

fn rightMouseDown(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    press(obj, event, .right);
}

fn rightMouseUp(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    release(obj, event, .right);
}

/// The middle button is the third (number 2); others are not taken.
fn otherMouseDown(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    if (objc.msg(objc.NSInteger, event, "buttonNumber", .{}) == 2) press(obj, event, .middle);
}

fn otherMouseUp(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    if (objc.msg(objc.NSInteger, event, "buttonNumber", .{}) == 2) release(obj, event, .middle);
}

fn mouseDragged(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    setMouse(s, event);
    s.ctx.updateHot();
    const tok = s.token();
    if (s.visible()) s.requestFrame() else s.frame();
    if (!Surface.alive(tok)) return;
    if (s.ctx.drag_request) |req| {
        s.ctx.drag_request = null;
        beginDragSession(s, req, event);
    }
}

fn mouseMoved(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    setMouse(s, event);
    if (s.transparent and s.ctx.inStageHoleAt(s.ctx.input.mouse) and s.ctx.hot == 0) return;
    const before = s.ctx.hot;
    s.ctx.updateHot();
    if (s.ctx.hot != before or s.ctx.wants_moves) {
        if (s.visible()) s.requestFrame() else s.frame();
        return;
    }
    // Onto or off text that selects, inside the same box: the cursor only.
    const over = s.ctx.pointerOverText();
    if (over != s.ctx.cursor_text) {
        s.ctx.cursor_text = over;
        s.updateCursor();
    }
    // Onto or off a marker with its own tooltip, inside the same box.
    s.refreshTip();
}

fn mouseExited(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.ctx.input.mouse = .{ .x = -1e6, .y = -1e6 };
    if (s.ctx.hot != 0) {
        s.ctx.updateHot();
        s.frame();
    }
}

/// A trackpad's pinch: `input.zoom`, about the pointer.
fn magnify(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    setMouse(s, event);
    const step: f32 = @floatCast(@max(0.1, 1 + objc.msg(f64, event, "magnification", .{})));
    // A trackpad sends magnify events faster than the display refreshes:
    // they compound into the next frame, drawn at the display link's pace,
    // as scrolling is, instead of a frame drawn for each.
    if (s.visible()) {
        s.ctx.input.zoom *= step;
        s.requestFrame();
    } else {
        s.ctx.input.zoom = step;
        s.frame();
    }
}

fn scrollPhase(event: objc.Object) input.ScrollPhase {
    if (objc.msg(objc.NSUInteger, event, "momentumPhase", .{}) != 0) return .momentum;
    const p = objc.msg(objc.NSUInteger, event, "phase", .{});
    // NSEventPhase: began 1, stationary 2, changed 4, ended 8, cancelled 16, may begin 32.
    return if (p & (1 | 32) != 0) .began else if (p & (2 | 4) != 0) .changed else if (p & (8 | 16) != 0) .ended else .none;
}

fn scrollWheel(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    setMouse(s, event);
    const in = &s.ctx.input;
    in.precise = objc.msg(objc.BOOL, event, "hasPreciseScrollingDeltas", .{});
    const phase = scrollPhase(event);
    if (!s.visible() or in.scroll_phase == .none or in.scroll_phase == .changed or phase == .began or phase == .ended) in.scroll_phase = phase;
    s.ctx.scroll_holding = in.precise and (phase == .began or phase == .changed);
    var dx: f32 = @floatCast(objc.msg(f64, event, "scrollingDeltaX", .{}));
    var dy: f32 = @floatCast(objc.msg(f64, event, "scrollingDeltaY", .{}));
    if (!in.precise) {
        dx *= 12;
        dy *= 12;
    }
    // Sideways always reaches the view (rows that scroll sideways); down
    // and up the scrolling box under the pointer, else a view that takes it.
    const took = dy != 0 and s.ctx.applyScroll(0);
    const wheel = (s.ctx.wants_wheel or s.ctx.wheelAt()) and !took;
    // A view taking the wheel keeps the same beat as a scrolling box: events come
    // unevenly, and a display link stopping between them misses frames.
    if (took or (wheel and s.visible())) s.scroll.add(dy, cf.CACurrentMediaTime());
    const release_over = !s.ctx.scroll_holding and s.ctx.hasOverscroll();
    if (!took and dx == 0 and !wheel and !release_over) return;
    if (s.visible()) {
        in.scroll.x += dx;
        s.requestFrame();
    } else {
        in.scroll = .{ .x = dx, .y = if (wheel) dy else 0 };
        const tok = s.token();
        s.frame();
        if (!Surface.alive(tok)) return;
        if (took) s.ctx.updateHot();
    }
}




fn backingChanged(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.updateGeometry();
    s.frame();
}

fn appearanceChanged(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.refreshAppearance();
    if (s.visible()) s.requestFrame() else s.frame();
}

fn accessibilityChanged(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    s.reduce_motion = objc.msg(objc.BOOL, ws, "accessibilityDisplayShouldReduceMotion", .{});
    if (s.visible()) s.requestFrame() else s.frame();
}

fn updateTrackingAreas(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    objc.msgSuper(void, obj, objc.class("NSView"), "updateTrackingAreas", .{});
    const s = surfaceOf(obj) orelse return;
    if (s.tracking) |t| {
        objc.msg(void, obj, "removeTrackingArea:", .{t});
        objc.release(t);
    }
    // Entered and exited, moved, cursorUpdate, always active, in the visible rect.
    const opts: objc.NSUInteger = 0x01 | 0x02 | 0x04 | 0x80 | 0x200;
    const area = objc.msg(objc.Object, objc.alloc("NSTrackingArea"), "initWithRect:options:owner:userInfo:", .{
        objc.CGRect{}, opts, obj, @as(?objc.Object, null),
    });
    objc.msg(void, obj, "addTrackingArea:", .{area});
    s.tracking = area;
}

fn cursorUpdate(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.applyCursor();
}

fn resetCursorRects(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.applyCursor();
}

fn draggingSourceMask(_: objc.Object, _: objc.SEL, _: objc.Object, _: objc.NSInteger) callconv(.c) objc.NSUInteger {
    return 1; // NSDragOperationCopy
}

fn beginDragSession(s: *Surface, req: @import("context_hooks.zig").DragRequest, event: objc.Object) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const w: f64 = if (req.rect.w > 0) @min(240, @max(80, req.rect.w)) else 160;
    const h: f64 = if (req.rect.h > 0) @min(48, @max(24, req.rect.h)) else 28;
    const img = objc.msg(objc.Object, objc.alloc("NSImage"), "initWithSize:", .{objc.CGSize{ .width = w, .height = h }});
    defer objc.release(img);
    objc.msg(void, img, "lockFocus", .{});
    const bg = s.ctx.theme.surface;
    const fill = objc.msg(objc.Object, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{ @as(f64, bg.r), @as(f64, bg.g), @as(f64, bg.b), @as(f64, 0.85) });
    objc.msg(void, fill, "setFill", .{});
    const path = objc.msg(objc.Object, objc.class("NSBezierPath"), "bezierPathWithRoundedRect:xRadius:yRadius:", .{
        objc.CGRect{ .size = .{ .width = w, .height = h } }, @as(f64, 9), @as(f64, 9),
    });
    objc.msg(void, path, "fill", .{});
    if (req.text.len > 0) {
        const fg = s.ctx.theme.text;
        const fg_color = objc.msg(objc.Object, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{ @as(f64, fg.r), @as(f64, fg.g), @as(f64, fg.b), @as(f64, 1) });
        const attrs = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ fg_color, objc.nsString("NSColor") });
        const ns_str = objc.nsString(req.text);
        objc.msg(void, ns_str, "drawInRect:withAttributes:", .{
            objc.CGRect{ .origin = .{ .x = 10, .y = (h - 16) * 0.5 }, .size = .{ .width = w - 20, .height = 18 } },
            attrs,
        });
    }
    objc.msg(void, img, "unlockFocus", .{});
    const pb_item = objc.new("NSPasteboardItem");
    defer objc.release(pb_item);
    _ = objc.msg(objc.BOOL, pb_item, "setString:forType:", .{ objc.nsString(req.text), objc.nsString("public.utf8-plain-text") });
    const drag_item = objc.msg(objc.Object, objc.alloc("NSDraggingItem"), "initWithPasteboardWriter:", .{pb_item});
    defer objc.release(drag_item);
    const frame = objc.CGRect{ .origin = .{ .x = s.ctx.input.mouse.x - w * 0.5, .y = s.ctx.input.mouse.y - h * 0.5 }, .size = .{ .width = w, .height = h } };
    objc.msg(void, drag_item, "setDraggingFrame:contents:", .{ frame, img });
    const items = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{drag_item});
    _ = objc.msg(?objc.Object, s.nsview, "beginDraggingSessionWithItems:event:source:", .{ items, event, s.nsview });
}

pub fn attachBackdrop(self: *Surface, stage_view: objc.Object) void {
    const host_class = objc.defineClass(.{
        .name = "NanoUIHostView",
        .superclass = "NSView",
        .methods = &.{.{ .name = "isFlipped", .imp = &yes, .types = "c@:" }},
    });
    const b = objc.msg(objc.CGRect, self.nsview, "bounds", .{});
    const host = objc.msg(objc.Object, objc.msg(objc.Object, host_class, "alloc", .{}), "initWithFrame:", .{b});
    objc.msg(void, host, "setWantsLayer:", .{objc.YES});
    objc.msg(void, host, "setAutoresizingMask:", .{@as(objc.NSUInteger, 2 | 16)});
    objc.msg(void, self.nsview, "retain", .{});
    defer objc.msg(void, self.nsview, "release", .{});
    objc.msg(void, self.window.nswindow, "setContentView:", .{host});
    objc.msg(void, stage_view, "setFrame:", .{b});
    objc.msg(void, stage_view, "setAutoresizingMask:", .{@as(objc.NSUInteger, 2 | 16)});
    objc.msg(void, self.nsview, "setFrame:", .{b});
    objc.msg(void, self.nsview, "setAutoresizingMask:", .{@as(objc.NSUInteger, 2 | 16)});
    objc.msg(void, host, "addSubview:", .{stage_view});
    objc.msg(void, host, "addSubview:", .{self.nsview});
    if (self.ctx.focus != 0) _ = objc.msg(objc.BOOL, self.window.nswindow, "makeFirstResponder:", .{self.nsview});
    objc.release(host);
    self.setTransparent(true);
    self.hosted = true;
    self.geometry_changed = true;
}
