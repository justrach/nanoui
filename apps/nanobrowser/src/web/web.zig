//! The script world of a page, as the rest of the browser calls it: when a
//! document has parsed, when a frame starts and ends, and what the person did.
//! All of these are no-ops on a page with no scripts. See `world.zig` for what a
//! task is, and `prelude_*.js` for the part of the platform written in JS.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const js = @import("../js/js.zig");
const dom = @import("../dom.zig");
const Page = @import("../page.zig").Page;
const world_mod = @import("world.zig");
const bind = @import("bind.zig");
const scripts = @import("scripts.zig");
const page_input = @import("../page_input.zig");
const Value = js.Value;

pub const World = world_mod.World;
pub const Modifiers = struct { ctrl: bool = false, shift: bool = false, alt: bool = false, meta: bool = false };

/// Whether the stderr gets the console (`NANOBROWSER_LOG`).
pub fn setLogging(on: bool) void {
    world_mod.log_to_stderr = on;
}

fn worldFor(p: *Page) ?*World {
    if (p.js) |w| return w;
    return World.create(p) catch |e| {
        std.debug.print("nanobrowser: no scripts on this page: {s}\n", .{@errorName(e)});
        return null;
    };
}

/// The document has parsed: a page with scripts gets its world, before it asks
/// for anything that might answer at once.
pub fn parsed(p: *Page) void {
    if (p.no_scripts) return;
    if (!scripts.hasScripts(p.doc)) return;
    const w = worldFor(p) orelse return;
    if (p.worker != null) @import("prelude.zig").workerScope(w) catch |e| w.report(e);
}

/// The world of a page another page's script has reached for, made if it had none.
/// A frame sandboxed without scripts has one too: its own never run, but what's
/// around it may still reach in, given `allow-same-origin`.
pub fn ensureWorld(p: *Page) ?*World {
    const had = p.js != null;
    const w = worldFor(p) orelse return null;
    if (!had) {
        // Its document has long been there.
        w.runner.phase = .complete;
        w.runner.dom_ready = true;
        w.runner.load_fired = true;
    }
    return w;
}

/// A press somewhere: `auto` popovers it's outside of close.
pub fn lightDismiss(p: *Page, node: ?*dom.Node) void {
    const w = p.js orelse return;
    if (p.doc.top_layer.items.len == 0 or !w.h.lightDismiss.isCallable()) return;
    const target = bind.wrap(w.vm, node) catch return;
    w.task(w.h.lightDismiss, Value.undefined, &.{target});
}

/// Escape, while something shows in the top layer.
pub fn escape(p: *Page) void {
    const w = p.js orelse return;
    if (p.doc.top_layer.items.len == 0 or !w.h.closeWatcher.isCallable()) return;
    w.task(w.h.closeWatcher, Value.undefined, &.{});
}

/// A button with `popovertarget` or `commandfor`: true when it did what it says.
pub fn invoke(p: *Page, button: *dom.Node) bool {
    const w = p.js orelse return false;
    if (!w.h.invoke.isCallable()) return false;
    const target = bind.wrap(w.vm, button) catch return false;
    w.enter();
    defer w.leave();
    const r = w.callReported(w.h.invoke, Value.undefined, &.{target}) orelse return false;
    return w.vm.toBoolean(r);
}

/// A `<details>` was opened or closed by a person.
pub fn detailsToggled(p: *Page, d: *dom.Node) void {
    const w = p.js orelse return;
    if (!w.h.detailsToggled.isCallable()) return;
    const target = bind.wrap(w.vm, d) catch return;
    w.task(w.h.detailsToggled, Value.undefined, &.{target});
}

/// Style and layout now, for one that changed and must be measured.
pub fn layoutNow(p: *Page) void {
    if (p.js) |w| {
        _ = @import("api_geometry.zig").flushLayout(w);
        return;
    }
    const c = p.host.uiContext(p.host.ctx) orelse return;
    @import("../page_view.zig").prepare(p, c, p.viewport_w, p.viewport_h);
}

/// A page is going: scripts in others can't reach it any more.
pub fn forgetPage(p: *Page) void {
    @import("api_frames.zig").forget(p);
}

/// Runs its scripts, in order.
pub fn begin(p: *Page) void {
    const w = p.js orelse return;
    scripts.begin(w);
}

/// Everything else the page asked for may have come: time for `load`?
pub fn loadCheck(p: *Page) void {
    const w = p.js orelse return;
    scripts.checkLoad(w);
}

pub fn scrolled(p: *Page, n: *dom.Node) void {
    const w = p.js orelse return;
    if (!w.hears("scroll")) return;
    for (w.scrolled.items) |x| if (x == n) return;
    w.scrolled.append(w.gpa, n) catch {};
    w.changed();
}

/// What animations and transitions have to say, to anyone listening.
pub fn animationEvents(p: *Page) void {
    const anim = &p.engine.anim;
    if (anim.events.items.len == 0) return;
    const w = p.js orelse {
        anim.events.clearRetainingCapacity();
        return;
    };
    const list = anim.gpa.dupe(@TypeOf(anim.events.items[0]), anim.events.items) catch return;
    defer anim.gpa.free(list);
    anim.events.clearRetainingCapacity();
    if (!w.h.fireAnimation.isCallable()) return;
    const vm = w.vm;
    for (list) |e| {
        if (p.dead) return;
        const name = @tagName(e.kind);
        if (!w.hears(name)) continue;
        w.enter();
        defer w.leave();
        const target = bind.wrap(vm, e.node) catch continue;
        const kind = vm.newString(name) catch continue;
        const what = vm.newString(e.name) catch continue;
        const pseudo = vm.newString(switch (e.pseudo) {
            .none => "",
            .before => "::before",
            .after => "::after",
            .marker => "::marker",
            .backdrop => "::backdrop",
        }) catch continue;
        _ = w.callReported(w.h.fireAnimation, Value.undefined, &.{ target, kind, what, bind.num(e.elapsed), pseudo });
    }
}

/// Runs what waits for a frame, before it lays out.
pub fn frameStart(p: *Page) void {
    const w = p.js orelse return;
    w.redraw_asked = false;
    w.in_frame = true;
    if (w.blur_request) {
        w.blur_request = false;
        if (p.host.uiContext(p.host.ctx)) |c| c.focus = 0;
    }
    if (w.animation.items.len == 0) return;
    const list = w.gpa.dupe(world_mod.AnimationFrame, w.animation.items) catch return;
    defer w.gpa.free(list);
    w.animation.clearRetainingCapacity();
    const vm = w.vm;
    // They stay marked through `list` only while in this task: no collection
    // happens until it ends.
    w.enter();
    const now = Value.fromDouble(@as(f64, @floatFromInt((world_mod.monotonic() -| w.started_ns) / std.time.ns_per_us)) / 1000);
    for (list) |a| _ = w.callReported(a.callback, vm.global().value(), &.{now});
    w.leave();
}

/// After layout: what changed with it, told to scripts. Layout may be dirty again after.
pub fn frameLaid(p: *Page) void {
    const w = p.js orelse return;
    if (p.dead) return;
    const vm = w.vm;
    if (w.told_w != p.viewport_w or w.told_h != p.viewport_h or w.told_dark != p.dark) {
        const first = w.told_w == 0 and w.told_h == 0;
        w.told_w = p.viewport_w;
        w.told_h = p.viewport_h;
        w.told_dark = p.dark;
        if (!first and w.h.viewportChanged.isCallable()) w.task(w.h.viewportChanged, Value.undefined, &.{});
    }
    if (w.scrolled.items.len > 0) {
        const list = w.gpa.dupe(*dom.Node, w.scrolled.items) catch return;
        defer w.gpa.free(list);
        w.scrolled.clearRetainingCapacity();
        for (list) |n| {
            if (p.dead) return;
            const bubbles = n.kind == .document;
            w.enter();
            const target = bind.wrap(vm, n) catch Value.undefined;
            const name = vm.newString("scroll") catch Value.undefined;
            _ = w.callReported(w.h.fire, Value.undefined, &.{ target, name, Value.fromBool(bubbles), Value.false });
            w.leave();
        }
    }
    if (w.frame_observers and w.h.frameObservers.isCallable() and !p.dead) w.task(w.h.frameObservers, Value.undefined, &.{});
}

/// Paint is about to start, or has ended: what scripts did in between runs now.
pub fn paintStart(p: *Page) void {
    if (p.js) |w| w.painting = true;
}

pub fn paintEnd(p: *Page) void {
    const w = p.js orelse return;
    w.painting = false;
    if (w.deferred_events.items.len > 0) {
        const list = w.gpa.dupe(world_mod.Deferred, w.deferred_events.items) catch return;
        defer w.gpa.free(list);
        w.deferred_events.clearRetainingCapacity();
        for (list) |d| {
            if (p.dead) break;
            switch (d) {
                .focus => |f| focusChanged(p, f.old, f.now),
                .event => |e| simpleEvent(p, e.node, e.name),
                .submit => |s| page_input.submit(p, s.form, s.submitter),
            }
        }
    }
}

/// The frame is over, however it ended: another if something still waits for one.
pub fn frameEnd(p: *Page, c: *ui.Context) void {
    const w = p.js orelse return;
    w.painting = false;
    if (!p.dead and (w.animation.items.len > 0 or w.redraw_due)) c.animationFrame();
    w.redraw_due = false;
    w.in_frame = false;
}

fn fireIf(w: *World, target: Value, name: []const u8, bubbles: bool, cancelable: bool) bool {
    if (!w.hears(name)) return true;
    const vm = w.vm;
    w.enter();
    defer w.leave();
    const n = vm.newString(name) catch return true;
    const r = w.callReported(w.h.fire, Value.undefined, &.{ target, n, Value.fromBool(bubbles), Value.fromBool(cancelable) }) orelse return true;
    return vm.toBoolean(r);
}

pub fn pointerMoved(p: *Page, old: ?*dom.Node, node: ?*dom.Node, x: f32, y: f32) void {
    const w = p.js orelse return;
    if (!w.pointer_heard or p.dead) return;
    const vm = w.vm;
    w.enter();
    defer w.leave();
    const a = bind.wrap(vm, old) catch return;
    const b = bind.wrap(vm, node) catch return;
    _ = w.callReported(w.h.firePointerMove, Value.undefined, &.{ a, b, bind.num(x - p.origin[0]), bind.num(y - p.origin[1]) });
}

/// True when a script prevented what the event would do.
pub fn mouseEvent(p: *Page, node: *dom.Node, name: []const u8, x: f32, y: f32, m: Modifiers) bool {
    const w = p.js orelse return false;
    if (p.dead) return false;
    const pointer = std.mem.eql(u8, name, "mousedown") or std.mem.eql(u8, name, "mouseup");
    if (!w.hears(name) and !(pointer and w.pointer_heard)) return false;
    const vm = w.vm;
    w.enter();
    defer w.leave();
    const target = bind.wrap(vm, node) catch return false;
    const n = vm.newString(name) catch return false;
    const args = [_]Value{ target, n, bind.num(x - p.origin[0]), bind.num(y - p.origin[1]), Value.fromBool(m.ctrl), Value.fromBool(m.shift), Value.fromBool(m.alt), Value.fromBool(m.meta) };
    const r = w.callReported(w.h.fireMouse, Value.undefined, &args) orelse return false;
    return !vm.toBoolean(r);
}

/// An event with nothing more to say: `input`, `change`. While a frame paints,
/// it waits for the frame to finish.
pub fn simpleEvent(p: *Page, node: *dom.Node, name: []const u8) void {
    const w = p.js orelse return;
    if (p.dead or !w.hears(name)) return;
    if (w.painting) {
        w.deferred_events.append(w.gpa, .{ .event = .{ .node = node, .name = name } }) catch {};
        return;
    }
    const target = bind.wrap(w.vm, node) catch return;
    const bubbles = std.mem.eql(u8, name, "input") or std.mem.eql(u8, name, "change");
    _ = fireIf(w, target, name, bubbles, false);
}

/// True when a script stopped the form.
pub fn submitEvent(p: *Page, form: *dom.Node) bool {
    const w = p.js orelse return false;
    if (p.dead or !w.hears("submit")) return false;
    const target = bind.wrap(w.vm, form) catch return false;
    return !fireIf(w, target, "submit", true, true);
}

/// A frame is painting and a control submitted: the submission waits for the
/// frame's end. True when it was put off.
pub fn deferSubmit(p: *Page, form: *dom.Node, submitter: ?*dom.Node) bool {
    const w = p.js orelse return false;
    if (!w.painting) return false;
    w.deferred_events.append(w.gpa, .{ .submit = .{ .form = form, .submitter = submitter } }) catch return false;
    return true;
}

/// A `javascript:` address.
pub fn runUrl(p: *Page, code: []const u8) void {
    const had = p.js != null;
    const w = worldFor(p) orelse return;
    if (!had) {
        // A page that had no scripts has long finished loading.
        w.runner.phase = .complete;
        w.runner.dom_ready = true;
        w.runner.load_fired = true;
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(w.gpa);
    percentDecode(w.gpa, code, &buf) catch return;
    w.enter();
    defer w.leave();
    _ = w.vm.eval(buf.items, "javascript:") catch |e| w.report(e);
}

fn percentDecode(gpa: std.mem.Allocator, s: []const u8, out: *std.ArrayList(u8)) !void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const v = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch {
                try out.append(gpa, s[i]);
                continue;
            };
            try out.append(gpa, v);
            i += 2;
        } else try out.append(gpa, s[i]);
    }
}

/// Moves the keyboard's focus, telling scripts.
pub fn setFocus(p: *Page, node: ?*dom.Node) void {
    const old = p.doc.focus;
    if (old == node) return;
    p.doc.focus = node;
    p.doc.touchStyle();
    const w = p.js orelse return;
    w.changed();
    w.blur_request = true;
    if (node) |n| if (n.isTag("input") or n.isTag("textarea")) {
        w.focus_request = n;
        w.blur_request = false;
    };
    focusChanged(p, old, node);
}

/// The focus moved (by a click or a control): the events.
pub fn focusChanged(p: *Page, old: ?*dom.Node, node: ?*dom.Node) void {
    const w = p.js orelse return;
    if (p.dead) return;
    if (!w.hears("focus") and !w.hears("blur") and !w.hears("focusin") and !w.hears("focusout")) return;
    if (w.painting) {
        w.deferred_events.append(w.gpa, .{ .focus = .{ .old = old, .now = node } }) catch {};
        return;
    }
    const vm = w.vm;
    w.enter();
    defer w.leave();
    const a = bind.wrap(vm, old) catch return;
    const b = bind.wrap(vm, node) catch return;
    _ = w.callReported(w.h.fireFocus, Value.undefined, &.{ a, b });
}

/// A picture's fate is known, for its `load` or `error` event. As a task of its own.
pub fn imageDone(p: *Page, n: *dom.Node, ok: bool) void {
    const w = p.js orelse return;
    if (p.dead or w.stopped) return;
    w.images_done.append(w.gpa, .{ .node = n, .ok = ok }) catch return;
    if (w.images_done.items.len == 1) _ = w.timers.add(w, w.h.imageDone, 0, &.{}, false) catch {};
}

/// The page went to another place in itself: a link to a fragment.
pub fn hashNavigated(p: *Page, to: []const u8) void {
    const w = p.js orelse {
        p.setUrl(to, true);
        return;
    };
    if (!w.h.hashChanged.isCallable()) {
        p.setUrl(to, true);
        return;
    }
    w.enter();
    defer w.leave();
    const s = w.vm.newString(to) catch return;
    _ = w.callReported(w.h.hashChanged, Value.undefined, &.{s});
}

/// The tab's back or forward, within what this document pushed: `popstate`.
pub fn historyStep(p: *Page, by: i32) void {
    const w = p.js orelse return;
    if (!w.h.historyStep.isCallable()) return;
    w.task(w.h.historyStep, Value.undefined, &.{Value.fromInt(by)});
}

/// True when a script stopped the wheel's scrolling.
pub fn wheel(p: *Page, node: ?*dom.Node, x: f32, y: f32, dx: f32, dy: f32, m: Modifiers) bool {
    const w = p.js orelse return false;
    if (p.dead or !w.hears("wheel") or node == null) return false;
    const vm = w.vm;
    w.enter();
    defer w.leave();
    const target = bind.wrap(vm, node) catch return false;
    const args = [_]Value{ target, bind.num(x - p.origin[0]), bind.num(y - p.origin[1]), bind.num(dx), bind.num(dy), Value.fromBool(m.ctrl), Value.fromBool(m.shift), Value.fromBool(m.alt), Value.fromBool(m.meta) };
    const r = w.callReported(w.h.fireWheel, Value.undefined, &args) orelse return false;
    return !vm.toBoolean(r);
}

fn keyName(k: anytype) []const u8 {
    return switch (k) {
        .backspace => "Backspace",
        .delete => "Delete",
        .left => "ArrowLeft",
        .right => "ArrowRight",
        .up => "ArrowUp",
        .down => "ArrowDown",
        .home => "Home",
        .end => "End",
        .enter => "Enter",
        .tab => "Tab",
        .escape => "Escape",
        .page_up => "PageUp",
        .page_down => "PageDown",
        .f1 => "F1",
        .f2 => "F2",
        .f3 => "F3",
        .f4 => "F4",
        .f5 => "F5",
        .f6 => "F6",
        .f7 => "F7",
        .f8 => "F8",
        .f9 => "F9",
        .f10 => "F10",
        .f11 => "F11",
        .f12 => "F12",
    };
}

/// A frame's keys, to the focused element or the body: `keydown`, `keypress`,
/// `keyup`. The window only tells of a key when it is pressed, so `keyup` comes
/// straight after. When a script prevents the default, the key goes no further.
pub fn keys(p: *Page, c: *ui.Context) void {
    const w = p.js orelse return;
    if (p.dead) return;
    if (!w.hears("keydown") and !w.hears("keypress") and !w.hears("keyup")) return;
    var buf: [8]u8 = undefined;
    var printable = false;
    const name: []const u8 = blk: {
        if (c.input.key) |k| break :blk keyName(k);
        if (c.input.chars.len > 0 and c.input.chars.len <= 4) {
            printable = true;
            break :blk c.input.chars;
        }
        if (c.input.shortcut) |s| {
            // Plain keys come as `key` or `chars` too: only combinations here.
            if (!s.cmd and !s.ctrl and !s.alt) return;
            if (c.shortcut_taken or s.key >= 0xF700 or s.key == 0x1b or s.key == '\t' or s.key == '\r') return;
            const n = std.unicode.utf8Encode(s.key, &buf) catch return;
            break :blk buf[0..n];
        }
        return;
    };
    const target_node = p.doc.focus orelse p.doc.body() orelse return;
    const vm = w.vm;
    w.enter();
    const target = bind.wrap(vm, target_node) catch Value.undefined;
    const n = vm.newString(name) catch Value.undefined;
    const args = [_]Value{ target, n, Value.fromBool(printable), Value.fromBool(c.input.ctrl), Value.fromBool(c.input.shift), Value.fromBool(c.input.alt), Value.fromBool(c.input.cmd) };
    const r = w.callReported(w.h.fireKey, Value.undefined, &args);
    const allowed = if (r) |x| vm.toBoolean(x) else true;
    w.leave();
    if (!allowed) {
        c.input.key = null;
        c.input.chars = "";
        c.input.ops = &.{};
    }
}

/// The page's focus request, for a field drawn now.
pub fn takeFocusRequest(p: *Page, n: *dom.Node) bool {
    const w = p.js orelse return false;
    if (w.focus_request != n) return false;
    w.focus_request = null;
    return true;
}

/// Everything the console holds: tests and a later panel read it.
pub fn consoleLines(p: *Page) []const world_mod.Line {
    const w = p.js orelse return &.{};
    return w.console.items;
}
