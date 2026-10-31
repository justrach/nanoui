//! Menus where nanoui handles them itself (Linux, Windows, Android), from the same
//! templates: kept for their accelerators, which keys reach before the
//! view does ("CmdOrCtrl" is Ctrl there), and their items' state. Native
//! menu bars are not built yet.
const std = @import("std");
const menu_types = @import("menu_types.zig");
const ui = @import("ui/ui.zig");

pub const Kind = menu_types.Kind;
pub const Role = menu_types.Role;
pub const Click = menu_types.Click(Item);
pub const MenuItem = menu_types.MenuItem(Item);
pub const parseAccelerator = menu_types.parseAccelerator;

pub const Item = struct {
    menu: *Menu,
    id: []const u8,
    kind: Kind,
    checked: bool,
    disabled: bool,
    click: ?Click,
    role: ?Role,
    accel: menu_types.Accelerator,

    pub fn setChecked(self: *Item, on: bool) void {
        self.checked = on;
    }

    pub fn setEnabled(self: *Item, on: bool) void {
        self.disabled = !on;
    }

    pub fn setAccelerator(self: *Item, accel: []const u8) void {
        self.accel = parseAccelerator(accel);
    }
};

pub const Menu = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Item) = .empty,

    pub fn create(gpa: std.mem.Allocator, template: []const MenuItem) !*Menu {
        const m = try gpa.create(Menu);
        m.* = .{ .gpa = gpa };
        errdefer m.destroy();
        try m.add(template);
        return m;
    }

    fn add(m: *Menu, template: []const MenuItem) !void {
        for (template) |t| {
            if (t.is_separator or t.hidden) continue;
            if (t.submenu) |sub| {
                try m.add(sub);
                continue;
            }
            try m.items.append(m.gpa, .{
                .menu = m,
                .id = t.id,
                .kind = t.kind,
                .checked = t.checked,
                .disabled = t.disabled,
                .click = t.click,
                .role = t.role,
                .accel = parseAccelerator(t.accelerator),
            });
        }
    }

    pub fn destroy(m: *Menu) void {
        m.items.deinit(m.gpa);
        m.gpa.destroy(m);
    }

    pub fn item(m: *Menu, id: []const u8) ?*Item {
        for (m.items.items) |*it| if (std.mem.eql(u8, it.id, id)) return it;
        return null;
    }

    /// The item whose accelerator is this key combination, if one is.
    pub fn match(m: *Menu, sc: ui.Shortcut) ?*Item {
        for (m.items.items) |*it| {
            const a = it.accel;
            if (a.key == 0 or it.disabled) continue;
            // Cmd (CmdOrCtrl) and Ctrl are both Ctrl on Linux.
            const ctrl = a.mods & (menu_types.mod_cmd | menu_types.mod_ctrl) != 0;
            const shift = a.mods & menu_types.mod_shift != 0;
            const alt = a.mods & menu_types.mod_alt != 0;
            if (a.key == sc.key and ctrl == sc.ctrl and shift == sc.shift and alt == sc.alt) return it;
        }
        return null;
    }

    /// Runs an item as a click would.
    pub fn activate(it: *Item) void {
        switch (it.kind) {
            .checkbox => it.checked = !it.checked,
            .radio => it.checked = true,
            .normal => {},
        }
        if (it.click) |c| c.func(c.ctx, it);
    }
};

test "an accelerator matches its modifiers, and a disabled item matches nothing" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const m = try Menu.create(gpa, &.{
        .{ .id = "copy", .label = "Copy", .accelerator = "CmdOrCtrl+C" },
        .{ .id = "find", .label = "Find", .accelerator = "CmdOrCtrl+Shift+F" },
        .{ .id = "quiet", .label = "Quiet", .accelerator = "F2", .disabled = true },
        .{ .id = "alt", .label = "Alt", .accelerator = "Alt+Left" },
    });
    defer m.destroy();
    // Ctrl+C, any shift; the shift variant is a different item.
    try testing.expectEqualStrings("copy", m.match(.{ .key = 'c', .ctrl = true }).?.id);
    try testing.expectEqualStrings("find", m.match(.{ .key = 'f', .ctrl = true, .shift = true }).?.id);
    try testing.expect(m.match(.{ .key = 'f', .ctrl = true }) == null);
    // Alt is its own modifier, and it is not Ctrl.
    try testing.expectEqualStrings("alt", m.match(.{ .key = ui.Shortcut.left, .alt = true }).?.id);
    try testing.expect(m.match(.{ .key = ui.Shortcut.left, .ctrl = true }) == null);
    // A disabled item never matches, and neither does an unbound key.
    try testing.expect(m.match(.{ .key = @as(u21, @intCast('2')) }) == null);
}

test "activating a checkbox toggles it and a radio sets it, then clicks" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const Clicked = struct { items: u32 = 0 };
    const M = struct {
        fn click(ctx: *anyopaque, _: *Item) void {
            const c: *Clicked = @ptrCast(@alignCast(ctx));
            c.items += 1;
        }
    };
    var clicked: Clicked = .{};
    const m = try Menu.create(gpa, &.{
        .{ .id = "box", .label = "Box", .kind = .checkbox, .click = .{ .ctx = &clicked, .func = M.click } },
        .{ .id = "one", .label = "One", .kind = .radio, .click = .{ .ctx = &clicked, .func = M.click } },
    });
    defer m.destroy();
    Menu.activate(m.item("box").?);
    try testing.expect(m.item("box").?.checked);
    Menu.activate(m.item("box").?);
    try testing.expect(!m.item("box").?.checked);
    Menu.activate(m.item("one").?);
    try testing.expect(m.item("one").?.checked);
    try testing.expectEqual(@as(u32, 3), clicked.items);
}
