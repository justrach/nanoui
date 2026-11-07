//! Keys as agents write them, "cmd+shift+t", "enter", "escape": modifiers
//! and one key, and that key's virtual key code on the Mac (ANSI layout).
const std = @import("std");

pub const Mods = packed struct(u8) {
    cmd: bool = false,
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    @"fn": bool = false,
    _: u3 = 0,
};

pub const Combo = struct {
    mods: Mods = .{},
    /// The key's name, lowercased ("enter", "a", "f5", "[").
    key: []const u8,
};

pub const ParseError = error{ Empty, UnknownKey, UnknownModifier };

/// Splits "cmd+shift+t" into modifiers and a key. "+" alone, or last as in
/// "cmd++", is the plus key.
pub fn parse(buf: []u8, s_in: []const u8) ParseError!Combo {
    const s = std.mem.trim(u8, s_in, " ");
    if (s.len == 0) return error.Empty;
    var mods: Mods = .{};
    var rest = s;
    while (std.mem.indexOfScalar(u8, rest, '+')) |i| {
        if (i == rest.len - 1 and i == 0) break; // "+"
        if (i == 0) return error.UnknownKey;
        const m = rest[0..i];
        if (!setMod(&mods, m)) return error.UnknownModifier;
        rest = rest[i + 1 ..];
        if (rest.len == 0) return error.Empty;
    }
    if (rest.len > buf.len) return error.UnknownKey;
    const key = std.ascii.lowerString(buf, rest);
    const named = alias(key);
    if (macCode(named) == null) return error.UnknownKey;
    return .{ .mods = mods, .key = named };
}

fn setMod(m: *Mods, name_in: []const u8) bool {
    var b: [16]u8 = undefined;
    if (name_in.len > b.len) return false;
    const name = std.ascii.lowerString(&b, name_in);
    const eq = struct {
        fn f(a: []const u8, list: []const []const u8) bool {
            for (list) |x| if (std.mem.eql(u8, a, x)) return true;
            return false;
        }
    }.f;
    if (eq(name, &.{ "cmd", "command", "meta", "super", "win", "⌘" })) m.cmd = true else if (eq(name, &.{ "shift", "⇧" })) m.shift = true else if (eq(name, &.{ "alt", "opt", "option", "⌥" })) m.alt = true else if (eq(name, &.{ "ctrl", "control", "⌃" })) m.ctrl = true else if (eq(name, &.{"fn"})) m.@"fn" = true else return false;
    return true;
}

/// Other names for the same key.
fn alias(k: []const u8) []const u8 {
    const pairs = [_][2][]const u8{
        .{ "return", "enter" },      .{ "esc", "escape" },     .{ "backspace", "delete" },
        .{ "del", "forwarddelete" }, .{ "pgup", "pageup" },    .{ "pgdn", "pagedown" },
        .{ "arrowup", "up" },        .{ "arrowdown", "down" }, .{ "arrowleft", "left" },
        .{ "arrowright", "right" },  .{ "spacebar", "space" }, .{ " ", "space" },
    };
    for (pairs) |p| if (std.mem.eql(u8, k, p[0])) return p[1];
    return k;
}

/// The Mac's virtual key code for a key name (Carbon's kVK_*).
pub fn macCode(k: []const u8) ?u16 {
    if (k.len == 1) {
        const chars = "asdfhgzxcv\x00bqweryt123465=97-80]ou[ip\x00lj'k;\\,/nm.";
        if (std.mem.indexOfScalar(u8, chars, k[0])) |i| if (k[0] != 0) return @intCast(i);
        if (k[0] == '`') return 50;
        if (k[0] == '+') return 24; // with shift on US keyboards; "=" key
        return null;
    }
    const named = [_]struct { []const u8, u16 }{
        .{ "enter", 36 },   .{ "tab", 48 },            .{ "space", 49 }, .{ "delete", 51 },
        .{ "escape", 53 },  .{ "forwarddelete", 117 }, .{ "home", 115 }, .{ "end", 119 },
        .{ "pageup", 116 }, .{ "pagedown", 121 },      .{ "left", 123 }, .{ "right", 124 },
        .{ "down", 125 },   .{ "up", 126 },            .{ "f1", 122 },   .{ "f2", 120 },
        .{ "f3", 99 },      .{ "f4", 118 },            .{ "f5", 96 },    .{ "f6", 97 },
        .{ "f7", 98 },      .{ "f8", 100 },            .{ "f9", 101 },   .{ "f10", 109 },
        .{ "f11", 103 },    .{ "f12", 111 },
    };
    for (named) |n| if (std.mem.eql(u8, k, n[0])) return n[1];
    return null;
}

/// CGEventFlags for the modifiers.
pub fn macFlags(m: Mods) u64 {
    var f: u64 = 0;
    if (m.shift) f |= 0x20000;
    if (m.ctrl) f |= 0x40000;
    if (m.alt) f |= 0x80000;
    if (m.cmd) f |= 0x100000;
    if (m.@"fn") f |= 0x800000;
    return f;
}

test "combos parse: modifiers, aliases, the plus key" {
    var b: [32]u8 = undefined;
    const c = try parse(&b, "Cmd+Shift+T");
    try std.testing.expect(c.mods.cmd and c.mods.shift and !c.mods.alt);
    try std.testing.expectEqualStrings("t", c.key);
    try std.testing.expectEqual(@as(?u16, 17), macCode(c.key));
    try std.testing.expectEqualStrings("enter", (try parse(&b, "return")).key);
    try std.testing.expectEqualStrings("escape", (try parse(&b, "ctrl+esc")).key);
    try std.testing.expectEqualStrings("+", (try parse(&b, "cmd++")).key);
    try std.testing.expectEqualStrings("+", (try parse(&b, "+")).key);
    try std.testing.expectError(error.UnknownModifier, parse(&b, "hyper+a"));
    try std.testing.expectError(error.UnknownKey, parse(&b, "cmd+banana"));
    try std.testing.expectError(error.Empty, parse(&b, " "));
    try std.testing.expectEqual(@as(u64, 0x120000), macFlags((try parse(&b, "shift+cmd+left")).mods));
}

test "the Mac's key codes" {
    const expect = [_]struct { []const u8, u16 }{
        .{ "a", 0 },  .{ "s", 1 },  .{ "b", 11 },   .{ "q", 12 }, .{ "1", 18 },  .{ "5", 23 }, .{ "=", 24 },
        .{ "0", 29 }, .{ "o", 31 }, .{ "l", 37 },   .{ "'", 39 }, .{ "\\", 42 }, .{ "/", 44 }, .{ "m", 46 },
        .{ ".", 47 }, .{ "`", 50 }, .{ "up", 126 },
    };
    for (expect) |e| try std.testing.expectEqual(@as(?u16, e[1]), macCode(e[0]));
}
