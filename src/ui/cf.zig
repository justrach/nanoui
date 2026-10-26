//! CoreFoundation, CoreGraphics, CoreText and QuartzCore, declared directly.
const objc = @import("../objc.zig");

pub const CFTypeRef = *opaque {};
pub const CFStringRef = *opaque {};
pub const CFDictionaryRef = *opaque {};
pub const CFAttributedStringRef = *opaque {};
pub const CTLineRef = *opaque {};
pub const CTTypesetterRef = *opaque {};
pub const CTFontRef = *opaque {};
pub const CGContextRef = *opaque {};
pub const CGColorSpaceRef = *opaque {};
pub const CFIndex = isize;
pub const CFRange = extern struct { location: CFIndex, length: CFIndex };

pub const utf8_encoding: u32 = 0x08000100;
pub const image_alpha_only: u32 = 7;

pub extern "c" const kCFTypeDictionaryKeyCallBacks: opaque {};
pub extern "c" const kCFTypeDictionaryValueCallBacks: opaque {};
pub extern "c" const kCFBooleanTrue: CFTypeRef;
pub extern "c" const kCTFontAttributeName: CFStringRef;
pub extern "c" const kCTForegroundColorFromContextAttributeName: CFStringRef;

pub extern "c" fn CFRelease(ref: *anyopaque) void;
pub extern "c" fn CFRetain(ref: *anyopaque) *anyopaque;
pub extern "c" fn CFStringCreateWithBytes(alloc: ?*anyopaque, bytes: [*]const u8, len: CFIndex, encoding: u32, external: bool) ?CFStringRef;
pub extern "c" fn CFStringGetLength(s: CFStringRef) CFIndex;
pub extern "c" fn CFDictionaryCreate(alloc: ?*anyopaque, keys: [*]const ?*const anyopaque, values: [*]const ?*const anyopaque, n: CFIndex, key_cb: *const anyopaque, value_cb: *const anyopaque) ?CFDictionaryRef;
pub extern "c" fn CFAttributedStringCreate(alloc: ?*anyopaque, s: CFStringRef, attrs: CFDictionaryRef) ?CFAttributedStringRef;

pub extern "c" fn CTLineCreateWithAttributedString(s: CFAttributedStringRef) ?CTLineRef;
pub extern "c" fn CTLineGetTypographicBounds(line: CTLineRef, ascent: ?*f64, descent: ?*f64, leading: ?*f64) f64;
pub extern "c" fn CTLineDraw(line: CTLineRef, ctx: CGContextRef) void;
pub extern "c" fn CTLineGetOffsetForStringIndex(line: CTLineRef, index: CFIndex, secondary: ?*f64) f64;
pub extern "c" fn CTLineGetStringIndexForPosition(line: CTLineRef, pos: objc.CGPoint) CFIndex;
pub extern "c" fn CTTypesetterCreateWithAttributedString(s: CFAttributedStringRef) ?CTTypesetterRef;
pub extern "c" fn CTTypesetterSuggestLineBreak(ts: CTTypesetterRef, start: CFIndex, width: f64) CFIndex;

pub extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, w: usize, h: usize, bpc: usize, bpr: usize, space: ?CGColorSpaceRef, info: u32) ?CGContextRef;
pub extern "c" fn CGContextRelease(ctx: CGContextRef) void;
pub extern "c" fn CGContextScaleCTM(ctx: CGContextRef, sx: f64, sy: f64) void;
pub extern "c" fn CGContextSetTextPosition(ctx: CGContextRef, x: f64, y: f64) void;
pub extern "c" fn CGContextSetGrayFillColor(ctx: CGContextRef, gray: f64, alpha: f64) void;
pub extern "c" fn CGContextSetShouldSmoothFonts(ctx: CGContextRef, v: bool) void;
pub extern "c" fn CGContextSetShouldAntialias(ctx: CGContextRef, v: bool) void;
pub extern "c" fn CGContextSetAllowsFontSubpixelPositioning(ctx: CGContextRef, v: bool) void;
pub extern "c" fn CGContextSetShouldSubpixelPositionFonts(ctx: CGContextRef, v: bool) void;
pub extern "c" fn CGContextSetAllowsFontSubpixelQuantization(ctx: CGContextRef, v: bool) void;
pub extern "c" fn CGContextSetShouldSubpixelQuantizeFonts(ctx: CGContextRef, v: bool) void;
pub extern "c" fn CGContextSetAllowsAntialiasing(ctx: CGContextRef, v: bool) void;

pub extern "c" const kCGColorSpaceSRGB: CFStringRef;
pub extern "c" fn CGColorSpaceCreateWithName(name: CFStringRef) ?CGColorSpaceRef;
pub extern "c" fn CGColorSpaceRelease(space: CGColorSpaceRef) void;
pub extern "c" fn CGColorSpaceCreateDeviceGray() ?CGColorSpaceRef;
pub extern "c" const kCFPreferencesCurrentApplication: CFStringRef;
pub extern "c" fn CFPreferencesCopyAppValue(key: CFStringRef, app: CFStringRef) ?*anyopaque;
pub extern "c" fn CFNumberGetTypeID() usize;
pub extern "c" fn CFGetTypeID(ref: *anyopaque) usize;
pub extern "c" fn CFNumberGetValue(number: *anyopaque, kind: CFIndex, out: *anyopaque) bool;
/// `kCFNumberSInt64Type`.
pub const number_sint64: CFIndex = 4;

pub extern "c" fn CACurrentMediaTime() f64;
pub extern "c" fn MTLCreateSystemDefaultDevice() ?objc.Object;

/// A CFString of `s`; release with CFRelease.
pub fn string(s: []const u8) CFStringRef {
    return CFStringCreateWithBytes(null, s.ptr, @intCast(s.len), utf8_encoding, false) orelse
        CFStringCreateWithBytes(null, "?", 1, utf8_encoding, false).?;
}

/// An attributed string of `s` in `font`, colored by the context; release with CFRelease.
pub fn attributed(s: []const u8, font: CTFontRef) CFAttributedStringRef {
    const str = string(s);
    defer CFRelease(str);
    const keys = [_]?*const anyopaque{ kCTFontAttributeName, kCTForegroundColorFromContextAttributeName };
    const values = [_]?*const anyopaque{ font, kCFBooleanTrue };
    const attrs = CFDictionaryCreate(null, &keys, &values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks).?;
    defer CFRelease(attrs);
    return CFAttributedStringCreate(null, str, attrs).?;
}

/// The UTF-16 offset of byte offset `byte` in UTF-8 `s`.
pub fn utf16Offset(s: []const u8, byte: usize) CFIndex {
    var n: CFIndex = 0;
    var i: usize = 0;
    while (i < byte and i < s.len) {
        const len = seqLen(s[i]);
        n += if (len == 4) 2 else 1;
        i += len;
    }
    return n;
}

/// The byte offset of UTF-16 offset `u16_index` in UTF-8 `s`.
pub fn byteOffset(s: []const u8, u16_index: CFIndex) usize {
    var n: CFIndex = 0;
    var i: usize = 0;
    while (i < s.len and n < u16_index) {
        const len = seqLen(s[i]);
        n += if (len == 4) 2 else 1;
        i += len;
    }
    return @min(i, s.len);
}

pub const seqLen = @import("utf8.zig").seqLen;
