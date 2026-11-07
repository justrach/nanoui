//! `font-family` to the list text is drawn from: generics to what Chromium uses on
//! this system, names a sheet's `@font-face` declares to the page's own fonts, and
//! the standard font last, where Chromium ends up when nothing else is found.
//!
//! Each generic was checked against Chromium's own pixels on the Mac: its headless
//! `monospace` is Courier (a full Chrome's preference can differ), and it does not
//! know `-apple-system`, `ui-monospace`, `ui-serif`, `ui-sans-serif` or `ui-rounded`,
//! so those are skipped like any family that isn't installed.
const std = @import("std");
const builtin = @import("builtin");
const sheet = @import("sheet.zig");
const tk = @import("tokenizer.zig");

const apple = builtin.os.tag == .macos or builtin.os.tag == .ios;
const android = builtin.abi.isAndroid();
const windows = builtin.os.tag == .windows;

/// What generics mean here: each may be a list.
const Generics = struct { serif: []const u8, sans: []const u8, mono: []const u8, cursive: []const u8, fantasy: []const u8 };
const generics: Generics = if (apple)
    .{ .serif = "Times", .sans = "Helvetica", .mono = "Courier", .cursive = "Apple Chancery", .fantasy = "Papyrus" }
else if (windows)
    .{ .serif = "Times New Roman", .sans = "Arial", .mono = "Consolas", .cursive = "Comic Sans MS", .fantasy = "Impact" }
else if (android)
    .{ .serif = "Noto Serif,Droid Serif", .sans = "Roboto", .mono = "Droid Sans Mono,Cutive Mono", .cursive = "Dancing Script,Roboto", .fantasy = "Roboto" }
else
    .{ .serif = "Liberation Serif,Times New Roman,DejaVu Serif,Noto Serif", .sans = "Liberation Sans,Arial,DejaVu Sans,Noto Sans", .mono = "Liberation Mono,Courier New,DejaVu Sans Mono,Noto Sans Mono", .cursive = "DejaVu Serif,Liberation Serif", .fantasy = "DejaVu Sans,Liberation Sans" };

/// A page with no `font-family` at all.
pub const standard = generics.serif;

/// Names that fontconfig answers with another family on Linux.
fn metricAlias(name: []const u8) ?[]const u8 {
    if (apple or windows or android) return null;
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(name, "Arial") or eq(name, "Helvetica")) return "Liberation Sans";
    if (eq(name, "Times New Roman") or eq(name, "Times")) return "Liberation Serif";
    if (eq(name, "Courier New") or eq(name, "Courier")) return "Liberation Mono";
    return null;
}

/// What a name is in a list: a generic or the system font; empty for one that
/// is skipped; null for an ordinary family name.
fn meaning(name: []const u8) ?[]const u8 {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(name, "serif")) return generics.serif;
    if (eq(name, "sans-serif")) return generics.sans;
    if (eq(name, "monospace")) return generics.mono;
    if (eq(name, "cursive")) return generics.cursive;
    if (eq(name, "fantasy")) return generics.fantasy;
    if (eq(name, "system-ui") or eq(name, "BlinkMacSystemFont")) return "system-ui";
    if (eq(name, "-apple-system") or eq(name, "ui-monospace") or eq(name, "ui-serif") or eq(name, "ui-sans-serif") or eq(name, "ui-rounded")) return "";
    // Apple's private families are not for pages.
    if (name.len > 0 and name[0] == '.') return "";
    return null;
}

/// What a font's real measures give the units that depend on them.
pub const Units = struct { ex: f32, ch: f32, cap: f32 };

/// What the engine knows of fonts while computing styles.
pub const Names = struct {
    /// What a family list came to, by how it was written. Values live in the
    /// style generation's arena, and go with it.
    interned: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The families the sheets declare, lowercased.
    declared: std.StringHashMapUnmanaged(void) = .empty,
    /// Put before a declared name: a font of this page, not another's.
    scope: []const u8 = "",
    /// Real metrics of a font, when there's a text system to ask (null: tests).
    ctx: ?*anyopaque = null,
    probe: ?*const fn (ctx: *anyopaque, family: []const u8, size: f32, weight: u16, italic: bool) ?Units = null,

    pub fn deinit(n: *Names, gpa: std.mem.Allocator) void {
        n.interned.deinit(gpa);
        var it = n.declared.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        n.declared.deinit(gpa);
    }

    /// Reads the families the sheets' `@font-face` rules declare. True when
    /// that's different from what was known.
    pub fn declare(n: *Names, gpa: std.mem.Allocator, sheets: []const *const sheet.Sheet) bool {
        var fresh: std.StringHashMapUnmanaged(void) = .empty;
        for (sheets) |s| for (s.font_faces) |f| {
            const raw = faceFamily(f.decls) orelse continue;
            var buf: [256]u8 = undefined;
            if (raw.len > buf.len) continue;
            const low = std.ascii.lowerString(&buf, raw);
            if (fresh.contains(low)) continue;
            const key = gpa.dupe(u8, low) catch continue;
            fresh.put(gpa, key, {}) catch gpa.free(key);
        };
        var same = fresh.count() == n.declared.count();
        if (same) {
            var it = fresh.keyIterator();
            while (it.next()) |k| if (!n.declared.contains(k.*)) {
                same = false;
            };
        }
        const gone = if (same) &fresh else &n.declared;
        var it = gone.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        gone.deinit(gpa);
        if (!same) {
            n.declared = fresh;
            n.interned.clearRetainingCapacity();
        }
        return !same;
    }

    fn isDeclared(n: *const Names, name: []const u8) bool {
        var buf: [256]u8 = undefined;
        if (name.len > buf.len) return false;
        return n.declared.contains(std.ascii.lowerString(&buf, name));
    }
};

/// The name an `@font-face` rule gives its family, or null.
pub fn faceFamily(d: *const sheet.Declarations) ?[]const u8 {
    for (d.items) |x| if (std.ascii.eqlIgnoreCase(x.name, "font-family")) {
        return oneName(x.value);
    };
    return null;
}


/// A family name: a string or one ident; the parser made a string of several words.
fn oneName(t: []const tk.Token) ?[]const u8 {
    var i: usize = 0;
    while (i < t.len and t[i].kind == .whitespace) i += 1;
    if (i >= t.len) return null;
    if (t[i].kind == .string) return t[i].text;
    if (t[i].kind != .ident) return null;
    for (t[i + 1 ..]) |k| if (k.kind != .whitespace) return null;
    return t[i].text;
}

/// Appends a list of family names read from `t` to `w`, resolved. False when
/// `t` isn't a list.
fn write(w: *std.ArrayList(u8), a: std.mem.Allocator, n: ?*const Names, t: []const tk.Token) std.mem.Allocator.Error!bool {
    var i: usize = 0;
    var ended = false;
    var any = false;
    while (i <= t.len) {
        var name: std.ArrayList(u8) = .empty;
        var parts: usize = 0;
        while (i < t.len and t[i].kind != .comma) : (i += 1) {
            const k = t[i];
            if (k.kind == .whitespace) continue;
            if (k.kind != .ident and k.kind != .string) return false;
            if (parts > 0) try name.append(a, ' ');
            // A comma in a quoted name would look like two names.
            for (k.text) |c| try name.append(a, if (c == ',') ' ' else c);
            parts += 1;
        }
        i += 1;
        if (parts == 0) return false;
        any = true;
        const resolved = meaning(name.items);
        var text: []const u8 = resolved orelse name.items;
        var scoped = false;
        if (resolved == null) {
            if (n) |names| if (names.isDeclared(name.items)) {
                scoped = true;
            };
            if (!scoped) if (metricAlias(name.items)) |alias| {
                text = alias;
            };
        }
        if (resolved != null and text.len > 0 and !std.mem.eql(u8, text, "system-ui")) ended = true;
        if (text.len == 0) continue;
        if (w.items.len > 0) try w.append(a, ',');
        if (scoped) try w.appendSlice(a, n.?.scope);
        try w.appendSlice(a, text);
    }
    if (!any) return false;
    // A generic always finds something; without one, the standard font is the end.
    if (!ended) {
        if (w.items.len > 0) try w.append(a, ',');
        try w.appendSlice(a, standard);
    }
    return true;
}

/// The list `t` means, in a string as long-lived as the style generation: the
/// same words give the same string. Null when `t` isn't a list.
pub fn resolve(a: std.mem.Allocator, n: ?*Names, gpa: std.mem.Allocator, t: []const tk.Token) std.mem.Allocator.Error!?[]const u8 {
    var key_buf: [512]u8 = undefined;
    var key_len: usize = 0;
    var keyed = n != null;
    for (t) |k| {
        if (k.text.len + 2 > key_buf.len - key_len) {
            keyed = false;
            break;
        }
        @memcpy(key_buf[key_len..][0..k.text.len], k.text);
        key_len += k.text.len;
        key_buf[key_len] = @intFromEnum(k.kind);
        key_len += 1;
    }
    if (keyed) if (n.?.interned.get(key_buf[0..key_len])) |v| return v;
    var w: std.ArrayList(u8) = .empty;
    if (!try write(&w, a, n, t)) return null;
    if (keyed) {
        const key = try a.dupe(u8, key_buf[0..key_len]);
        try n.?.interned.put(gpa, key, w.items);
    }
    return w.items;
}

/// `list` as a page should see it: without the page's own mark on declared names.
pub fn shown(a: std.mem.Allocator, list: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, list, '@') == null) return list;
    var w: std.ArrayList(u8) = .empty;
    var names = std.mem.splitScalar(u8, list, ',');
    while (names.next()) |name| {
        if (w.items.len > 0) try w.appendSlice(a, ", ");
        const cut = if (name.len > 0 and name[0] == '@') (std.mem.indexOfScalar(u8, name, '/') orelse 0) + 1 else 0;
        try w.appendSlice(a, name[cut..]);
    }
    return w.items;
}

fn tokens(a: std.mem.Allocator, text: []const u8) ![]const tk.Token {
    var t: tk.Tokenizer = .{ .arena = a, .src = text };
    var out: std.ArrayList(tk.Token) = .empty;
    while (true) {
        const k = try t.next();
        if (k.kind == .eof) return out.items;
        try out.append(a, k);
    }
}

test "generics, unknown keywords and the standard font at the end" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gen = struct {
        fn of(al: std.mem.Allocator, text: []const u8) ![]const u8 {
            return (try resolve(al, null, al, try tokens(al, text))).?;
        }
    }.of;
    const expect = std.testing.expectEqualStrings;
    try expect(generics.mono, try gen(a, "monospace"));
    try expect("Foo Bar," ++ generics.sans, try gen(a, "\"Foo Bar\", sans-serif"));
    try expect("Foo Bar," ++ standard, try gen(a, "Foo   Bar"));
    try expect(standard, try gen(a, "-apple-system"));
    try expect("system-ui," ++ standard, try gen(a, "BlinkMacSystemFont"));
    try expect(generics.serif, try gen(a, "ui-monospace, '.AppleSystemUIFont', serif"));
    try std.testing.expect((try resolve(a, null, a, try tokens(a, "12px"))) == null);
}

test "a declared family is the page's own, and pages don't see the mark" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var n: Names = .{ .scope = "@7/" };
    defer n.deinit(gpa);
    try n.declared.put(gpa, try gpa.dupe(u8, "inter"), {});
    const list = (try resolve(a, &n, gpa, try tokens(a, "Inter, Arial")));
    try std.testing.expect(std.mem.startsWith(u8, list.?, "@7/Inter,"));
    const whole = try std.fmt.allocPrint(a, "Inter,{s},{s}", .{ metricAlias("Arial") orelse "Arial", standard });
    const want = try std.mem.replaceOwned(u8, a, whole, ",", ", ");
    try std.testing.expectEqualStrings(want, try shown(a, list.?));
    // The same words, the same string.
    try std.testing.expectEqual(list.?.ptr, (try resolve(a, &n, gpa, try tokens(a, "Inter, Arial"))).?.ptr);
}
