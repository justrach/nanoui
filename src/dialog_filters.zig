//! Named filter groups in an open or save panel (macOS): a popup in the
//! panel's accessory view ("Show: All Media / Audio / Images"), whose choice
//! sets the content types the panel allows. AppKit has no list of named
//! types of its own for NSOpenPanel, so this is the accessory Apple's
//! documentation suggests.
const std = @import("std");
const objc = @import("objc.zig");
const dialog_types = @import("dialog_types.zig");
const Filter = dialog_types.Filter;

/// The popup's target while the panel is up: the groups and the panel the
/// choice is applied to. Lives on the caller's stack for `runModal`.
pub const Accessory = struct {
    panel: objc.Object,
    groups: []const Filter,
    view: ?objc.Object = null,
    popup: ?objc.Object = null,
    target: ?objc.Object = null,

    /// The accessory view for `a.groups`, set on the panel, and the first
    /// group applied. Nothing for fewer than two groups (one is applied as
    /// it is). Undo with `deinit` once the panel is done.
    pub fn attach(a: *Accessory) void {
        if (a.groups.len == 0) return;
        apply(a.panel, a.groups[0]);
        if (a.groups.len < 2) return;
        const cls = objc.defineClass(.{ .name = "NanoUIFilterTarget", .methods = &.{
            .{ .name = "filterChanged:", .imp = &changed, .types = "v@:@" },
        } });
        const target = objc.msg(objc.Object, cls, "new", .{});
        objc.setZig(target, a);
        a.target = target;
        const popup = objc.msg(objc.Object, objc.alloc("NSPopUpButton"), "initWithFrame:pullsDown:", .{ objc.CGRect{ .origin = .{ .x = 60, .y = 8 }, .size = .{ .width = 240, .height = 26 } }, objc.NO });
        a.popup = popup;
        for (a.groups) |g| objc.msg(void, popup, "addItemWithTitle:", .{objc.nsString(if (g.name.len > 0) g.name else "Files")});
        objc.msg(void, popup, "setTarget:", .{target});
        objc.msg(void, popup, "setAction:", .{objc.sel("filterChanged:")});
        const view = objc.msg(objc.Object, objc.alloc("NSView"), "initWithFrame:", .{objc.CGRect{ .size = .{ .width = 320, .height = 42 } }});
        a.view = view;
        const label = objc.msg(objc.Object, objc.class("NSTextField"), "labelWithString:", .{objc.nsString("Show:")});
        objc.msg(void, label, "setFrame:", .{objc.CGRect{ .origin = .{ .x = 8, .y = 13 }, .size = .{ .width = 50, .height = 17 } }});
        objc.msg(void, label, "setAlignment:", .{@as(objc.NSInteger, 1)}); // NSTextAlignmentRight
        objc.msg(void, view, "addSubview:", .{label});
        objc.msg(void, view, "addSubview:", .{popup});
        if (objc.msg(objc.BOOL, a.panel, "respondsToSelector:", .{objc.sel("setAccessoryView:")})) objc.msg(void, a.panel, "setAccessoryView:", .{view});
        // An open panel hides its accessory behind "Options" unless told.
        if (objc.msg(objc.BOOL, a.panel, "respondsToSelector:", .{objc.sel("setAccessoryViewDisclosed:")})) objc.msg(void, a.panel, "setAccessoryViewDisclosed:", .{objc.YES});
    }

    /// The group the popup shows.
    pub fn selected(a: *const Accessory) usize {
        const p = a.popup orelse return 0;
        const i = objc.msg(objc.NSInteger, p, "indexOfSelectedItem", .{});
        return if (i < 0) 0 else @min(@as(usize, @intCast(i)), a.groups.len - 1);
    }

    pub fn deinit(a: *Accessory) void {
        if (a.view != null and objc.msg(objc.BOOL, a.panel, "respondsToSelector:", .{objc.sel("setAccessoryView:")})) objc.msg(void, a.panel, "setAccessoryView:", .{@as(?objc.Object, null)});
        if (a.popup) |p| {
            objc.msg(void, p, "setTarget:", .{@as(?objc.Object, null)});
            objc.release(p);
        }
        if (a.view) |v| objc.release(v);
        if (a.target) |t| {
            objc.setZig(t, null);
            objc.release(t);
        }
        a.* = .{ .panel = a.panel, .groups = a.groups };
    }

    fn changed(self: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
        const a = objc.getZig(Accessory, self) orelse return;
        apply(a.panel, a.groups[a.selected()]);
    }
};

/// The panel shows what `g` names: its extensions' types, or every file.
pub fn apply(panel: objc.Object, g: Filter) void {
    const types = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for (g.extensions) |ext| {
        const ut = objc.msg(?objc.Object, objc.class("UTType"), "typeWithFilenameExtension:", .{objc.nsString(ext)}) orelse continue;
        objc.msg(void, types, "addObject:", .{ut});
    }
    // An empty list allows every file, as a panel never told any.
    objc.msg(void, panel, "setAllowedContentTypes:", .{types});
}

/// A stand-in for the panel in the tests: it keeps the types it is given
/// and the accessory view, and is never shown.
const FakePanel = struct {
    types: usize = 0,
    first: [32]u8 = @splat(0),
    accessory: bool = false,

    fn setTypes(self: objc.Object, _: objc.SEL, types: objc.Object) callconv(.c) void {
        const f = objc.getZig(FakePanel, self) orelse return;
        f.types = objc.msg(objc.NSUInteger, types, "count", .{});
        f.first = @splat(0);
        if (f.types == 0) return;
        const ut = objc.msg(objc.Object, types, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
        const ext = objc.fromNSString(objc.msg(?objc.Object, ut, "preferredFilenameExtension", .{}));
        @memcpy(f.first[0..@min(ext.len, 31)], ext[0..@min(ext.len, 31)]);
    }

    fn setAccessory(self: objc.Object, _: objc.SEL, view: ?objc.Object) callconv(.c) void {
        const f = objc.getZig(FakePanel, self) orelse return;
        f.accessory = view != null;
    }
};

test "filter groups: the popup lists them, and a choice sets the panel's types" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const cls = objc.defineClass(.{ .name = "NanoUITestFilterPanel", .methods = &.{
        .{ .name = "setAllowedContentTypes:", .imp = &FakePanel.setTypes, .types = "v@:@" },
        .{ .name = "setAccessoryView:", .imp = &FakePanel.setAccessory, .types = "v@:@" },
    } });
    var fake: FakePanel = .{};
    const panel = objc.msg(objc.Object, cls, "new", .{});
    defer objc.release(panel);
    objc.setZig(panel, &fake);
    const groups = [_]Filter{
        .{ .name = "All Media", .extensions = &.{ "mov", "wav", "png" } },
        .{ .name = "Audio", .extensions = &.{ "wav", "aiff" } },
        .{ .name = "All Files" },
    };
    var a: Accessory = .{ .panel = panel, .groups = &groups };
    a.attach();
    try std.testing.expect(fake.accessory);
    try std.testing.expectEqual(@as(usize, 3), fake.types);
    try std.testing.expectEqualStrings("mov", std.mem.sliceTo(&fake.first, 0));
    const popup = a.popup.?;
    try std.testing.expectEqual(@as(objc.NSInteger, 3), objc.msg(objc.NSInteger, popup, "numberOfItems", .{}));
    try std.testing.expectEqualStrings("Audio", objc.fromNSString(objc.msg(?objc.Object, popup, "itemTitleAtIndex:", .{@as(objc.NSInteger, 1)})));
    // The user picks Audio: the popup sends its action.
    objc.msg(void, popup, "selectItemAtIndex:", .{@as(objc.NSInteger, 1)});
    _ = objc.msg(objc.BOOL, popup, "sendAction:to:", .{ objc.sel("filterChanged:"), a.target.? });
    try std.testing.expectEqual(@as(usize, 1), a.selected());
    try std.testing.expectEqual(@as(usize, 2), fake.types);
    try std.testing.expectEqualStrings("wav", std.mem.sliceTo(&fake.first, 0));
    // All Files: no types, every file shown.
    objc.msg(void, popup, "selectItemAtIndex:", .{@as(objc.NSInteger, 2)});
    _ = objc.msg(objc.BOOL, popup, "sendAction:to:", .{ objc.sel("filterChanged:"), a.target.? });
    try std.testing.expectEqual(@as(usize, 0), fake.types);
    a.deinit();
    try std.testing.expect(!fake.accessory);
}

test "one group is applied without an accessory" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const cls = objc.defineClass(.{ .name = "NanoUITestFilterPanel", .methods = &.{
        .{ .name = "setAllowedContentTypes:", .imp = &FakePanel.setTypes, .types = "v@:@" },
        .{ .name = "setAccessoryView:", .imp = &FakePanel.setAccessory, .types = "v@:@" },
    } });
    var fake: FakePanel = .{};
    const panel = objc.msg(objc.Object, cls, "new", .{});
    defer objc.release(panel);
    objc.setZig(panel, &fake);
    const groups = [_]Filter{.{ .name = "", .extensions = &.{"png"} }};
    var a: Accessory = .{ .panel = panel, .groups = &groups };
    a.attach();
    defer a.deinit();
    try std.testing.expect(!fake.accessory);
    try std.testing.expectEqual(@as(usize, 1), fake.types);
}
