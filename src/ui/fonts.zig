//! Fonts: the system's (SF Pro, SF Mono) or a family the theme names
//! (Geist, JetBrains Mono, …), at a weight and in italics. A named family
//! that is not installed falls back to the system's; a family without
//! italics is slanted, as browsers synthesize them.
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

extern "c" fn CTFontCopyFontDescriptor(font: cf.CTFontRef) *anyopaque;
extern "c" fn CTFontDescriptorCreateCopyWithFeature(desc: *anyopaque, feature_type: *anyopaque, selector: *anyopaque) ?*anyopaque;
/// `kNumberSpacingType`, `kMonospacedNumbersSelector` (SFNTLayoutTypes.h).
const number_spacing: i32 = 6;
const monospaced_numbers: i32 = 0;

/// `base` with monospaced (tabular) digits, released.
pub fn tabular(base: cf.CTFontRef) cf.CTFontRef {
    defer cf.CFRelease(base);
    const kind = CFNumberCreate(null, kCFNumberSInt32Type, &number_spacing) orelse return @ptrCast(cf.CFRetain(base));
    defer cf.CFRelease(kind);
    const sel = CFNumberCreate(null, kCFNumberSInt32Type, &monospaced_numbers) orelse return @ptrCast(cf.CFRetain(base));
    defer cf.CFRelease(sel);
    const own = CTFontCopyFontDescriptor(base);
    defer cf.CFRelease(own);
    const desc = CTFontDescriptorCreateCopyWithFeature(own, kind, sel) orelse return @ptrCast(cf.CFRetain(base));
    defer cf.CFRelease(desc);
    // Size 0 and no matrix: the font's own (an italic's slant kept).
    return CTFontCreateCopyWithAttributes(base, 0, null, desc) orelse @ptrCast(cf.CFRetain(base));
}

extern "c" const NSFontDescriptorSystemDesignRounded: objc.Object;

/// `base` in the system's rounded design (SF Rounded), released; `base`
/// itself where the face has none (a named family).
pub fn rounded(base: cf.CTFontRef) cf.CTFontRef {
    const pool = objc.Pool.push();
    defer pool.pop();
    const font: objc.Object = @ptrCast(base);
    const desc = objc.msg(objc.Object, font, "fontDescriptor", .{});
    const round = objc.msg(?objc.Object, desc, "fontDescriptorWithDesign:", .{NSFontDescriptorSystemDesignRounded}) orelse return base;
    // Size 0: the descriptor's own.
    const made = objc.msg(?objc.Object, objc.class("NSFont"), "fontWithDescriptor:size:", .{ round, @as(f64, 0) }) orelse return base;
    cf.CFRelease(base);
    return @ptrCast(objc.retain(made));
}
