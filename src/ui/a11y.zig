//! Accessibility (`NSAccessibility`): turns the frame's interactive boxes
//! into `NSAccessibilityElement` children of `NanoUIView` for VoiceOver
//! and automated accessibility queries, and posts spoken announcements.
const std = @import("std");
const objc = @import("../objc.zig");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Surface = @import("surface.zig").Surface;

pub const ElementPayload = struct {
    surface: *Surface,
    id: u64,
    role: ctx_mod.A11yRole,
    /// On `gpa` (the surface's), replaced on each update.
    label: []u8 = &.{},
    value: []u8 = &.{},
    selected: bool = false,
    enabled: bool = true,
    adjustable: bool = false,

    /// Takes the item's state, its label and value copied.
    pub fn update(p: *ElementPayload, gpa: std.mem.Allocator, it: ctx_mod.A11yItem) void {
        p.role = it.role;
        p.selected = it.selected;
        p.enabled = it.enabled;
        p.adjustable = it.adjustable;
        if (!std.mem.eql(u8, p.label, it.label)) p.label = swap(gpa, p.label, it.label);
        if (!std.mem.eql(u8, p.value, it.value)) p.value = swap(gpa, p.value, it.value);
    }

    fn swap(gpa: std.mem.Allocator, old: []u8, new: []const u8) []u8 {
        gpa.free(old);
        return gpa.dupe(u8, new) catch &.{};
    }

    pub fn deinit(p: *ElementPayload, gpa: std.mem.Allocator) void {
        gpa.free(p.label);
        gpa.free(p.value);
    }
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
            .{ .name = "dealloc", .imp = &elemDealloc, .types = "v@:" },
            .{ .name = "isAccessibilityElement", .imp = &elemYes, .types = "c@:" },
            .{ .name = "isAccessibilityEnabled", .imp = &elemEnabled, .types = "c@:" },
            .{ .name = "isAccessibilitySelected", .imp = &elemSelected, .types = "c@:" },
            .{ .name = "accessibilityParent", .imp = &elemParent, .types = "@@:" },
            .{ .name = "accessibilityRole", .imp = &elemRole, .types = "@@:" },
            .{ .name = "accessibilitySubrole", .imp = &elemSubrole, .types = "@@:" },
            .{ .name = "accessibilityLabel", .imp = &elemLabel, .types = "@@:" },
            .{ .name = "accessibilityValue", .imp = &elemValue, .types = "@@:" },
            .{ .name = "accessibilityFrame", .imp = &elemFrame, .types = "{CGRect={CGPoint=dd}{CGSize=dd}}@:" },
            .{ .name = "accessibilityPerformPress", .imp = &elemPress, .types = "c@:" },
            .{ .name = "accessibilityPerformIncrement", .imp = &elemIncrement, .types = "c@:" },
            .{ .name = "accessibilityPerformDecrement", .imp = &elemDecrement, .types = "c@:" },
            .{ .name = "isAccessibilitySelectorAllowed:", .imp = &elemAllowed, .types = "c@::" },
        },
    });
}

fn pruneCache(s: *Surface) void {
    var stale: [64]u64 = undefined;
    var n: usize = 0;
    var it = s.a11y_cache.keyIterator();
    outer: while (it.next()) |k| {
        for (s.ctx.a11y_items.items) |item| if (item.id == k.*) continue :outer;
        stale[n] = k.*;
        n += 1;
        if (n == stale.len) break;
    }
    for (stale[0..n]) |k| if (s.a11y_cache.fetchRemove(k)) |kv| {
        if (payloadOf(kv.value)) |p| {
            objc.setZig(kv.value, null);
            p.deinit(s.gpa);
            s.gpa.destroy(p);
        }
        objc.release(kv.value);
    };
}

fn viewChildren(obj: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const s = objc.getZig(Surface, obj) orelse return objc.msg(objc.Object, objc.class("NSArray"), "array", .{});
    if (s.a11y_cache.count() > s.ctx.a11y_items.items.len + 64) pruneCache(s);
    const arr = objc.msg(objc.Object, objc.class("NSMutableArray"), "arrayWithCapacity:", .{@as(objc.NSUInteger, s.ctx.a11y_items.items.len)});
    const cls = elementClass();
    for (s.ctx.a11y_items.items) |it| {
        const gop = s.a11y_cache.getOrPut(s.gpa, it.id) catch continue;
        if (!gop.found_existing) {
            const p = s.gpa.create(ElementPayload) catch continue;
            p.* = .{ .surface = s, .id = it.id, .role = it.role };
            const el = objc.msg(objc.Object, cls, "new", .{});
            objc.setZig(el, p);
            gop.value_ptr.* = el;
        }
        const el = gop.value_ptr.*;
        if (payloadOf(el)) |p| p.update(s.gpa, it);
        objc.msg(void, arr, "addObject:", .{el});
    }
    return arr;
}

pub fn clearCache(s: *Surface) void {
    var it = s.a11y_cache.valueIterator();
    while (it.next()) |el_ptr| {
        if (payloadOf(el_ptr.*)) |p| {
            objc.setZig(el_ptr.*, null);
            p.deinit(s.gpa);
            s.gpa.destroy(p);
        }
        objc.release(el_ptr.*);
    }
    s.a11y_cache.deinit(s.gpa);
}

fn payloadOf(obj: objc.Object) ?*ElementPayload {
    return objc.getZig(ElementPayload, obj);
}

fn elemDealloc(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    if (payloadOf(obj)) |p| {
        objc.setZig(obj, null);
        p.deinit(p.surface.gpa);
        p.surface.gpa.destroy(p);
    }
    objc.msgSuper(void, obj, objc.class("NSAccessibilityElement"), "dealloc", .{});
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

fn elemRole(obj: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const p = payloadOf(obj) orelse return objc.nsString("AXUnknown");
    return objc.nsString(switch (p.role) {
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
    });
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

fn elemValue(obj: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const p = payloadOf(obj) orelse return objc.nsString("");
    if (p.value.len > 0) return objc.nsString(p.value);
    return switch (p.role) {
        .checkbox, .switch_toggle, .tab, .radio_button => objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{if (p.selected) objc.YES else objc.NO}),
        else => objc.nsString(""),
    };
}

fn elemFrame(obj: objc.Object, _: objc.SEL) callconv(.c) objc.CGRect {
    const p = payloadOf(obj) orelse return .{};
    const r = p.surface.ctx.rects.get(p.id) orelse return .{};
    const local: objc.CGRect = .{
        .origin = .{ .x = r.x, .y = r.y },
        .size = .{ .width = r.w, .height = r.h },
    };
    const in_win = objc.msg(objc.CGRect, p.surface.nsview, "convertRect:toView:", .{ local, @as(?objc.Object, null) });
    return objc.msg(objc.CGRect, p.surface.window.nswindow, "convertRectToScreen:", .{in_win});
}

fn elemPress(obj: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    const p = payloadOf(obj) orelse return objc.NO;
    const r = p.surface.ctx.rects.get(p.id) orelse return objc.NO;
    const s = p.surface;
    s.ctx.input.mouse = .{ .x = r.x + r.w * 0.5, .y = r.y + r.h * 0.5 };
    s.ctx.updateHot();
    s.ctx.input.click_count = 1;
    s.ctx.input.button = .left;
    s.ctx.pointerDown();
    s.frame();
    s.ctx.pointerUp();
    s.frame();
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
    if (!p.adjustable) return objc.NO;
    p.surface.ctx.a11yStep(p.id, dir);
    p.surface.frame();
    return objc.YES;
}

/// Only adjustable elements offer AXIncrement / AXDecrement.
fn elemAllowed(obj: objc.Object, _: objc.SEL, s: objc.SEL) callconv(.c) objc.BOOL {
    if (s == objc.sel("accessibilityPerformIncrement") or s == objc.sel("accessibilityPerformDecrement")) {
        const p = payloadOf(obj) orelse return objc.NO;
        return if (p.adjustable) objc.YES else objc.NO;
    }
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
