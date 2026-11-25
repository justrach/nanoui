//! VoiceOver on iOS: the frame's accessibility tree (`ui/access.zig`, the
//! same one the Mac reads) as `UIAccessibilityElement`s of the view, and
//! what the system asks of the view before each frame: Dynamic Type,
//! Increase Contrast, Bold Text, whether VoiceOver runs.
//!
//! An element keeps its object while its box keeps its id, so VoiceOver's
//! focus stays on it across frames. Activating one (a double tap) clicks
//! its box (`Context.a11yPress`); swiping up or down on an adjustable one
//! steps it (`Context.a11yStep`). A listbox is a list container
//! (`UIAccessibilityContainerTypeList`) holding its options.
const std = @import("std");
const objc = @import("../objc.zig");
const access = @import("../ui/access.zig");
const Surface = @import("surface.zig").Surface;

extern "c" const UIAccessibilityTraitButton: u64;
extern "c" const UIAccessibilityTraitLink: u64;
extern "c" const UIAccessibilityTraitHeader: u64;
extern "c" const UIAccessibilityTraitSelected: u64;
extern "c" const UIAccessibilityTraitNotEnabled: u64;
extern "c" const UIAccessibilityTraitStaticText: u64;
extern "c" const UIAccessibilityTraitImage: u64;
extern "c" const UIAccessibilityTraitAdjustable: u64;
extern "c" const UIAccessibilityLayoutChangedNotification: u32;
extern "c" const UIAccessibilityScreenChangedNotification: u32;
extern "c" const UIAccessibilityAnnouncementNotification: u32;
extern "c" fn UIAccessibilityPostNotification(notification: u32, argument: ?objc.Object) void;
extern "c" fn UIAccessibilityIsVoiceOverRunning() bool;
extern "c" fn UIAccessibilityDarkerSystemColorsEnabled() bool;
extern "c" fn UIAccessibilityIsReduceTransparencyEnabled() bool;
extern "c" fn UIAccessibilityIsBoldTextEnabled() bool;
extern "c" fn UIAccessibilityConvertFrameToScreenCoordinates(rect: objc.CGRect, view: objc.Object) objc.CGRect;
/// `UIAccessibilityContainerType`.
const container_none: objc.NSInteger = 0;
const container_list: objc.NSInteger = 2;

const Payload = struct {
    surface: *Surface,
    id: u64,
    adjustable: bool = false,
    /// Inside a listbox: its frame is converted from `rect`, as the
    /// container is an element rather than the view.
    nested: bool = false,
    rect: objc.CGRect = .{},
    /// The build that last listed it: older ones are let go.
    seen: u64 = 0,
};

pub const State = struct {
    cache: std.AutoHashMapUnmanaged(u64, objc.Object) = .empty,
    /// The elements of frame `built` (retained), for UIKit's asks between frames.
    array: ?objc.Object = null,
    built: u64 = std.math.maxInt(u64),
    builds: u64 = 0,
    /// What was read last (ids, labels, values): a change is a new layout.
    hash: u64 = 0,
    arena: std.heap.ArenaAllocator,
    text_category: [64]u8 = undefined,
    text_category_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator) State {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(st: *State, gpa: std.mem.Allocator) void {
        var it = st.cache.valueIterator();
        while (it.next()) |el| forget(gpa, el.*);
        st.cache.deinit(gpa);
        if (st.array) |a| objc.release(a);
        st.arena.deinit();
    }
};

fn forget(gpa: std.mem.Allocator, el: objc.Object) void {
    if (objc.getZig(Payload, el)) |p| {
        objc.setZig(el, null);
        gpa.destroy(p);
    }
    objc.release(el);
}

pub const view_methods = [_]objc.Method{
    .{ .name = "isAccessibilityElement", .imp = &viewIsElement, .types = "c@:" },
    .{ .name = "accessibilityElements", .imp = &viewElements, .types = "@@:" },
};

fn viewIsElement(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.NO;
}

fn viewElements(obj: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    const s = objc.getZig(Surface, obj) orelse return null;
    return elements(s);
}

fn elementClass() objc.Class {
    return objc.defineClass(.{
        .name = "NanoUIAccessibilityElement",
        .superclass = "UIAccessibilityElement",
        .methods = &.{
            .{ .name = "accessibilityActivate", .imp = &activate, .types = "c@:" },
            .{ .name = "accessibilityIncrement", .imp = &increment, .types = "v@:" },
            .{ .name = "accessibilityDecrement", .imp = &decrement, .types = "v@:" },
            .{ .name = "accessibilityFrame", .imp = &frameOf, .types = "{CGRect={CGPoint=dd}{CGSize=dd}}@:" },
        },
    });
}

/// What the system asks of the view, before a frame.
pub fn beforeFrame(s: *Surface) void {
    const a = &s.ctx.access;
    a.screen_reader = UIAccessibilityIsVoiceOverRunning();
    a.increase_contrast = UIAccessibilityDarkerSystemColorsEnabled();
    a.reduce_transparency = UIAccessibilityIsReduceTransparencyEnabled();
    a.bold_text = UIAccessibilityIsBoldTextEnabled();
    const app = objc.msg(objc.Object, objc.class("UIApplication"), "sharedApplication", .{});
    const name = objc.fromNSString(objc.msg(?objc.Object, app, "preferredContentSizeCategory", .{}));
    const st = &s.access;
    if (name.len <= st.text_category.len and !std.mem.eql(u8, name, st.text_category[0..st.text_category_len])) {
        @memcpy(st.text_category[0..name.len], name);
        st.text_category_len = name.len;
        a.text_scale = access.textScaleOf(name);
        access.applyZoom(&s.ctx);
    }
}

/// After a frame: what the view asked to say, and a new layout for VoiceOver.
pub fn afterFrame(s: *Surface) void {
    const a = &s.ctx.access;
    if (a.screen_changed) {
        a.screen_changed = false;
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, null);
    } else if (a.screen_reader) {
        const before = s.access.hash;
        _ = elements(s);
        if (s.access.hash != before) UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, null);
    }
    if (a.announcement_len > 0) {
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, objc.nsString(a.announcement[0..a.announcement_len]));
        a.announcement_len = 0;
    }
}

/// The last frame's elements, made once per frame.
pub fn elements(s: *Surface) ?objc.Object {
    const st = &s.access;
    if (st.built == s.ctx.frame) if (st.array) |arr| return arr;
    _ = st.arena.reset(.retain_capacity);
    var list: std.ArrayList(access.Element) = .empty;
    access.tree(&s.ctx, st.arena.allocator(), &list) catch return st.array;
    st.builds += 1;
    st.built = s.ctx.frame;
    const arr = objc.msg(objc.Object, objc.class("NSMutableArray"), "arrayWithCapacity:", .{@as(objc.NSUInteger, list.items.len)});
    var h: std.hash.Wyhash = .init(0);
    const cls = elementClass();
    // This build's listboxes and their options, in reading order.
    var boxes: std.AutoArrayHashMapUnmanaged(u64, objc.Object) = .empty;
    for (list.items) |e| {
        h.update(std.mem.asBytes(&e.id));
        h.update(e.label);
        h.update(e.value);
        h.update(&.{ @intFromBool(e.selected), @intFromBool(e.enabled) });
        h.update(std.mem.asBytes(&e.container));
        const gop = st.cache.getOrPut(s.gpa, e.id) catch continue;
        if (!gop.found_existing) {
            const p = s.gpa.create(Payload) catch {
                _ = st.cache.remove(e.id);
                continue;
            };
            p.* = .{ .surface = s, .id = e.id };
            const el = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "initWithAccessibilityContainer:", .{s.uiview});
            objc.setZig(el, p);
            gop.value_ptr.* = el;
        }
        const el = gop.value_ptr.*;
        const p = objc.getZig(Payload, el) orelse continue;
        p.seen = st.builds;
        p.adjustable = e.adjustable;
        update(el, e);
        const listbox = e.role == .listbox;
        objc.msg(void, el, "setIsAccessibilityElement:", .{if (listbox) objc.NO else objc.YES});
        objc.msg(void, el, "setAccessibilityContainerType:", .{if (listbox) container_list else container_none});
        if (listbox) boxes.put(st.arena.allocator(), e.id, objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{})) catch {};
        const kids = if (e.container != 0) boxes.get(e.container) else null;
        p.nested = kids != null;
        p.rect = .{ .origin = .{ .x = e.rect.x, .y = e.rect.y }, .size = .{ .width = e.rect.w, .height = e.rect.h } };
        objc.msg(void, el, "setAccessibilityContainer:", .{if (kids != null) st.cache.get(e.container).? else s.uiview});
        objc.msg(void, kids orelse arr, "addObject:", .{el});
    }
    var it = boxes.iterator();
    while (it.next()) |kv| if (st.cache.get(kv.key_ptr.*)) |box| objc.msg(void, box, "setAccessibilityElements:", .{kv.value_ptr.*});
    st.hash = h.final();
    prune(s);
    if (st.array) |old| objc.release(old);
    st.array = objc.retain(arr);
    return arr;
}

fn update(el: objc.Object, e: access.Element) void {
    objc.msg(void, el, "setAccessibilityLabel:", .{objc.nsString(e.label)});
    objc.msg(void, el, "setAccessibilityValue:", .{objc.nsString(valueOf(e))});
    objc.msg(void, el, "setAccessibilityHint:", .{if (e.hint.len > 0) objc.nsString(e.hint) else if (e.role == .text_field) objc.nsString("Text field. Double tap to edit.") else null});
    objc.msg(void, el, "setAccessibilityTraits:", .{traitsOf(e)});
    const r: objc.CGRect = .{ .origin = .{ .x = e.rect.x, .y = e.rect.y }, .size = .{ .width = e.rect.w, .height = e.rect.h } };
    objc.msg(void, el, "setAccessibilityFrameInContainerSpace:", .{r});
}

fn valueOf(e: access.Element) []const u8 {
    if (e.value.len > 0) return e.value;
    return switch (e.role) {
        .switch_toggle => if (e.selected) "on" else "off",
        .checkbox => if (e.selected) "checked" else "not checked",
        else => "",
    };
}

/// iOS 17's trait for a control that turns on and off: looked up when
/// the app starts, as nanoui runs on iOS 15 too (a plain button there).
fn toggleTrait() u64 {
    const p = @extern(?*const u64, .{ .name = "UIAccessibilityTraitToggleButton", .linkage = .weak });
    return if (p) |t| t.* else 0;
}

pub fn traitsOf(e: access.Element) u64 {
    var t: u64 = switch (e.role) {
        .button, .menu_button, .tab, .radio_button, .popover => UIAccessibilityTraitButton,
        .checkbox, .switch_toggle => UIAccessibilityTraitButton | toggleTrait(),
        .link => UIAccessibilityTraitLink,
        .static_text => UIAccessibilityTraitStaticText,
        .image => UIAccessibilityTraitImage,
        .slider, .splitter => UIAccessibilityTraitAdjustable,
        .text_field, .group, .list, .row, .listbox, .option => 0,
    };
    if (e.adjustable) t |= UIAccessibilityTraitAdjustable;
    if (e.header) t |= UIAccessibilityTraitHeader;
    const choice = switch (e.role) {
        .tab, .radio_button, .button, .row, .option => true,
        else => false,
    };
    if (e.selected and choice) t |= UIAccessibilityTraitSelected;
    if (!e.enabled) t |= UIAccessibilityTraitNotEnabled;
    return t;
}

/// Lets go of the elements whose boxes are gone.
fn prune(s: *Surface) void {
    const st = &s.access;
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

fn activate(obj: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    const p = objc.getZig(Payload, obj) orelse return objc.NO;
    const s = p.surface;
    if (s.dead) return objc.NO;
    s.depth += 1;
    defer s.leave();
    s.ctx.a11yPress(p.id);
    s.frame();
    return objc.YES;
}

/// An element inside a listbox reports its screen frame itself; the others
/// keep UIKit's conversion from `accessibilityFrameInContainerSpace`.
fn frameOf(obj: objc.Object, _: objc.SEL) callconv(.c) objc.CGRect {
    const p = objc.getZig(Payload, obj) orelse return .{};
    if (!p.nested or p.surface.dead) return objc.msgSuper(objc.CGRect, obj, objc.class("UIAccessibilityElement"), "accessibilityFrame", .{});
    return UIAccessibilityConvertFrameToScreenCoordinates(p.rect, p.surface.uiview);
}

fn increment(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    step(obj, 1);
}

fn decrement(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    step(obj, -1);
}

fn step(obj: objc.Object, dir: i8) void {
    const p = objc.getZig(Payload, obj) orelse return;
    const s = p.surface;
    if (!p.adjustable or s.dead) return;
    s.depth += 1;
    defer s.leave();
    s.ctx.a11yStep(p.id, dir);
    s.frame();
}
