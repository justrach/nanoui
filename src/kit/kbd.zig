//! Shortcuts as key caps: one cap per key (`⌘K` is ⌘ and K), each with a
//! lip along its foot, as on a keyboard. A sequence of chords, split by
//! spaces (`G G`, `⌘K ⌘S`), sets its chords a little further apart than
//! their keys.
const std = @import("std");
const ui = @import("../ui/ui.zig");
const kit = @import("kit.zig");
const Color = ui.Color;

pub const Size = enum {
    /// 20-point caps: a shortcut on its own (a cheat sheet, a binding).
    md,
    /// 16-point caps: inside a 28- to 32-point control (a search field's ⌘K).
    sm,
};

pub const Options = struct {
    size: Size = .md,
    /// The legends' color: a rebound shortcut in the accent, say.
    color: ?Color = null,
};

/// A key or a shortcut as key caps: `kit.kbd(c, ui.keys.label("⌘K"))`,
/// `Ctrl+Shift+K`, `Esc`, `⌘K ⌘S`.
pub fn kbd(c: *ui.Context, keys: []const u8) void {
    kbdWith(c, keys, .{});
}

/// `kbd` at a size, or in another color.
pub fn kbdWith(c: *ui.Context, keys: []const u8, o: Options) void {
    const sm = o.size == .sm;
    _ = c.open(.{ .direction = .row, .align_items = .center, .gap = if (sm) 5 else 7 }, null);
    defer c.end();
    var chords = std.mem.tokenizeScalar(u8, keys, ' ');
    while (chords.next()) |chord| {
        var caps: [max_caps][]const u8 = undefined;
        const n = splitChord(chord, &caps);
        _ = c.open(.{ .direction = .row, .align_items = .center, .gap = if (sm) 2 else 3 }, null);
        for (caps[0..n]) |k| keyCap(c, k, o);
        c.end();
    }
}

pub const max_caps = 6;

/// The modifier glyphs, each a cap of its own.
const modifiers = [_][]const u8{ "⌘", "⇧", "⌥", "⌃" };

fn isModifier(k: []const u8) bool {
    for (modifiers) |m| if (std.mem.eql(u8, k, m)) return true;
    return std.mem.eql(u8, k, "Ctrl") or std.mem.eql(u8, k, "Shift") or std.mem.eql(u8, k, "Alt");
}

/// One chord's keys: split on `+` (`Ctrl+Shift+K`; a trailing `+` is the
/// plus key), else each leading modifier glyph, then the rest as one key
/// (`⌘⇧P` is ⌘ ⇧ P; `Esc`, `F5` and `⌫` stay whole).
pub fn splitChord(chord: []const u8, out: *[max_caps][]const u8) usize {
    var n: usize = 0;
    if (chord.len > 1 and std.mem.indexOfScalar(u8, chord[0 .. chord.len - 1], '+') != null) {
        var start: usize = 0;
        for (chord, 0..) |ch, i| {
            if (n == max_caps) break;
            if (ch == '+' and i > start) {
                out[n] = chord[start..i];
                n += 1;
                start = i + 1;
            }
        }
        if (start < chord.len and n < max_caps) {
            out[n] = chord[start..];
            n += 1;
        }
        return n;
    }
    var rest = chord;
    outer: while (rest.len > 0 and n < max_caps - 1) {
        for (modifiers) |m| if (std.mem.startsWith(u8, rest, m) and rest.len > m.len) {
            out[n] = m;
            n += 1;
            rest = rest[m.len..];
            continue :outer;
        };
        break;
    }
    if (rest.len > 0) {
        out[n] = rest;
        n += 1;
    }
    return n;
}

/// What a cap reads: the arrows as arrows everywhere and, where shortcuts
/// are written with symbols (`ui.keys.mac`), a modifier spelled out
/// (`Cmd+Shift+K`) as its glyph, and Backspace and Return as ⌫ and ↩.
pub fn legend(k: []const u8, mac: bool) []const u8 {
    const arrows = [_][2][]const u8{ .{ "Left", "←" }, .{ "Right", "→" }, .{ "Up", "↑" }, .{ "Down", "↓" } };
    for (arrows) |a| if (std.ascii.eqlIgnoreCase(k, a[0])) return a[1];
    if (!mac) return k;
    const names = [_][2][]const u8{
        .{ "Backspace", "⌫" },
        .{ "Return", "↩" },
        .{ "Enter", "↩" },
        .{ "Cmd", "⌘" },
        .{ "Command", "⌘" },
        .{ "Shift", "⇧" },
        .{ "Opt", "⌥" },
        .{ "Option", "⌥" },
        .{ "Alt", "⌥" },
        .{ "Ctrl", "⌃" },
        .{ "Control", "⌃" },
    };
    for (names) |a| if (std.ascii.eqlIgnoreCase(k, a[0])) return a[1];
    return k;
}

/// One cap: square for a lone character, its legend centred; a symbol
/// (⌘, ⌫, ←) sets a little larger than a letter or a word.
fn keyCap(c: *ui.Context, key: []const u8, o: Options) void {
    const t = kit.tokens(c);
    const k = legend(key, ui.keys.mac);
    const sm = o.size == .sm;
    const h: f32 = if (sm) 16 else 20;
    const single = (std.unicode.utf8CountCodepoints(k) catch k.len) == 1;
    const symbol = single and k[0] >= 0x80;
    const size: f32 = if (sm) (if (symbol) 10.5 else 10) else (if (symbol) 12.5 else 11);
    const dark = c.theme.dark;
    _ = c.open(.{
        .height = .{ .px = h },
        .width = if (single) .{ .px = h } else .auto,
        .min_width = h,
        .padding = .{ .left = if (single) 0 else if (sm) 4 else 6, .right = if (single) 0 else if (sm) 4 else 6, .bottom = 1 },
        .align_items = .center,
        .justify = .center,
        .radius = if (sm) 4 else 5,
        .background = if (dark) t.surface_hover else t.surface,
        .gradient = if (dark) t.surface else t.background,
        .border = t.border.alpha(if (dark) 0.6 else 0.9),
        // The lip: a hard edge under the cap.
        .shadow = .{ .color = if (dark) Color.black.alpha(0.6) else t.border, .blur = 0, .y = 1 },
    }, null);
    ui.text(c, k, .{ .size = size, .weight = .medium, .color = o.color orelse if (isModifier(k)) t.muted else t.foreground.alpha(0.82) });
    c.end();
}

test "a chord splits into one cap per key" {
    var caps: [max_caps][]const u8 = undefined;
    const Case = struct { in: []const u8, out: []const []const u8 };
    const cases = [_]Case{
        .{ .in = "⌘K", .out = &.{ "⌘", "K" } },
        .{ .in = "⇧⌘P", .out = &.{ "⇧", "⌘", "P" } },
        .{ .in = "Ctrl+Shift+K", .out = &.{ "Ctrl", "Shift", "K" } },
        .{ .in = "Ctrl++", .out = &.{ "Ctrl", "+" } },
        .{ .in = "+", .out = &.{"+"} },
        .{ .in = "Esc", .out = &.{"Esc"} },
        .{ .in = "⌘", .out = &.{"⌘"} },
        .{ .in = "↑↓", .out = &.{"↑↓"} },
    };
    for (cases) |case| {
        const n = splitChord(case.in, &caps);
        try std.testing.expectEqual(case.out.len, n);
        for (case.out, caps[0..n]) |want, got| try std.testing.expectEqualStrings(want, got);
    }
}

test "spelled-out modifiers read as glyphs only where shortcuts use them" {
    try std.testing.expectEqualStrings("⌘", legend("Cmd", true));
    try std.testing.expectEqualStrings("Cmd", legend("Cmd", false));
    try std.testing.expectEqualStrings("←", legend("left", false));
    try std.testing.expectEqualStrings("K", legend("K", true));
}
