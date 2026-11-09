//! Tray icons: items in the menu bar's status area, with a menu, a title,
//! an SF Symbol or pixels as their icon. A menu alone opens on every click;
//! `on_click` alone takes every click (a menu bar extra opens its panel
//! under `anchor()`); with both, a click calls `on_click` and then opens the
//! menu under the item (a menu bar app that brings its window forward and
//! offers its menu in one click), and a right click only opens the menu
//! (`clickAction`).
const std = @import("std");
const objc = @import("objc.zig");
const menu_mod = @import("menu.zig");

extern "c" fn CGColorSpaceCreateDeviceRGB() ?*anyopaque;
extern "c" fn CGColorSpaceRelease(space: *anyopaque) void;
extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, w: usize, h: usize, bpc: usize, bpr: usize, space: ?*anyopaque, info: u32) ?*anyopaque;
extern "c" fn CGBitmapContextCreateImage(ctx: *anyopaque) ?*anyopaque;
extern "c" fn CGContextRelease(ctx: *anyopaque) void;
extern "c" fn CGImageRelease(image: *anyopaque) void;

/// What a click on a tray calls.
pub const Click = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, tray: *Tray) void };

/// A tray's place in the menu bar, in screen points from the primary
/// screen's top left (as `Window.setPosition` takes them).
pub const Anchor = struct { x: f64, y: f64, width: f64, height: f64 };

pub const Options = struct {
    /// Text shown in the menu bar.
    title: []const u8 = "",
    /// The name of an SF Symbol ("star.fill"), drawn as a template image
    /// that follows the menu bar's appearance.
    symbol: []const u8 = "",
    tooltip: []const u8 = "",
    menu: []const menu_mod.MenuItem = &.{},
    /// Called on a click; with a menu too, before the menu opens. It must
    /// not destroy the tray (defer that: `App.soon`).
    on_click: ?Click = null,
};

/// What a click on a tray does (`Options.on_click`).
pub const ClickAction = enum { none, click, menu, click_then_menu };

/// A left (`right` false) or right click on a tray with `on_click`
/// (`has_click`) and a menu (`has_menu`). A tray with a menu and no
/// `on_click` never asks: the menu is the status item's own and AppKit
/// opens it on every click.
pub fn clickAction(right: bool, has_click: bool, has_menu: bool) ClickAction {
    if (right) return if (has_menu) .menu else if (has_click) .click else .none;
    if (has_click) return if (has_menu) .click_then_menu else .click;
    return if (has_menu) .menu else .none;
}

pub const Tray = struct {
    gpa: std.mem.Allocator,
    /// For `updateMenu`; the app's, which outlives its trays.
    app_name: []const u8 = "",
    item: objc.Object,
    menu: ?*menu_mod.Menu = null,
    target: ?objc.Object = null,
    on_click: ?Click = null,

    pub fn create(gpa: std.mem.Allocator, app_name: []const u8, opts: Options) !*Tray {
        const pool = objc.Pool.push();
        defer pool.pop();
        const self = try gpa.create(Tray);
        errdefer gpa.destroy(self);
        const bar = objc.msg(objc.Object, objc.class("NSStatusBar"), "systemStatusBar", .{});
        // NSVariableStatusItemLength is -1.
        const item = objc.retain(objc.msg(objc.Object, bar, "statusItemWithLength:", .{@as(f64, -1)}));
        self.* = .{ .gpa = gpa, .app_name = app_name, .item = item, .on_click = opts.on_click };
        self.setTitle(opts.title);
        if (opts.symbol.len > 0) self.setSymbol(opts.symbol);
        if (opts.tooltip.len > 0) self.setTooltip(opts.tooltip);
        if (opts.menu.len > 0) try self.setMenu(app_name, opts.menu);
        if (opts.on_click != null) {
            const cls = objc.defineClass(.{ .name = "NanoUITrayTarget", .methods = &.{
                .{ .name = "clicked:", .imp = &clicked, .types = "v@:@" },
            } });
            const target = objc.msg(objc.Object, cls, "new", .{});
            objc.setZig(target, self);
            self.target = target;
            const button = objc.msg(objc.Object, item, "button", .{});
            objc.msg(void, button, "setTarget:", .{target});
            objc.msg(void, button, "setAction:", .{objc.sel("clicked:")});
            // Both buttons, on release: a right click opens the menu alone.
            _ = objc.msg(isize, button, "sendActionOn:", .{@as(objc.NSUInteger, mask_left_up | mask_right_up)});
        }
        return self;
    }

    pub fn destroy(self: *Tray) void {
        const bar = objc.msg(objc.Object, objc.class("NSStatusBar"), "systemStatusBar", .{});
        objc.msg(void, bar, "removeStatusItem:", .{self.item});
        objc.release(self.item);
        if (self.target) |t| {
            objc.setZig(t, null);
            objc.release(t);
        }
        if (self.menu) |m| m.destroy();
        self.gpa.destroy(self);
    }

    pub fn setTitle(self: *Tray, title: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const button = objc.msg(objc.Object, self.item, "button", .{});
        objc.msg(void, button, "setTitle:", .{objc.nsString(title)});
    }

    pub fn setTooltip(self: *Tray, tooltip: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const button = objc.msg(objc.Object, self.item, "button", .{});
        objc.msg(void, button, "setToolTip:", .{objc.nsString(tooltip)});
    }

    pub fn setSymbol(self: *Tray, name: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const button = objc.msg(objc.Object, self.item, "button", .{});
        const img = objc.msg(?objc.Object, objc.class("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", .{
            objc.nsString(name), @as(?objc.Object, null),
        }) orelse return;
        objc.msg(void, img, "setTemplate:", .{objc.YES});
        objc.msg(void, button, "setImage:", .{img});
    }

    /// Shows `bgra` (premultiplied, `width` × `height` pixels at `scale`
    /// pixels a point) as the icon; a template image (only its alpha counts,
    /// drawn in the menu bar's color) when `template`.
    pub fn setImage(self: *Tray, bgra: []const u8, width: usize, height: usize, scale: f64, template: bool) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const space = CGColorSpaceCreateDeviceRGB() orelse return;
        defer CGColorSpaceRelease(space);
        // Premultiplied first, 32-bit little endian: BGRA in memory.
        const ctx = CGBitmapContextCreate(@constCast(bgra.ptr), width, height, 8, width * 4, space, 2 | (2 << 12)) orelse return;
        defer CGContextRelease(ctx);
        const cg = CGBitmapContextCreateImage(ctx) orelse return;
        defer CGImageRelease(cg);
        const size: objc.CGSize = .{ .width = @as(f64, @floatFromInt(width)) / scale, .height = @as(f64, @floatFromInt(height)) / scale };
        const img = objc.msg(objc.Object, objc.alloc("NSImage"), "initWithCGImage:size:", .{ cg, size });
        defer objc.release(img);
        objc.msg(void, img, "setTemplate:", .{template});
        const button = objc.msg(objc.Object, self.item, "button", .{});
        objc.msg(void, button, "setImage:", .{img});
    }

    /// Where the tray is in the menu bar.
    pub fn anchor(self: *Tray) Anchor {
        const button = objc.msg(objc.Object, self.item, "button", .{});
        const win = objc.msg(?objc.Object, button, "window", .{}) orelse return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        const f = objc.msg(objc.CGRect, win, "frame", .{});
        const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
        const primary = objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
        const top = objc.msg(objc.CGRect, primary, "frame", .{}).size.height;
        return .{ .x = f.origin.x, .y = top - f.origin.y - f.size.height, .width = f.size.width, .height = f.size.height };
    }

    // NSEventMaskLeftMouseUp, NSEventMaskRightMouseUp, NSEventTypeRightMouseUp.
    const mask_left_up: objc.NSUInteger = 1 << 2;
    const mask_right_up: objc.NSUInteger = 1 << 4;
    const type_right_up: objc.NSUInteger = 4;

    fn clicked(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
        const self = objc.getZig(Tray, obj) orelse return;
        const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        const event = objc.msg(?objc.Object, nsapp, "currentEvent", .{});
        const right = if (event) |e| objc.msg(objc.NSUInteger, e, "type", .{}) == type_right_up else false;
        const action = clickAction(right, self.on_click != null, self.menu != null);
        if (action == .click or action == .click_then_menu) if (self.on_click) |c| c.func(c.ctx, self);
        // Read after `on_click`, which may have replaced the menu.
        if (action == .menu or action == .click_then_menu) if (self.menu) |m| {
            // The status item's own way to open a menu it does not own
            // (`menu` would take the click from `on_click`); it returns once
            // the menu closes.
            objc.msg(void, self.item, "popUpStatusItemMenu:", .{m.ns});
        };
    }

    pub fn setMenu(self: *Tray, app_name: []const u8, template: []const menu_mod.MenuItem) !void {
        const m = try menu_mod.Menu.create(self.gpa, app_name, template);
        if (self.menu) |old| old.destroy();
        self.menu = m;
        // With `on_click` the button's action opens the menu after it; a
        // status item's own menu would take every click instead.
        if (self.on_click == null) objc.msg(void, self.item, "setMenu:", .{m.ns});
    }

    /// Replaces the menu (`setMenu` under the app's name) while it runs:
    /// a status line that changes, a Pause that becomes Resume.
    pub fn updateMenu(self: *Tray, template: []const menu_mod.MenuItem) !void {
        return self.setMenu(self.app_name, template);
    }

    /// The menu's item whose template had `id`, to check or disable.
    pub fn menuItem(self: *Tray, id: []const u8) ?*menu_mod.Item {
        const m = self.menu orelse return null;
        return m.item(id);
    }
};

test "a click with on_click and a menu runs on_click and then opens the menu; a right click only opens it" {
    const t = std.testing;
    try t.expectEqual(ClickAction.click_then_menu, clickAction(false, true, true));
    try t.expectEqual(ClickAction.menu, clickAction(true, true, true));
    try t.expectEqual(ClickAction.click, clickAction(false, true, false));
    try t.expectEqual(ClickAction.click, clickAction(true, true, false));
    try t.expectEqual(ClickAction.menu, clickAction(false, false, true));
    try t.expectEqual(ClickAction.none, clickAction(false, false, false));
}
