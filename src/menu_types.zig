//! Menu templates, the same on every platform: items, their roles and
//! accelerators, and what a click calls.
const std = @import("std");
pub const Kind = enum { normal, checkbox, radio };

pub const Role = enum {
    // Whole menus.
    app_menu,
    edit_menu,
    view_menu,
    window_menu,
    // Items.
    about,
    hide,
    hide_others,
    unhide,
    quit,
    undo,
    redo,
    cut,
    copy,
    paste,
    delete,
    select_all,
    minimize,
    zoom,
    close,
    toggle_full_screen,
    front,
};

/// What a click calls: `.of(&state, State.method)`, where
/// `fn method(s: *State, item: *Item) void`.
pub fn Click(comptime Item: type) type {
    return struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, item: *Item) void,

        pub fn of(ptr: anytype, comptime func: fn (@TypeOf(ptr), *Item) void) @This() {
            const P = @TypeOf(ptr);
            return .{ .ctx = @ptrCast(ptr), .func = struct {
                fn call(c: *anyopaque, item: *Item) void {
                    func(@as(P, @ptrCast(@alignCast(c))), item);
                }
            }.call };
        }
    };
}

pub fn MenuItem(comptime Item: type) type {
    return struct {
        const Self = @This();
        label: []const u8 = "",
        /// "CmdOrCtrl+Shift+K", "Alt+Up", "F5", "Cmd+,".
        accelerator: []const u8 = "",
        role: ?Role = null,
        selector: ?[:0]const u8 = null,
        kind: Kind = .normal,
        checked: bool = false,
        disabled: bool = false,
        hidden: bool = false,
        tooltip: []const u8 = "",
        /// To find the item with `Menu.item`.
        id: []const u8 = "",
        submenu: ?[]const Self = null,
        click: ?Click(Item) = null,
        /// Called before its submenu shows (a menu bar menu, a lazy one):
        /// fill it with `Item.setSubmenu`, refresh titles and checks.
        on_open: ?Click(Item) = null,
        /// Shown in place of the item before it while Option is held.
        alternate: bool = false,
        /// An SF Symbol's name, or a picture's PNG bytes shown at 16 pt (a favicon).
        image_symbol: []const u8 = "",
        image_png: []const u8 = "",
        is_separator: bool = false,

        pub const separator: Self = .{ .is_separator = true };
    };
}

pub const Accelerator = struct {
    mods: usize = 0,
    /// A character, or one of AppKit's function key code points.
    key: u21 = 0,

    pub fn keyString(a: Accelerator, buf: *[8]u8) []const u8 {
        if (a.key == 0) return "";
        const n = std.unicode.utf8Encode(a.key, buf) catch return "";
        return buf[0..n];
    }
};

pub const mod_shift: usize = 1 << 17;
pub const mod_ctrl: usize = 1 << 18;
pub const mod_alt: usize = 1 << 19;
pub const mod_cmd: usize = 1 << 20;

/// Parses "CmdOrCtrl+Shift+K" into AppKit's modifier mask and key.
pub fn parseAccelerator(s: []const u8) Accelerator {
    var a: Accelerator = .{};
    if (s.len == 0) return a;
    var parts = std.mem.splitScalar(u8, s, '+');
    while (parts.next()) |raw| {
        // "Cmd++" names the plus key.
        const p = if (raw.len == 0) "+" else raw;
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(p, "Cmd") or eq(p, "Command") or eq(p, "CmdOrCtrl") or eq(p, "CommandOrControl") or eq(p, "Super") or eq(p, "Meta")) {
            a.mods |= mod_cmd;
        } else if (eq(p, "Ctrl") or eq(p, "Control")) {
            a.mods |= mod_ctrl;
        } else if (eq(p, "Alt") or eq(p, "Option")) {
            a.mods |= mod_alt;
        } else if (eq(p, "Shift")) {
            a.mods |= mod_shift;
        } else a.key = keyOf(p);
    }
    return a;
}

fn keyOf(p: []const u8) u21 {
    const eq = std.ascii.eqlIgnoreCase;
    const named = .{
        .{ "Up", 0xF700 },   .{ "Down", 0xF701 }, .{ "Left", 0xF702 },    .{ "Right", 0xF703 },
        .{ "Enter", '\r' },  .{ "Return", '\r' }, .{ "Tab", '\t' },       .{ "Space", ' ' },
        .{ "Escape", 0x1b }, .{ "Esc", 0x1b },    .{ "Backspace", 0x08 }, .{ "Delete", 0x7f },
        .{ "Home", 0xF729 }, .{ "End", 0xF72B },  .{ "PageUp", 0xF72C },  .{ "PageDown", 0xF72D },
        .{ "Plus", '+' },
    };
    inline for (named) |n| if (eq(p, n[0])) return n[1];
    if ((p[0] == 'F' or p[0] == 'f') and p.len > 1) {
        if (std.fmt.parseInt(u8, p[1..], 10)) |n| {
            if (n >= 1 and n <= 20) return 0xF704 + @as(u21, n) - 1;
        } else |_| {}
    }
    const view = std.unicode.Utf8View.init(p) catch return 0;
    var it = view.iterator();
    const cp = it.nextCodepoint() orelse return 0;
    return if (cp < 128) std.ascii.toLower(@intCast(cp)) else cp;
}

test "accelerators" {
    const a = parseAccelerator("CmdOrCtrl+Shift+K");
    try std.testing.expectEqual(mod_cmd | mod_shift, a.mods);
    try std.testing.expectEqual(@as(u21, 'k'), a.key);
    try std.testing.expectEqual(@as(u21, 0xF704 + 4), parseAccelerator("F5").key);
    try std.testing.expectEqual(@as(u21, '+'), parseAccelerator("Cmd++").key);
    try std.testing.expectEqual(@as(u21, 0xF700), parseAccelerator("Alt+Up").key);
    try std.testing.expectEqual(mod_alt, parseAccelerator("Alt+Up").mods);
}
