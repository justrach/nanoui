//! Fonts an app brings. `ui.registerFont`: a TrueType or OpenType file's bytes,
//! kept by the app, found by family name like an installed font. On macOS and
//! iOS CoreText registers them for the process; where nanoui reads fonts itself,
//! its font database adds them before the system's.
//!
//! `ui.registerFontFace`: a face from any bytes (WOFF and WOFF2 too) under a
//! family name of the app's choosing, with the weights, style, width and
//! characters it is for, as CSS's `@font-face` describes one. Nothing is
//! visible to other programs, and a family can be taken away again. Faces of
//! a family are chosen as CSS's font matching does (`best`), so a family split
//! into files by range works.
const std = @import("std");

const portable = @import("text.zig").portable;
const sfnt = @import("tt/sfnt.zig");

pub var fonts: [64][]const u8 = undefined;
pub var count: usize = 0;

/// Registers the font file `bytes` (kept by the caller: an `@embedFile`).
/// False if it can't be read or too many are registered. Register fonts
/// before the windows that use them.
pub fn register(bytes: []const u8) bool {
    if (count == fonts.len) return false;
    if (!portable and !@import("fonts.zig").registerData(bytes)) return false;
    fonts[count] = bytes;
    count += 1;
    return true;
}

pub fn registered() []const []const u8 {
    return fonts[0..count];
}

/// What `registerFontFace` is told of a face.
pub const FaceOptions = struct {
    /// The name `TextStyle.family` finds it by. Case doesn't matter.
    family: []const u8,
    /// A TrueType, OpenType, WOFF or WOFF2 file: copied, and decoded. Empty
    /// when `local` names an installed font instead.
    bytes: []const u8 = "",
    /// An installed font by its full or PostScript name (CSS's `local()`).
    local: ?[]const u8 = null,
    /// The weights it serves, on CSS's scale: a range on a variable font.
    weight: [2]u16 = .{ 400, 400 },
    italic: bool = false,
    /// The widths it serves, as `font-stretch` percentages.
    stretch: [2]u16 = .{ 100, 100 },
    /// The characters it serves, inclusive ranges; empty is all of them.
    ranges: []const [2]u21 = &.{},
    /// Nothing to draw with yet: the face counts when one is chosen, as CSS has it,
    /// and text goes to the next family until `fillFace` gives it its file.
    pending: bool = false,
    /// Among faces alike in the rest, higher is looked in first. A file can
    /// arrive long after a rule written later: this says which rule it was.
    order: u32 = 0,
};

pub const Face = struct {
    family: []const u8,
    /// The sfnt; empty for a local one.
    bytes: []const u8 = "",
    local: ?[]const u8 = null,
    weight: [2]u16,
    italic: bool,
    stretch: [2]u16,
    ranges: []const [2]u21,
    order: u32 = 0,
    /// Made in this order, per the registry: the later wins among equal orders.
    serial: u64,
    gpa: std.mem.Allocator,
    /// The text system's handle for it, where it has one (a font descriptor).
    native: ?*anyopaque = null,

    pub fn covers(f: *const Face, cp: u21) bool {
        return rangesCover(f.ranges, cp);
    }
};

pub fn rangesCover(ranges: []const [2]u21, cp: u21) bool {
    if (ranges.len == 0) return true;
    for (ranges) |r| if (cp >= r[0] and cp <= r[1]) return true;
    return false;
}

pub const RegisterError = sfnt.Error;

/// The faces brought so far. Touched on the main thread only.
var faces: std.ArrayList(*Face) = .empty;
var faces_gpa: ?std.mem.Allocator = null;
var serial: u64 = 0;
/// Bumped when faces come or go: text systems drop what they shaped.
pub var generation: u64 = 0;

/// Adds a face (`FaceOptions`). The bytes need not outlive the call. `gpa` is
/// used until the family is unregistered.
pub fn registerFace(gpa: std.mem.Allocator, o: FaceOptions) RegisterError!void {
    if (o.family.len == 0) return error.NotAFont;
    const f = try gpa.create(Face);
    errdefer gpa.destroy(f);
    const family = try gpa.dupe(u8, o.family);
    errdefer gpa.free(family);
    const ranges = try gpa.dupe([2]u21, o.ranges);
    errdefer gpa.free(ranges);
    const local = if (o.local) |l| try gpa.dupe(u8, l) else null;
    errdefer if (local) |l| gpa.free(l);
    const bytes: []const u8 = if (o.bytes.len > 0) try sfnt.decode(gpa, o.bytes) else if (local != null or o.pending) "" else return error.NotAFont;
    errdefer if (bytes.len > 0) gpa.free(bytes);
    var native: ?*anyopaque = null;
    if (!portable and bytes.len > 0) {
        native = @import("text_stack_mac.zig").describe(bytes) orelse return error.Unsupported;
    }
    serial += 1;
    f.* = .{
        .family = family,
        .bytes = bytes,
        .local = local,
        .weight = .{ @min(o.weight[0], o.weight[1]), @max(o.weight[0], o.weight[1]) },
        .italic = o.italic,
        .stretch = .{ @min(o.stretch[0], o.stretch[1]), @max(o.stretch[0], o.stretch[1]) },
        .ranges = ranges,
        .order = o.order,
        .serial = serial,
        .gpa = gpa,
        .native = native,
    };
    const list_gpa = faces_gpa orelse gpa;
    faces_gpa = list_gpa;
    faces.append(list_gpa, f) catch |e| {
        release(f);
        return e;
    };
    generation += 1;
}

/// Gives a pending face of `family`, the one registered with `order`, its file or
/// the installed font it is.
pub fn fillFace(family: []const u8, order: u32, bytes: []const u8, local: ?[]const u8) RegisterError!void {
    for (faces.items) |f| {
        if (f.order != order or f.bytes.len > 0 or f.local != null or !std.ascii.eqlIgnoreCase(f.family, family)) continue;
        if (local) |l| {
            f.local = try f.gpa.dupe(u8, l);
        } else {
            const decoded = try sfnt.decode(f.gpa, bytes);
            errdefer f.gpa.free(decoded);
            if (!portable) f.native = @import("text_stack_mac.zig").describe(decoded) orelse return error.Unsupported;
            f.bytes = decoded;
        }
        generation += 1;
        return;
    }
    return error.NotAFont;
}

fn release(f: *Face) void {
    if (!portable) if (f.native) |n| @import("text_stack_mac.zig").forget(n);
    const gpa = f.gpa;
    gpa.free(f.family);
    if (f.bytes.len > 0) gpa.free(f.bytes);
    if (f.local) |l| gpa.free(l);
    gpa.free(f.ranges);
    gpa.destroy(f);
}

/// Takes away the families whose names start with `prefix`.
pub fn unregisterFamilies(prefix: []const u8) void {
    var kept: usize = 0;
    var gone = false;
    for (faces.items) |f| {
        if (std.ascii.startsWithIgnoreCase(f.family, prefix)) {
            release(f);
            gone = true;
        } else {
            faces.items[kept] = f;
            kept += 1;
        }
    }
    faces.items.len = kept;
    if (gone) generation += 1;
    if (kept == 0) if (faces_gpa) |g| {
        faces.deinit(g);
        faces = .empty;
        faces_gpa = null;
    };
}

pub fn hasFamily(name: []const u8) bool {
    for (faces.items) |f| if (std.ascii.eqlIgnoreCase(f.family, name)) return true;
    return false;
}

/// CSS's distance of a face's weights from the one asked for: 400 to 500 look
/// up to 500 first, then down, then up; lighter ones down first; heavier up.
fn weightDistance(have: [2]u16, want: u16) u32 {
    if (want >= have[0] and want <= have[1]) return 0;
    const up: u32 = if (have[0] > want) have[0] - want else 0;
    const down: u32 = if (have[1] < want) want - have[1] else 0;
    if (want >= 400 and want <= 500) {
        if (up > 0 and have[0] <= 500) return up;
        if (down > 0) return 1000 + down;
        return 2000 + up;
    }
    if (want < 400) return if (down > 0) down else 1000 + up;
    return if (up > 0) up else 1000 + down;
}

fn stretchDistance(have: [2]u16, want: u16) u32 {
    if (want >= have[0] and want <= have[1]) return 0;
    const up: u32 = if (have[0] > want) have[0] - want else 0;
    const down: u32 = if (have[1] < want) want - have[1] else 0;
    if (want <= 100) return if (down > 0) down else 1000 + up;
    return if (up > 0) up else 1000 + down;
}

/// How far a face's description is from a style: the lowest is what CSS's font
/// matching takes, width first, then style, then weight.
pub fn score(weight: [2]u16, italic: bool, stretch: [2]u16, want_weight: u16, want_italic: bool, want_stretch: u16) u64 {
    return (@as(u64, stretchDistance(stretch, want_stretch)) << 32) +
        (@as(u64, @intFromBool(italic != want_italic)) << 31) + weightDistance(weight, want_weight);
}

/// The faces of `family` CSS would draw this style in: those with the nearest
/// width, style and weight, whichever file holds the character, latest first.
/// Fills `out` and says how many.
pub fn best(family: []const u8, weight: u16, italic: bool, stretch: u16, out: []*const Face) usize {
    var top: ?*const Face = null;
    var top_score: u64 = std.math.maxInt(u64);
    for (faces.items) |f| {
        if (!std.ascii.eqlIgnoreCase(f.family, family)) continue;
        const s = score(f.weight, f.italic, f.stretch, weight, italic, stretch);
        if (s < top_score) {
            top_score = s;
            top = f;
        }
    }
    const t = top orelse return 0;
    var n: usize = 0;
    var i = faces.items.len;
    while (i > 0 and n < out.len) {
        i -= 1;
        const f = faces.items[i];
        if (!std.ascii.eqlIgnoreCase(f.family, family)) continue;
        if (f.italic != t.italic or !std.mem.eql(u16, &f.weight, &t.weight) or !std.mem.eql(u16, &f.stretch, &t.stretch)) continue;
        // By rule, the later first; faces of one rule by when they came.
        var at = n;
        while (at > 0 and out[at - 1].order < f.order) : (at -= 1) out[at] = out[at - 1];
        out[at] = f;
        n += 1;
    }
    return n;
}

test "a pending face is chosen by its description, and draws once it has a file" {
    const gpa = std.testing.allocator;
    const tf = @import("tt/testfont.zig");
    const bytes = try tf.build(gpa, .{ .family = "Pending" });
    defer gpa.free(bytes);
    defer unregisterFamilies("regpend-");
    try registerFace(gpa, .{ .family = "regpend-a", .bytes = bytes, .weight = .{ 700, 700 }, .order = 0 });
    try registerFace(gpa, .{ .family = "regpend-a", .pending = true, .weight = .{ 400, 400 }, .order = 1 });
    var out: [8]*const Face = undefined;
    try std.testing.expectEqual(@as(usize, 1), best("regpend-a", 400, false, 100, &out));
    try std.testing.expectEqual(@as(usize, 0), out[0].bytes.len);
    try fillFace("regpend-a", 1, bytes, null);
    _ = best("regpend-a", 400, false, 100, &out);
    try std.testing.expect(out[0].bytes.len > 0);
    try std.testing.expectError(error.NotAFont, fillFace("regpend-a", 1, bytes, null));
    try std.testing.expectError(error.NotAFont, fillFace("regpend-b", 0, bytes, null));
}

test "css's font matching picks the nearest weights and keeps a split family together" {
    const gpa = std.testing.allocator;
    const tf = @import("tt/testfont.zig");
    const bytes = try tf.build(gpa, .{ .family = "Reg Test" });
    defer gpa.free(bytes);
    defer unregisterFamilies("regtest-");
    try registerFace(gpa, .{ .family = "regtest-a", .bytes = bytes, .weight = .{ 400, 400 }, .ranges = &.{.{ 0, 0x7f }} });
    try registerFace(gpa, .{ .family = "regtest-a", .bytes = bytes, .weight = .{ 400, 400 }, .ranges = &.{.{ 0x400, 0x4ff }} });
    try registerFace(gpa, .{ .family = "regtest-a", .bytes = bytes, .weight = .{ 700, 700 } });
    try registerFace(gpa, .{ .family = "regtest-a", .bytes = bytes, .weight = .{ 300, 300 }, .italic = true });
    var out: [8]*const Face = undefined;
    // Two files of 400: the later first.
    const n = best("REGTEST-A", 400, false, 100, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expect(out[0].covers(0x410) and !out[0].covers('a'));
    try std.testing.expect(out[1].covers('a'));
    try std.testing.expectEqual(@as(u16, 700), blk: {
        _ = best("regtest-a", 600, false, 100, &out);
        break :blk out[0].weight[0];
    });
    // 500 looks down to 400 before up to 700; style outranks weight.
    _ = best("regtest-a", 500, false, 100, &out);
    try std.testing.expectEqual(@as(u16, 400), out[0].weight[0]);
    _ = best("regtest-a", 900, true, 100, &out);
    try std.testing.expect(out[0].italic);
    try std.testing.expectEqual(@as(usize, 0), best("regtest-none", 400, false, 100, &out));
    // Variable: a range holds every weight in it.
    try std.testing.expectEqual(@as(u32, 0), weightDistance(.{ 100, 900 }, 450));
}
