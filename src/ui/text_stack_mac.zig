//! The fonts of a text that names families (`TextStyle.family`), on CoreText: each
//! name to its face at this style (a font the app brought, else an installed
//! family, chosen as Chromium chooses on the Mac), and a text cut where its
//! characters' fonts change. A character no family has is left to CoreText's
//! own cascade.
const std = @import("std");
const cf = @import("cf.zig");
const objc = @import("../objc.zig");
const fonts = @import("fonts.zig");
const registry = @import("font_registry.zig");
const types = @import("types.zig");
const utf8 = @import("utf8.zig");

extern "c" fn CFDataCreate(alloc: ?*anyopaque, bytes: [*]const u8, len: cf.CFIndex) ?*anyopaque;
extern "c" fn CTFontManagerCreateFontDescriptorFromData(data: *anyopaque) ?*anyopaque;
extern "c" fn CTFontCreateWithFontDescriptor(desc: *anyopaque, size: f64, matrix: ?*const Transform) ?cf.CTFontRef;
extern "c" fn CTFontCreateWithName(name: cf.CFStringRef, size: f64, matrix: ?*const Transform) ?cf.CTFontRef;
extern "c" fn CTFontCreateCopyWithAttributes(font: cf.CTFontRef, size: f64, matrix: ?*const Transform, attrs: ?*anyopaque) ?cf.CTFontRef;
extern "c" fn CTFontCopyFontDescriptor(font: cf.CTFontRef) *anyopaque;
extern "c" fn CTFontCopyPostScriptName(font: cf.CTFontRef) cf.CFStringRef;
extern "c" fn CTFontCopyFullName(font: cf.CTFontRef) cf.CFStringRef;
extern "c" fn CTFontCopyFamilyName(font: cf.CTFontRef) cf.CFStringRef;
extern "c" fn CTFontCopyVariationAxes(font: cf.CTFontRef) ?*anyopaque;
extern "c" fn CTFontGetSymbolicTraits(font: cf.CTFontRef) u32;
extern "c" fn CTFontGetSize(font: cf.CTFontRef) f64;
extern "c" fn CTFontGetGlyphsForCharacters(font: cf.CTFontRef, chars: [*]const u16, glyphs: [*]u16, n: cf.CFIndex) bool;
extern "c" fn CTFontDescriptorCreateWithAttributes(attrs: cf.CFDictionaryRef) ?*anyopaque;
extern "c" fn CTFontDescriptorCreateMatchingFontDescriptors(desc: *anyopaque, mandatory: ?*anyopaque) ?*anyopaque;
extern "c" fn CTFontDescriptorCopyAttribute(desc: *anyopaque, name: cf.CFStringRef) ?*anyopaque;
extern "c" fn CTFontDescriptorCreateCopyWithVariation(desc: *anyopaque, id: *anyopaque, value: f64) ?*anyopaque;
extern "c" fn CFArrayGetCount(arr: *anyopaque) cf.CFIndex;
extern "c" fn CFArrayGetValueAtIndex(arr: *anyopaque, i: cf.CFIndex) *anyopaque;
extern "c" fn CFDictionaryGetValue(dict: *anyopaque, key: *const anyopaque) ?*anyopaque;
extern "c" fn CFNumberCreate(alloc: ?*anyopaque, kind: cf.CFIndex, value: *const anyopaque) ?*anyopaque;
extern "c" fn CFStringCompare(a: cf.CFStringRef, b: cf.CFStringRef, options: u64) cf.CFIndex;
extern "c" fn CFAttributedStringCreateMutable(alloc: ?*anyopaque, max: cf.CFIndex) ?cf.CFAttributedStringRef;
extern "c" fn CFAttributedStringReplaceString(s: cf.CFAttributedStringRef, range: cf.CFRange, with: cf.CFStringRef) void;
extern "c" fn CFAttributedStringSetAttribute(s: cf.CFAttributedStringRef, range: cf.CFRange, name: cf.CFStringRef, value: *const anyopaque) void;
extern "c" fn CFAttributedStringBeginEditing(s: cf.CFAttributedStringRef) void;
extern "c" fn CFAttributedStringEndEditing(s: cf.CFAttributedStringRef) void;
extern "c" const kCTFontFamilyNameAttribute: cf.CFStringRef;
extern "c" const kCTFontTraitsAttribute: cf.CFStringRef;
extern "c" const kCTFontWeightTrait: cf.CFStringRef;
extern "c" const kCTFontWidthTrait: cf.CFStringRef;
extern "c" const kCTFontSymbolicTrait: cf.CFStringRef;
extern "c" const kCTFontVariationAxisIdentifierKey: cf.CFStringRef;
extern "c" const kCTFontVariationAxisMinimumValueKey: cf.CFStringRef;
extern "c" const kCTFontVariationAxisMaximumValueKey: cf.CFStringRef;
extern "c" const kCTLigatureAttributeName: cf.CFStringRef;

const Transform = extern struct { a: f64, b: f64, c: f64, d: f64, tx: f64, ty: f64 };
/// Chromium's synthesized italics: a skew of a quarter.
const skew: Transform = .{ .a = 1, .b = 0, .c = 0.25, .d = 1, .tx = 0, .ty = 0 };
const italic_trait: u32 = 1;
const number_f64: cf.CFIndex = 6;
const number_i32: cf.CFIndex = 3;
const number_u32_as_i64: cf.CFIndex = 4;
/// `kCFCompareCaseInsensitive`.
const case_insensitive: u64 = 1;

fn axis(s: *const [4]u8) i32 {
    return std.mem.readInt(i32, s, .big);
}

/// A font descriptor of an sfnt's bytes, null if CoreText can't read it.
pub fn describe(bytes: []const u8) ?*anyopaque {
    const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return null;
    defer cf.CFRelease(data);
    return CTFontManagerCreateFontDescriptorFromData(data);
}

pub fn forget(native: *anyopaque) void {
    cf.CFRelease(native);
}

pub const Entry = struct {
    ref: cf.CTFontRef,
    /// The characters it serves, empty for all (owned).
    ranges: []const [2]u21 = &.{},
    /// Points of outline added, for a bold it lacks.
    stroke: f32 = 0,
    /// A font the app brought: its own shaping rules (an icon font's
    /// ligatures), so CoreText always shapes with it.
    brought: bool = false,
};

const none: u8 = 0xff;

pub const Stack = struct {
    entries: []Entry,
    /// The first entry with the space: the one whose metrics a line takes.
    primary: u8 = 0,
    /// Printable ASCII is all the primary's own: the fast path may shape it.
    fast: bool = false,
    ascii: [128]u8 = @splat(0xfe),
    others: std.AutoHashMapUnmanaged(u21, u8) = .empty,

    pub fn destroy(st: *Stack, gpa: std.mem.Allocator) void {
        for (st.entries) |e| {
            cf.CFRelease(e.ref);
            gpa.free(e.ranges);
        }
        gpa.free(st.entries);
        st.others.deinit(gpa);
        gpa.destroy(st);
    }

    fn find(st: *const Stack, cp: u21) u8 {
        var units: [2]u16 = undefined;
        const n: cf.CFIndex = if (cp >= 0x10000) 2 else 1;
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            units = .{ @intCast(0xd800 + (v >> 10)), @intCast(0xdc00 + (v & 0x3ff)) };
        } else units[0] = @intCast(cp);
        var glyphs: [2]u16 = undefined;
        for (st.entries, 0..) |e, i| {
            if (!registry.rangesCover(e.ranges, cp)) continue;
            if (CTFontGetGlyphsForCharacters(e.ref, &units, &glyphs, n) and glyphs[0] != 0) return @intCast(i);
        }
        return none;
    }

    /// The entry that draws `cp`; `none` when none has it.
    pub fn pick(st: *Stack, gpa: std.mem.Allocator, cp: u21) u8 {
        if (cp < 128) {
            if (st.ascii[cp] == 0xfe) st.ascii[cp] = st.find(cp);
            return st.ascii[cp];
        }
        if (st.others.get(cp)) |v| return v;
        const v = st.find(cp);
        st.others.put(gpa, cp, v) catch {};
        return v;
    }

    pub fn strokeOf(st: *const Stack, run_font: *anyopaque) f32 {
        for (st.entries) |e| {
            if (e.stroke == 0) continue;
            if (@as(*anyopaque, e.ref) == run_font or cfEqual(e.ref, run_font)) return e.stroke;
        }
        return 0;
    }
};

extern "c" fn CFEqual(a: *anyopaque, b: *anyopaque) bool;
fn cfEqual(a: *anyopaque, b: *anyopaque) bool {
    return CFEqual(a, b);
}

/// How much Skia thickens a bold it makes up at this size, in points: what
/// Chromium draws.
fn strokeFor(size: f32) f32 {
    const k: f32 = if (size <= 9) 1.0 / 24.0 else if (size >= 36) 1.0 / 32.0 else 1.0 / 24.0 + (size - 9) / 27 * (1.0 / 32.0 - 1.0 / 24.0);
    return size * k;
}

/// AppKit's numbering of weights, which Chromium chooses faces by.
fn appKitWeight(w: u16) i32 {
    const table = [_]i32{ 2, 3, 4, 5, 6, 8, 9, 10, 12 };
    return table[@min(@max(w, 100) / 100 - 1, 8)];
}

fn cssWeightOf(trait: f64) u16 {
    const steps = [_]f64{ -0.8, -0.6, -0.4, 0, 0.23, 0.3, 0.4, 0.56, 0.62 };
    var best: usize = 0;
    var d: f64 = 9;
    for (steps, 0..) |v, i| if (@abs(trait - v) < d) {
        d = @abs(trait - v);
        best = i;
    };
    return @intCast((best + 1) * 100);
}

fn numberIn(dict: *anyopaque, key: cf.CFStringRef) f64 {
    const n = CFDictionaryGetValue(dict, key) orelse return 0;
    var v: f64 = 0;
    _ = cf.CFNumberGetValue(n, number_f64, &v);
    return v;
}

const Traits = struct { weight: u16, width: f64, italic: bool };

fn traitsOf(desc: *anyopaque) Traits {
    const t = CTFontDescriptorCopyAttribute(desc, kCTFontTraitsAttribute) orelse return .{ .weight = 400, .width = 0, .italic = false };
    defer cf.CFRelease(t);
    var sym: i64 = 0;
    if (CFDictionaryGetValue(t, kCTFontSymbolicTrait)) |n| _ = cf.CFNumberGetValue(n, number_u32_as_i64, &sym);
    return .{ .weight = cssWeightOf(numberIn(t, kCTFontWeightTrait)), .width = numberIn(t, kCTFontWidthTrait), .italic = sym & italic_trait != 0 };
}

/// An installed family's faces: a retained array of descriptors, null when
/// nothing is installed under the name.
pub fn familyFaces(name: []const u8) ?*anyopaque {
    const family = cf.string(name);
    defer cf.CFRelease(family);
    const keys = [_]?*const anyopaque{kCTFontFamilyNameAttribute};
    const vals = [_]?*const anyopaque{family};
    const attrs = cf.CFDictionaryCreate(null, &keys, &vals, 1, &cf.kCFTypeDictionaryKeyCallBacks, &cf.kCFTypeDictionaryValueCallBacks) orelse return null;
    defer cf.CFRelease(attrs);
    const desc = CTFontDescriptorCreateWithAttributes(attrs) orelse return null;
    defer cf.CFRelease(desc);
    const all = CTFontDescriptorCreateMatchingFontDescriptors(desc, null) orelse return null;
    // Only the family asked for, not what CoreText thinks is like it.
    if (CFArrayGetCount(all) > 0) {
        const got = CTFontDescriptorCopyAttribute(CFArrayGetValueAtIndex(all, 0), kCTFontFamilyNameAttribute);
        defer if (got) |g| cf.CFRelease(g);
        if (got != null and CFStringCompare(@ptrCast(got.?), family, case_insensitive) == 0) return all;
    }
    cf.CFRelease(all);
    return null;
}

/// As Chromium's `BetterChoice`: style, then width, then the nearest weight,
/// the one further from medium when two are as near.
fn pickFace(all: *anyopaque, weight: u16, italic: bool, stretch: u16) ?*anyopaque {
    const want = appKitWeight(weight);
    const narrow = stretch < 100;
    const wide = stretch > 100;
    var best: ?*anyopaque = null;
    var best_score: i64 = std.math.maxInt(i64);
    var i: cf.CFIndex = 0;
    const n = CFArrayGetCount(all);
    while (i < n) : (i += 1) {
        const d = CFArrayGetValueAtIndex(all, i);
        const t = traitsOf(d);
        const w = appKitWeight(t.weight);
        const has_narrow = t.width < -0.05;
        const has_wide = t.width > 0.05;
        var score: i64 = 0;
        if (t.italic != italic) score += 1 << 40;
        if (has_narrow != narrow) score += 1 << 32;
        if (has_wide != wide) score += 1 << 32;
        score += @as(i64, @abs(w - want)) << 8;
        // Further from medium wins a tie.
        score += 16 - @as(i64, @abs(w - 6));
        if (score < best_score) {
            best_score = score;
            best = d;
        }
    }
    return best;
}

fn sameName(a: cf.CFStringRef, b: []const u8) bool {
    const s = cf.string(b);
    defer cf.CFRelease(s);
    return CFStringCompare(a, s, case_insensitive) == 0;
}

/// An installed font by its full or PostScript name.
pub fn byName(name: []const u8, size: f64) ?cf.CTFontRef {
    const s = cf.string(name);
    defer cf.CFRelease(s);
    const f = CTFontCreateWithName(s, size, null) orelse return null;
    const ps = CTFontCopyPostScriptName(f);
    defer cf.CFRelease(ps);
    const full = CTFontCopyFullName(f);
    defer cf.CFRelease(full);
    if (CFStringCompare(ps, s, case_insensitive) == 0 or CFStringCompare(full, s, case_insensitive) == 0) return f;
    cf.CFRelease(f);
    return null;
}

/// `base`, released, with variations set where it has those axes: its weight
/// and width clamped to the face's, and its optical size following the text's,
/// as CSS's `font-optical-sizing: auto`.
fn varied(base: cf.CTFontRef, size: f64, weight: f64, stretch: f64) cf.CTFontRef {
    const axes = CTFontCopyVariationAxes(base) orelse return base;
    defer cf.CFRelease(axes);
    var desc: *anyopaque = CTFontCopyFontDescriptor(base);
    defer cf.CFRelease(desc);
    var changed = false;
    var i: cf.CFIndex = 0;
    const n = CFArrayGetCount(axes);
    while (i < n) : (i += 1) {
        const ax = CFArrayGetValueAtIndex(axes, i);
        const id_num = CFDictionaryGetValue(ax, kCTFontVariationAxisIdentifierKey) orelse continue;
        var id: i64 = 0;
        _ = cf.CFNumberGetValue(id_num, number_u32_as_i64, &id);
        const value: f64 = if (id == axis("wght")) weight else if (id == axis("wdth")) stretch else if (id == axis("opsz")) size else continue;
        const lo = numberIn(ax, kCTFontVariationAxisMinimumValueKey);
        const hi = numberIn(ax, kCTFontVariationAxisMaximumValueKey);
        const next = CTFontDescriptorCreateCopyWithVariation(desc, id_num, std.math.clamp(value, lo, @max(lo, hi))) orelse continue;
        cf.CFRelease(desc);
        desc = next;
        changed = true;
    }
    if (!changed) return base;
    const made = CTFontCreateWithFontDescriptor(desc, size, null) orelse return base;
    cf.CFRelease(base);
    return made;
}

fn slanted(base: cf.CTFontRef, size: f64) cf.CTFontRef {
    const made = CTFontCreateCopyWithAttributes(base, size, &skew, null) orelse return base;
    cf.CFRelease(base);
    return made;
}

/// The fonts of a family list, at a style. Null when not one of them exists.
pub fn build(gpa: std.mem.Allocator, list: []const u8, style: types.TextStyle, zoom: f32, installed: anytype) ?*Stack {
    const size: f64 = style.size * zoom;
    const weight = style.weightValue();
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(gpa);
    var names = std.mem.splitScalar(u8, list, ',');
    while (names.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0 or entries.items.len >= 200) continue;
        var chosen: [64]*const registry.Face = undefined;
        const n = registry.best(name, weight, style.italic, style.stretch, &chosen);
        if (n > 0) {
            for (chosen[0..n]) |face| {
                const e = brought(gpa, face, style, size, weight) orelse continue;
                entries.append(gpa, e) catch cf.CFRelease(e.ref);
            }
            continue;
        }
        const ref = system(name, style, zoom) orelse named(name, style, size, weight, installed) orelse continue;
        entries.append(gpa, ref) catch cf.CFRelease(ref.ref);
    }
    if (entries.items.len == 0) return null;
    if (style.tabular) for (entries.items) |*e| {
        e.ref = fonts.tabular(e.ref);
    };
    const st = gpa.create(Stack) catch return null;
    const owned = entries.toOwnedSlice(gpa) catch {
        gpa.destroy(st);
        return null;
    };
    st.* = .{ .entries = owned };
    for (owned, 0..) |e, i| if (registry.rangesCover(e.ranges, ' ') and i < none) {
        st.primary = @intCast(i);
        break;
    };
    const p = owned[st.primary];
    st.fast = !p.brought and p.stroke == 0 and p.ranges.len == 0;
    return st;
}

fn brought(gpa: std.mem.Allocator, face: *const registry.Face, style: types.TextStyle, size: f64, weight: u16) ?Entry {
    var ref: cf.CTFontRef = undefined;
    if (face.native) |d| {
        ref = CTFontCreateWithFontDescriptor(d, size, null) orelse return null;
        ref = varied(ref, size, @floatFromInt(std.math.clamp(weight, face.weight[0], face.weight[1])), @floatFromInt(std.math.clamp(style.stretch, face.stretch[0], face.stretch[1])));
    } else {
        ref = byName(face.local orelse return null, size) orelse return null;
    }
    if (style.italic and !face.italic and CTFontGetSymbolicTraits(ref) & italic_trait == 0) ref = slanted(ref, size);
    const ranges = gpa.dupe([2]u21, face.ranges) catch {
        cf.CFRelease(ref);
        return null;
    };
    const bold = weight >= 600 and face.weight[1] < 600;
    return .{ .ref = ref, .ranges = ranges, .stroke = if (bold) strokeFor(@floatCast(size)) else 0, .brought = face.native != null };
}

/// The names that mean the system's own fonts.
fn system(name: []const u8, style: types.TextStyle, zoom: f32) ?Entry {
    const eq = std.ascii.eqlIgnoreCase;
    const mono = eq(name, "ui-monospace");
    const serif = eq(name, "ui-serif");
    const round = eq(name, "ui-rounded");
    if (!mono and !serif and !round and !eq(name, "system-ui")) return null;
    var ref = fonts.create(null, style.size * zoom, types.Weight.of(style.weightValue()), style.italic, mono);
    if (serif) ref = fonts.serif(ref);
    if (round) ref = fonts.rounded(ref);
    return .{ .ref = ref };
}

fn named(name: []const u8, style: types.TextStyle, size: f64, weight: u16, installed: anytype) ?Entry {
    var ref: cf.CTFontRef = undefined;
    var has_weight: u16 = weight;
    var has_italic = false;
    if (installed.facesOf(name)) |all| {
        const d = pickFace(all, weight, style.italic, style.stretch) orelse return null;
        const t = traitsOf(d);
        has_weight = t.weight;
        has_italic = t.italic;
        ref = CTFontCreateWithFontDescriptor(d, size, null) orelse return null;
    } else {
        ref = byName(name, size) orelse return null;
        has_italic = CTFontGetSymbolicTraits(ref) & italic_trait != 0;
        const own = CTFontCopyFontDescriptor(ref);
        defer cf.CFRelease(own);
        has_weight = traitsOf(own).weight;
    }
    if (style.italic and !has_italic) ref = slanted(ref, size);
    return .{ .ref = ref, .stroke = if (appKitWeight(weight) >= 7 and appKitWeight(has_weight) < 7) strokeFor(@floatCast(size)) else 0 };
}

fn joins(cp: u21) bool {
    return (cp >= 0x300 and cp <= 0x36f) or cp == 0x200c or cp == 0x200d or (cp >= 0xfe00 and cp <= 0xfe0f) or (cp >= 0x1f3fb and cp <= 0x1f3ff) or (cp >= 0xe0100 and cp <= 0xe01ef);
}

/// Puts each character of `s`'s bytes [from, to) in the font of `st` that has
/// it, in `m`, whose text is `s`.
pub fn applyRuns(gpa: std.mem.Allocator, m: cf.CFAttributedStringRef, st: *Stack, s: []const u8, from: usize, to: usize) void {
    var i = from;
    var unit: cf.CFIndex = cf.utf16Offset(s, from);
    var run_start = unit;
    var cur: u8 = none;
    while (i < to) {
        const want = utf8.seqLen(s[i]);
        const n = @min(want, s.len - i);
        const cp: u21 = if (n == want) std.unicode.utf8Decode(s[i .. i + n]) catch 0xfffd else 0xfffd;
        var e = st.pick(gpa, cp);
        if (e == none or joins(cp)) e = if (cur != none) cur else st.primary;
        if (cur != e) {
            if (cur != none and unit > run_start) set(m, st, cur, run_start, unit);
            cur = e;
            run_start = unit;
        }
        unit += if (n == 4) 2 else 1;
        i += n;
    }
    if (cur != none and unit > run_start) set(m, st, cur, run_start, unit);
}

fn set(m: cf.CFAttributedStringRef, st: *const Stack, e: u8, a: cf.CFIndex, b: cf.CFIndex) void {
    CFAttributedStringSetAttribute(m, .{ .location = a, .length = b - a }, cf.kCTFontAttributeName, st.entries[e].ref);
}

/// `s` as an attributed string in a style's fonts; release with CFRelease.
pub fn attributed(gpa: std.mem.Allocator, st: *Stack, s: []const u8, ligatures: bool) cf.CFAttributedStringRef {
    if (st.entries.len == 1 and st.entries[0].ranges.len == 0 and ligatures) return cf.attributed(s, st.entries[0].ref);
    const m = CFAttributedStringCreateMutable(null, 0) orelse return cf.attributed(s, st.entries[st.primary].ref);
    const str = cf.string(s);
    defer cf.CFRelease(str);
    CFAttributedStringBeginEditing(m);
    CFAttributedStringReplaceString(m, .{ .location = 0, .length = 0 }, str);
    const total = cf.CFStringGetLength(str);
    CFAttributedStringSetAttribute(m, .{ .location = 0, .length = total }, cf.kCTFontAttributeName, st.entries[st.primary].ref);
    CFAttributedStringSetAttribute(m, .{ .location = 0, .length = total }, cf.kCTForegroundColorFromContextAttributeName, cf.kCFBooleanTrue);
    applyRuns(gpa, m, st, s, 0, s.len);
    if (!ligatures) noLigatures(m, total);
    CFAttributedStringEndEditing(m);
    return m;
}

/// Only the ligatures a script can't do without (`kCTLigatureAttributeName` 0).
fn noLigatures(m: cf.CFAttributedStringRef, total: cf.CFIndex) void {
    const zero: i32 = 0;
    const num = CFNumberCreate(null, number_i32, &zero) orelse return;
    defer cf.CFRelease(num);
    CFAttributedStringSetAttribute(m, .{ .location = 0, .length = total }, kCTLigatureAttributeName, num);
}

/// The primary font's family name, in `buf`.
pub fn familyName(ref: cf.CTFontRef, buf: []u8) []const u8 {
    const name = CTFontCopyFamilyName(ref);
    defer cf.CFRelease(name);
    if (!CFStringGetCString(name, buf.ptr, @intCast(buf.len), cf.utf8_encoding)) return "";
    return std.mem.sliceTo(buf, 0);
}

extern "c" fn CFStringGetCString(s: cf.CFStringRef, buf: [*]u8, size: cf.CFIndex, encoding: u32) bool;
