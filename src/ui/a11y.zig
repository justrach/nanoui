//! VoiceOver on the Mac (`NSAccessibility`): the frame's accessibility
//! tree (`access.zig`, the same one iOS reads) as `NSAccessibilityElement`
//! children of `NanoUIView`, and what the system asks of the view before
//! each frame: Reduce Motion, Increase Contrast, whether VoiceOver runs.
//!
//! An element keeps its object while its box keeps its id, so VoiceOver's
//! cursor stays on it across frames. Pressing one (VO-Space) clicks its
//! box (`Context.a11yPress`); VO-Up and VO-Down step an adjustable one.
const std = @import("std");
const objc = @import("../objc.zig");
const types = @import("types.zig");
const access = @import("access.zig");
const Theme = @import("theme.zig").Theme;
const Surface = @import("surface.zig").Surface;

pub const Payload = struct {
    surface: *Surface,
    id: u64,
    role: access.Role = .group,
    /// On the surface's `gpa`, replaced when they change.
    label: []u8 = &.{},
    value: []u8 = &.{},
    hint: []u8 = &.{},
    rect: types.Rect = .{},
    selected: bool = false,
    enabled: bool = true,
    adjustable: bool = false,
    header: bool = false,
    /// The build that last listed it: older ones are let go.
    seen: u64 = 0,

    pub fn update(p: *Payload, gpa: std.mem.Allocator, e: access.Element) void {
        p.role = e.role;
        p.rect = e.rect;
        p.selected = e.selected;
        p.enabled = e.enabled;
        p.adjustable = e.adjustable;
        p.header = e.header;
        swap(gpa, &p.label, e.label);
        swap(gpa, &p.value, e.value);
        swap(gpa, &p.hint, e.hint);
    }

    fn swap(gpa: std.mem.Allocator, old: *[]u8, new: []const u8) void {
        if (std.mem.eql(u8, old.*, new)) return;
        gpa.free(old.*);
        old.* = gpa.dupe(u8, new) catch &.{};
    }

    pub fn deinit(p: *Payload, gpa: std.mem.Allocator) void {
        gpa.free(p.label);
        gpa.free(p.value);
        gpa.free(p.hint);
    }
};

pub const State = struct {
    cache: std.AutoHashMapUnmanaged(u64, objc.Object) = .empty,
    /// The elements of frame `built` (retained), for AppKit's asks between frames.
    array: ?objc.Object = null,
    built: u64 = std.math.maxInt(u64),
    builds: u64 = 0,
    /// What was read last (ids, labels, values): a change is a new layout.
    hash: u64 = 0,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
};

pub const methods = [_]objc.Method{
    .{ .name = "isAccessibilityElement", .imp = &viewIsElement, .types = "c@:" },
    .{ .name = "accessibilityRole", .imp = &viewRole, .types = "@@:" },
    .{ .name = "accessibilityChildren", .imp = &viewChildren, .types = "@@:" },
};

fn viewIsElement(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.NO;
}

fn viewRole(_: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    return objc.nsString("AXGroup");
}

fn elementClass() objc.Class {
    return objc.defineClass(.{
        .name = "NanoUIA11yElement",
        .superclass = "NSAccessibilityElement",
        .methods = &.{
            .{ .name = "isAccessibilityElement", .imp = &elemYes, .types = "c@:" },
            .{ .name = "isAccessibilityEnabled", .imp = &elemEnabled, .types = "c@:" },
            .{ .name = "isAccessibilitySelected", .imp = &elemSelected, .types = "c@:" },
            .{ .name = "accessibilityParent", .imp = &elemParent, .types = "@@:" },
            .{ .name = "accessibilityRole", .imp = &elemRole, .types = "@@:" },
            .{ .name = "accessibilitySubrole", .imp = &elemSubrole, .types = "@@:" },
            .{ .name = "accessibilityLabel", .imp = &elemLabel, .types = "@@:" },
            .{ .name = "accessibilityValue", .imp = &elemValue, .types = "@@:" },
            .{ .name = "accessibilityHelp", .imp = &elemHelp, .types = "@@:" },
            .{ .name = "accessibilityFrame", .imp = &elemFrame, .types = "{CGRect={CGPoint=dd}{CGSize=dd}}@:" },
            .{ .name = "accessibilityPerformPress", .imp = &elemPress, .types = "c@:" },
            .{ .name = "accessibilityPerformIncrement", .imp = &elemIncrement, .types = "c@:" },
            .{ .name = "accessibilityPerformDecrement", .imp = &elemDecrement, .types = "c@:" },
            .{ .name = "isAccessibilitySelectorAllowed:", .imp = &elemAllowed, .types = "c@::" },
        },
    });
}

/// What the system asks of the view, before a frame.
pub fn beforeFrame(s: *Surface) void {
    const c = &s.ctx;
    c.reduce_motion = s.reduce_motion;
    c.reduced_motion = s.reduce_motion;
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    c.access.increase_contrast = objc.msg(objc.BOOL, ws, "accessibilityDisplayShouldIncreaseContrast", .{});
    c.access.screen_reader = objc.msg(objc.BOOL, ws, "isVoiceOverEnabled", .{});
}

/// The theme with Increase Contrast's stronger text and borders.
pub fn themed(s: *Surface, t: Theme) Theme {
    return access.themed(&s.ctx, t);
}

/// After a frame: what the view asked to say, and a new layout for VoiceOver.
pub fn afterFrame(s: *Surface) void {
    const a = &s.ctx.access;
    if (a.screen_changed or a.screen_reader) {
        const before = s.a11y_cache.hash;
        _ = elements(s);
        if (a.screen_changed or s.a11y_cache.hash != before) objc.NSAccessibilityPostNotificationWithUserInfo(s.nsview, objc.nsString("AXLayoutChanged"), null);
        a.screen_changed = false;
    }
    if (a.announcement_len > 0) {
        announce(s.nsview, a.announcement[0..a.announcement_len]);
        a.announcement_len = 0;
    }
}

fn viewChildren(obj: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const s = objc.getZig(Surface, obj) orelse return objc.msg(objc.Object, objc.class("NSArray"), "array", .{});
    return elements(s) orelse objc.msg(objc.Object, objc.class("NSArray"), "array", .{});
}

/// The last frame's elements, made once per frame.
pub fn elements(s: *Surface) ?objc.Object {
    const st = &s.a11y_cache;
    if (st.built == s.ctx.frame) if (st.array) |arr| return arr;
    _ = st.arena.reset(.retain_capacity);
    var list: std.ArrayList(access.Element) = .empty;
    access.tree(&s.ctx, st.arena.allocator(), &list) catch return st.array;
    st.builds += 1;
    st.built = s.ctx.frame;
    const arr = objc.msg(objc.Object, objc.class("NSMutableArray"), "arrayWithCapacity:", .{@as(objc.NSUInteger, list.items.len)});
    var h: std.hash.Wyhash = .init(0);
    const cls = elementClass();
    for (list.items) |e| {
        h.update(std.mem.asBytes(&e.id));
        h.update(e.label);
        h.update(e.value);
        h.update(&.{ @intFromBool(e.selected), @intFromBool(e.enabled) });
        const gop = st.cache.getOrPut(s.gpa, e.id) catch continue;
        if (!gop.found_existing) {
            const p = s.gpa.create(Payload) catch {
                _ = st.cache.remove(e.id);
                continue;
            };
            p.* = .{ .surface = s, .id = e.id };
            const el = objc.msg(objc.Object, cls, "new", .{});
            objc.setZig(el, p);
            gop.value_ptr.* = el;
        }
        const el = gop.value_ptr.*;
        const p = objc.getZig(Payload, el) orelse continue;
        p.seen = st.builds;
        p.update(s.gpa, e);
        objc.msg(void, arr, "addObject:", .{el});
    }
    st.hash = h.final();
    prune(s);
    if (st.array) |old| objc.release(old);
    st.array = objc.retain(arr);
    return arr;
}

fn forget(gpa: std.mem.Allocator, el: objc.Object) void {
    if (objc.getZig(Payload, el)) |p| {
        objc.setZig(el, null);
        p.deinit(gpa);
        gpa.destroy(p);
    }
    objc.release(el);
}

/// Lets go of the elements whose boxes are gone.
fn prune(s: *Surface) void {
    const st = &s.a11y_cache;
    var stale: [64]u64 = undefined;
    var n: usize = 0;
    var it = st.cache.iterator();
    while (it.next()) |kv| {
        const p = objc.getZig(Payload, kv.value_ptr.*) orelse continue;
        if (p.seen == st.builds) continue;
        stale[n] = kv.key_ptr.*;
        n += 1;
        if (n == stale.len) break;
    }
    for (stale[0..n]) |k| if (st.cache.fetchRemove(k)) |kv| forget(s.gpa, kv.value);
}

pub fn clearCache(s: *Surface) void {
    const st = &s.a11y_cache;
    var it = st.cache.valueIterator();
    while (it.next()) |el| forget(s.gpa, el.*);
    st.cache.deinit(s.gpa);
    if (st.array) |a| objc.release(a);
    st.array = null;
    st.arena.deinit();
}

fn payloadOf(obj: objc.Object) ?*Payload {
    return objc.getZig(Payload, obj);
}

fn elemYes(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn elemEnabled(obj: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    const p = payloadOf(obj) orelse return objc.NO;
    return if (p.enabled) objc.YES else objc.NO;
}

fn elemSelected(obj: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    const p = payloadOf(obj) orelse return objc.NO;
    return if (p.selected) objc.YES else objc.NO;
}

fn elemParent(obj: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    const p = payloadOf(obj) orelse return null;
    return p.surface.nsview;
}

/// The AppKit role for an element: a heading is AXHeading, as WebKit's.
pub fn roleName(role: access.Role, header: bool) []const u8 {
    if (header and role == .static_text) return "AXHeading";
    return switch (role) {
        .button => "AXButton",
        .tab, .radio_button => "AXRadioButton",
        .text_field => "AXTextField",
        .splitter => "AXSplitter",
        .slider => "AXSlider",
        .checkbox, .switch_toggle => "AXCheckBox",
        .group => "AXGroup",
        .static_text => "AXStaticText",
        .list => "AXList",
        .row => "AXRow",
        .image => "AXImage",
        .menu_button => "AXMenuButton",
        .popover => "AXPopover",
        .link => "AXLink",
    };
}

fn elemRole(obj: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const p = payloadOf(obj) orelse return objc.nsString("AXUnknown");
    return objc.nsString(roleName(p.role, p.header));
}

fn elemSubrole(obj: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    const p = payloadOf(obj) orelse return null;
    return switch (p.role) {
        .switch_toggle => objc.nsString("AXSwitch"),
        .tab => objc.nsString("AXTabButton"),
        else => null,
    };
}

fn elemLabel(obj: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const p = payloadOf(obj) orelse return objc.nsString("");
    return objc.nsString(p.label);
}

fn elemValue(obj: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    const p = payloadOf(obj) orelse return null;
    if (p.value.len > 0) return objc.nsString(p.value);
    return switch (p.role) {
        .checkbox, .switch_toggle, .tab, .radio_button => objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{if (p.selected) objc.YES else objc.NO}),
        .text_field => objc.nsString(""),
        else => null,
    };
}

fn elemHelp(obj: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    const p = payloadOf(obj) orelse return null;
    return if (p.hint.len > 0) objc.nsString(p.hint) else null;
}

/// Its visible part, in screen coordinates.
fn elemFrame(obj: objc.Object, _: objc.SEL) callconv(.c) objc.CGRect {
    const p = payloadOf(obj) orelse return .{};
    const r = p.rect;
    const local: objc.CGRect = .{ .origin = .{ .x = r.x, .y = r.y }, .size = .{ .width = r.w, .height = r.h } };
    const in_win = objc.msg(objc.CGRect, p.surface.nsview, "convertRect:toView:", .{ local, @as(?objc.Object, null) });
    return objc.msg(objc.CGRect, p.surface.window.nswindow, "convertRectToScreen:", .{in_win});
}

fn elemPress(obj: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    const p = payloadOf(obj) orelse return objc.NO;
    if (!p.enabled or p.surface.dead) return objc.NO;
    p.surface.ctx.a11yPress(p.id);
    p.surface.frame();
    return objc.YES;
}

fn elemIncrement(obj: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return step(obj, 1);
}

fn elemDecrement(obj: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return step(obj, -1);
}

/// An adjustable box's step comes to its `interact` in the next frame.
fn step(obj: objc.Object, dir: i8) objc.BOOL {
    const p = payloadOf(obj) orelse return objc.NO;
    if (!p.adjustable or p.surface.dead) return objc.NO;
    p.surface.ctx.a11yStep(p.id, dir);
    p.surface.frame();
    return objc.YES;
}

/// Only adjustable elements offer AXIncrement / AXDecrement; only enabled
/// ones AXPress.
fn elemAllowed(obj: objc.Object, _: objc.SEL, s: objc.SEL) callconv(.c) objc.BOOL {
    const p = payloadOf(obj) orelse return objc.NO;
    if (s == objc.sel("accessibilityPerformIncrement") or s == objc.sel("accessibilityPerformDecrement")) return if (p.adjustable) objc.YES else objc.NO;
    if (s == objc.sel("accessibilityPerformPress")) return if (p.enabled and p.role != .static_text) objc.YES else objc.NO;
    return objc.msgSuper(objc.BOOL, obj, objc.class("NSAccessibilityElement"), "isAccessibilitySelectorAllowed:", .{s});
}

/// Posts a high-priority VoiceOver announcement (`NSAccessibilityAnnouncementRequestedNotification`).
pub fn announce(target: objc.Object, message: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const keys = [_]objc.Object{
        objc.nsString("AXAnnouncementKey"),
        objc.nsString("AXPriorityKey"),
    };
    const prio = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithInteger:", .{@as(objc.NSInteger, 90)});
    const values = [_]objc.Object{
        objc.nsString(message),
        prio,
    };
    const info = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{
        &values, &keys, @as(objc.NSUInteger, 2),
    });
    objc.NSAccessibilityPostNotificationWithUserInfo(target, objc.nsString("AXAnnouncementRequested"), info);
}
