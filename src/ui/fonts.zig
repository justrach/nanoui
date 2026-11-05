//! Fonts: the system's (SF Pro, SF Mono) or a family the theme names
//! (Geist, JetBrains Mono, …), at a weight and in italics. A named family
//! that is not installed falls back to the system's; a family without
//! italics is slanted, as browsers synthesize them. A family the app brought
//! comes before an installed one of that name.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const types = @import("types.zig");

extern "c" const kCTFontFamilyNameAttribute: cf.CFStringRef;
extern "c" const kCTFontTraitsAttribute: cf.CFStringRef;
extern "c" const kCTFontWeightTrait: cf.CFStringRef;
extern "c" const kCTFontSymbolicTrait: cf.CFStringRef;
extern "c" fn CFNumberCreate(alloc: ?*anyopaque, kind: cf.CFIndex, value: *const anyopaque) ?*anyopaque;
extern "c" fn CTFontDescriptorCreateWithAttributes(attrs: cf.CFDictionaryRef) ?*anyopaque;
extern "c" fn CTFontCreateWithFontDescriptor(desc: *anyopaque, size: f64, matrix: ?*const Transform) ?cf.CTFontRef;
extern "c" fn CTFontCreateCopyWithSymbolicTraits(font: cf.CTFontRef, size: f64, matrix: ?*const Transform, value: u32, mask: u32) ?cf.CTFontRef;
extern "c" fn CTFontCreateCopyWithAttributes(font: cf.CTFontRef, size: f64, matrix: ?*const Transform, attrs: ?*anyopaque) ?cf.CTFontRef;
extern "c" fn CTFontCopyFamilyName(font: cf.CTFontRef) cf.CFStringRef;
extern "c" fn CTFontGetSymbolicTraits(font: cf.CTFontRef) u32;
extern "c" fn CFStringCompare(a: cf.CFStringRef, b: cf.CFStringRef, options: u64) cf.CFIndex;

extern "c" fn CGDataProviderCreateWithData(info: ?*anyopaque, data: [*]const u8, size: usize, release: ?*const anyopaque) ?*anyopaque;
extern "c" fn CGFontCreateWithDataProvider(provider: *anyopaque) ?*anyopaque;
extern "c" fn CTFontManagerRegisterGraphicsFont(font: *anyopaque, err: ?*?*anyopaque) bool;
extern "c" fn CFErrorGetCode(err: *anyopaque) cf.CFIndex;
extern "c" fn CTFontCreateWithGraphicsFont(font: *anyopaque, size: f64, matrix: ?*const Transform, attrs: ?*anyopaque) ?cf.CTFontRef;
extern "c" fn CTFontCopyTraits(font: cf.CTFontRef) cf.CFDictionaryRef;
extern "c" fn CFDictionaryGetValue(dict: cf.CFDictionaryRef, key: ?*const anyopaque) ?*anyopaque;
extern "c" fn CFNumberGetValue(number: *anyopaque, kind: cf.CFIndex, out: *anyopaque) bool;

/// A file the app brought, found by its family's name before anything
/// installed: CoreText, asked by name, may answer with an installed cut of
/// the family, whose glyphs and kerning differ (a variable Geist beside the
/// app's own static files).
const Face = struct { font: *anyopaque, family: cf.CFStringRef, weight: f64, italic: bool };
var faces: [64]Face = undefined;
var face_count: usize = 0;

fn addFace(font: *anyopaque) void {
    if (face_count == faces.len) return;
    const ct = CTFontCreateWithGraphicsFont(font, 12, null, null) orelse return;
    defer cf.CFRelease(ct);
    const family = CTFontCopyFamilyName(ct);
    const traits = CTFontCopyTraits(ct);
    defer cf.CFRelease(traits);
    var weight: f64 = 0;
    if (CFDictionaryGetValue(traits, kCTFontWeightTrait)) |n| _ = CFNumberGetValue(n, kCFNumberFloat64Type, &weight);
    const italic = CTFontGetSymbolicTraits(ct) & italic_trait != 0;
    // The same face twice: the first stays, as CoreText's registering does.
    for (faces[0..face_count]) |f| {
        if (f.italic == italic and f.weight == weight and CFStringCompare(f.family, family, 0) == 0) {
            cf.CFRelease(family);
            return;
        }
    }
    faces[face_count] = .{ .font = @ptrCast(cf.CFRetain(font)), .family = family, .weight = weight, .italic = italic };
    face_count += 1;
}

/// Of the family's brought faces, the nearest in weight, in the slant asked
/// for if it has one.
fn brought(family: cf.CFStringRef, weight: f64, italic: bool) ?Face {
    var best: ?Face = null;
    for (faces[0..face_count]) |f| {
        if (CFStringCompare(f.family, family, 0) != 0) continue;
        const b = best orelse {
            best = f;
            continue;
        };
        const slant_better = f.italic == italic and b.italic != italic;
        const slant_same = f.italic == b.italic;
        if (slant_better or (slant_same and @abs(f.weight - weight) < @abs(b.weight - weight))) best = f;
    }
    return best;
}

/// Registers a font file's bytes (kept by the caller) for this process, so
/// its family is found by name.
pub fn registerData(bytes: []const u8) bool {
    const provider = CGDataProviderCreateWithData(null, bytes.ptr, bytes.len, null) orelse return false;
    defer cf.CFRelease(provider);
    const font = CGFontCreateWithDataProvider(provider) orelse return false;
    defer cf.CFRelease(font);
    addFace(font);
    var err: ?*anyopaque = null;
    if (CTFontManagerRegisterGraphicsFont(font, &err)) return true;
    const e = err orelse return false;
    defer cf.CFRelease(e);
    // Already registered (the same font twice) is as good.
    return CFErrorGetCode(e) == 105;
}

const Transform = extern struct { a: f64, b: f64, c: f64, d: f64, tx: f64, ty: f64 };
const italic_trait: u32 = 1 << 0;
const kCFNumberFloat64Type: cf.CFIndex = 6;
const kCFNumberSInt32Type: cf.CFIndex = 3;
/// The slant of synthesized italics (about 11°).
const slant: Transform = .{ .a = 1, .b = 0, .c = 0.2, .d = 1, .tx = 0, .ty = 0 };

/// CoreText's weights, as NSFontWeight (and UIFontWeight) values.
pub fn weightValue(w: types.Weight) f64 {
    return switch (w) {
        .regular => 0,
        .medium => 0.23,
        .semibold => 0.3,
        .bold => 0.4,
    };
}

extern "c" const kCTFontFeatureSettingsAttribute: cf.CFStringRef;
extern "c" const kCTFontOpenTypeFeatureTag: cf.CFStringRef;
extern "c" const kCTFontOpenTypeFeatureValue: cf.CFStringRef;
extern "c" fn CFArrayCreate(alloc: ?*anyopaque, values: [*]const ?*const anyopaque, count: cf.CFIndex, callbacks: *const anyopaque) ?*anyopaque;
extern "c" const kCFTypeArrayCallBacks: anyopaque;

/// `base`, released, with OpenType's `tnum` on; `base` if that can't be made.
pub fn tabular(base: cf.CTFontRef) cf.CTFontRef {
    const tag = cf.string("tnum");
    defer cf.CFRelease(tag);
    const on: i32 = 1;
    const value = CFNumberCreate(null, kCFNumberSInt32Type, &on) orelse return base;
    defer cf.CFRelease(value);
    const fkeys = [_]?*const anyopaque{ kCTFontOpenTypeFeatureTag, kCTFontOpenTypeFeatureValue };
    const fvals = [_]?*const anyopaque{ tag, value };
    const feature = cf.CFDictionaryCreate(null, &fkeys, &fvals, 2, &cf.kCFTypeDictionaryKeyCallBacks, &cf.kCFTypeDictionaryValueCallBacks) orelse return base;
    defer cf.CFRelease(feature);
    const list = [_]?*const anyopaque{feature};
    const settings = CFArrayCreate(null, &list, 1, &kCFTypeArrayCallBacks) orelse return base;
    defer cf.CFRelease(settings);
    const keys = [_]?*const anyopaque{kCTFontFeatureSettingsAttribute};
    const vals = [_]?*const anyopaque{settings};
    const attrs = cf.CFDictionaryCreate(null, &keys, &vals, 1, &cf.kCFTypeDictionaryKeyCallBacks, &cf.kCFTypeDictionaryValueCallBacks) orelse return base;
    defer cf.CFRelease(attrs);
    const desc = CTFontDescriptorCreateWithAttributes(attrs) orelse return base;
    defer cf.CFRelease(desc);
    const copy = CTFontCreateCopyWithAttributes(base, 0, null, desc) orelse return base;
    cf.CFRelease(base);
    return copy;
}

/// A retained font of `family` (or the system's when null or missing).
pub fn create(family: ?[]const u8, size: f32, weight: types.Weight, italic: bool, mono: bool) cf.CTFontRef {
    if (family) |name| if (named(name, size, weight, italic)) |f| return f;
    const ctor: [:0]const u8 = if (mono) "monospacedSystemFontOfSize:weight:" else "systemFontOfSize:weight:";
    const nsfont = objc.msg(objc.Object, objc.class(objc.font_class), ctor, .{ @as(f64, size), weightValue(weight) });
    // NSFont and UIFont are toll-free bridged with CTFont.
    const base: cf.CTFontRef = @ptrCast(objc.retain(nsfont));
    return if (italic) italicOf(base, size) else base;
}

/// `base` in italics, released; its own italic face, else slanted.
fn italicOf(base: cf.CTFontRef, size: f32) cf.CTFontRef {
    defer cf.CFRelease(base);
    if (CTFontCreateCopyWithSymbolicTraits(base, size, null, italic_trait, italic_trait)) |f| return f;
    return CTFontCreateCopyWithAttributes(base, size, &slant, null) orelse @ptrCast(cf.CFRetain(base));
}

fn named(name: []const u8, size: f32, weight: types.Weight, italic: bool) ?cf.CTFontRef {
    const family = cf.string(name);
    defer cf.CFRelease(family);
    const w = weightValue(weight);
    if (brought(family, w, italic)) |face| {
        const f = CTFontCreateWithGraphicsFont(face.font, size, null, null) orelse return null;
        if (!italic or face.italic) return f;
        defer cf.CFRelease(f);
        return CTFontCreateCopyWithAttributes(f, size, &slant, null);
    }
    const wnum = CFNumberCreate(null, kCFNumberFloat64Type, &w) orelse return null;
    defer cf.CFRelease(wnum);
    const sym: i32 = if (italic) @intCast(italic_trait) else 0;
    const snum = CFNumberCreate(null, kCFNumberSInt32Type, &sym) orelse return null;
    defer cf.CFRelease(snum);
    const tkeys = [_]?*const anyopaque{ kCTFontWeightTrait, kCTFontSymbolicTrait };
    const tvals = [_]?*const anyopaque{ wnum, snum };
    const traits = cf.CFDictionaryCreate(null, &tkeys, &tvals, 2, &cf.kCFTypeDictionaryKeyCallBacks, &cf.kCFTypeDictionaryValueCallBacks) orelse return null;
    defer cf.CFRelease(traits);
    const keys = [_]?*const anyopaque{ kCTFontFamilyNameAttribute, kCTFontTraitsAttribute };
    const vals = [_]?*const anyopaque{ family, traits };
    const attrs = cf.CFDictionaryCreate(null, &keys, &vals, 2, &cf.kCFTypeDictionaryKeyCallBacks, &cf.kCFTypeDictionaryValueCallBacks) orelse return null;
    defer cf.CFRelease(attrs);
    const desc = CTFontDescriptorCreateWithAttributes(attrs) orelse return null;
    defer cf.CFRelease(desc);
    const f = CTFontCreateWithFontDescriptor(desc, size, null) orelse return null;
    // CoreText answers with a fallback when the family is missing.
    const got = CTFontCopyFamilyName(f);
    defer cf.CFRelease(got);
    if (CFStringCompare(got, family, 0) != 0) {
        cf.CFRelease(f);
        return null;
    }
    if (italic and CTFontGetSymbolicTraits(f) & italic_trait == 0) {
        defer cf.CFRelease(f);
        return CTFontCreateCopyWithAttributes(f, size, &slant, null);
    }
    return f;
}
