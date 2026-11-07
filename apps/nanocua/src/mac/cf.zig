//! CoreFoundation, the Accessibility API (HIServices) and the screen
//! capture permission, declared directly; and reading CF values as Zig.
const std = @import("std");

pub const CFTypeRef = *opaque {};
pub const CFStringRef = *opaque {};
pub const CFArrayRef = *opaque {};
pub const CFDictionaryRef = *opaque {};
pub const CFMutableDataRef = *opaque {};
pub const CFNumberRef = *opaque {};
pub const AXUIElementRef = *opaque {};
pub const CFIndex = isize;
pub const CFRange = extern struct { location: CFIndex, length: CFIndex };
pub const CGPoint = extern struct { x: f64 = 0, y: f64 = 0 };
pub const CGSize = extern struct { width: f64 = 0, height: f64 = 0 };
pub const CGRect = extern struct { origin: CGPoint = .{}, size: CGSize = .{} };

const utf8: u32 = 0x08000100;

pub extern "c" const kCFTypeArrayCallBacks: opaque {};
pub extern "c" const kCFTypeDictionaryKeyCallBacks: opaque {};
pub extern "c" const kCFTypeDictionaryValueCallBacks: opaque {};
pub extern "c" const kCFBooleanTrue: CFTypeRef;
pub extern "c" const kCFBooleanFalse: CFTypeRef;
pub extern "c" fn CFRelease(ref: *anyopaque) void;
pub extern "c" fn CFRetain(ref: *anyopaque) *anyopaque;
pub extern "c" fn CFGetTypeID(ref: *anyopaque) usize;
pub extern "c" fn CFStringGetTypeID() usize;
pub extern "c" fn CFArrayGetTypeID() usize;
pub extern "c" fn CFBooleanGetTypeID() usize;
pub extern "c" fn CFNumberGetTypeID() usize;
pub extern "c" fn CFStringCreateWithBytes(alloc: ?*anyopaque, bytes: [*]const u8, len: CFIndex, encoding: u32, external: bool) ?CFStringRef;
pub extern "c" fn CFStringGetLength(s: CFStringRef) CFIndex;
pub extern "c" fn CFStringGetBytes(s: CFStringRef, range: CFRange, encoding: u32, loss: u8, external: bool, buf: ?[*]u8, max: CFIndex, used: ?*CFIndex) CFIndex;
pub extern "c" fn CFArrayCreate(alloc: ?*anyopaque, values: [*]const ?*const anyopaque, n: CFIndex, cb: *const anyopaque) ?CFArrayRef;
pub extern "c" fn CFArrayGetCount(a: CFArrayRef) CFIndex;
pub extern "c" fn CFArrayGetValueAtIndex(a: CFArrayRef, i: CFIndex) ?*anyopaque;
pub extern "c" fn CFBooleanGetValue(b: CFTypeRef) bool;
pub extern "c" fn CFNumberGetValue(n: CFTypeRef, kind: CFIndex, out: *anyopaque) bool;
pub extern "c" fn CFNumberCreate(alloc: ?*anyopaque, kind: CFIndex, value: *const anyopaque) ?CFNumberRef;
pub extern "c" fn CFDictionaryCreate(alloc: ?*anyopaque, keys: [*]const ?*const anyopaque, values: [*]const ?*const anyopaque, n: CFIndex, key_cb: *const anyopaque, value_cb: *const anyopaque) ?CFDictionaryRef;
pub extern "c" fn CFDataCreateMutable(alloc: ?*anyopaque, capacity: CFIndex) ?CFMutableDataRef;
pub extern "c" fn CFDataGetLength(d: CFMutableDataRef) CFIndex;
pub extern "c" fn CFDataGetBytePtr(d: CFMutableDataRef) [*]const u8;
pub const number_double: CFIndex = 13;

// Accessibility (HIServices).
pub const AXError = i32;
pub extern "c" fn AXIsProcessTrusted() bool;
pub extern "c" fn AXIsProcessTrustedWithOptions(options: ?CFDictionaryRef) bool;
pub extern "c" const kAXTrustedCheckOptionPrompt: CFStringRef;
pub extern "c" fn AXUIElementCreateSystemWide() AXUIElementRef;
pub extern "c" fn AXUIElementCreateApplication(pid: i32) AXUIElementRef;
pub extern "c" fn AXUIElementCopyAttributeValue(el: AXUIElementRef, attr: CFStringRef, out: *?CFTypeRef) AXError;
pub extern "c" fn AXUIElementCopyMultipleAttributeValues(el: AXUIElementRef, attrs: CFArrayRef, options: u32, out: *?CFArrayRef) AXError;
pub extern "c" fn AXUIElementSetAttributeValue(el: AXUIElementRef, attr: CFStringRef, value: *anyopaque) AXError;
pub extern "c" fn AXUIElementPerformAction(el: AXUIElementRef, action: CFStringRef) AXError;
pub extern "c" fn AXUIElementSetMessagingTimeout(el: AXUIElementRef, seconds: f32) AXError;
pub extern "c" fn AXUIElementCopyElementAtPosition(app: AXUIElementRef, x: f32, y: f32, out: *?AXUIElementRef) AXError;
pub extern "c" fn AXUIElementGetPid(el: AXUIElementRef, pid: *i32) AXError;
pub extern "c" fn AXValueGetTypeID() usize;
pub extern "c" fn AXValueGetType(v: CFTypeRef) u32;
pub extern "c" fn AXValueGetValue(v: CFTypeRef, kind: u32, out: *anyopaque) bool;
pub const ax_point: u32 = 1;
pub const ax_size: u32 = 2;

// The screen: its bounds and the permission to capture it.
pub extern "c" fn CGMainDisplayID() u32;
pub extern "c" fn CGDisplayBounds(display: u32) CGRect;
pub extern "c" fn CGPreflightScreenCaptureAccess() bool;
pub extern "c" fn CGRequestScreenCaptureAccess() bool;

/// A CFString of `s`; release it.
pub fn str(s: []const u8) CFStringRef {
    return CFStringCreateWithBytes(null, s.ptr, @intCast(s.len), utf8, false) orelse
        CFStringCreateWithBytes(null, "?", 1, utf8, false).?;
}

pub fn isString(v: *anyopaque) bool {
    return CFGetTypeID(v) == CFStringGetTypeID();
}

/// A CF string's UTF-8 into `buf` (cut if it doesn't fit).
pub fn utf8Into(buf: []u8, s: CFStringRef) []const u8 {
    var used: CFIndex = 0;
    const len = CFStringGetLength(s);
    _ = CFStringGetBytes(s, .{ .location = 0, .length = len }, utf8, '?', false, buf.ptr, @intCast(buf.len), &used);
    return buf[0..@intCast(used)];
}

/// A value as text: strings as they are, numbers and booleans written.
pub fn text(buf: []u8, v: ?*anyopaque) []const u8 {
    const x = v orelse return "";
    const t = CFGetTypeID(x);
    if (t == CFStringGetTypeID()) return utf8Into(buf, @ptrCast(x));
    if (t == CFNumberGetTypeID()) {
        var d: f64 = 0;
        if (!CFNumberGetValue(@ptrCast(x), number_double, &d)) return "";
        return std.fmt.bufPrint(buf, "{d}", .{d}) catch "";
    }
    if (t == CFBooleanGetTypeID()) return if (CFBooleanGetValue(@ptrCast(x))) "true" else "false";
    return "";
}

pub fn boolean(v: ?*anyopaque) ?bool {
    const x = v orelse return null;
    if (CFGetTypeID(x) != CFBooleanGetTypeID()) return null;
    return CFBooleanGetValue(@ptrCast(x));
}

pub fn point(v: ?*anyopaque) ?CGPoint {
    const x = v orelse return null;
    if (CFGetTypeID(x) != AXValueGetTypeID() or AXValueGetType(@ptrCast(x)) != ax_point) return null;
    var p: CGPoint = .{};
    return if (AXValueGetValue(@ptrCast(x), ax_point, &p)) p else null;
}

pub fn size(v: ?*anyopaque) ?CGSize {
    const x = v orelse return null;
    if (CFGetTypeID(x) != AXValueGetTypeID() or AXValueGetType(@ptrCast(x)) != ax_size) return null;
    var s: CGSize = .{};
    return if (AXValueGetValue(@ptrCast(x), ax_size, &s)) s else null;
}

pub fn array(v: ?*anyopaque) ?CFArrayRef {
    const x = v orelse return null;
    return if (CFGetTypeID(x) == CFArrayGetTypeID()) @ptrCast(x) else null;
}

/// Whether this process may use accessibility; with `prompt`, the system
/// asks the user (once) to allow it.
pub fn trusted(prompt: bool) bool {
    if (!prompt) return AXIsProcessTrusted();
    const keys = [_]?*const anyopaque{kAXTrustedCheckOptionPrompt};
    const values = [_]?*const anyopaque{kCFBooleanTrue};
    const opts = CFDictionaryCreate(null, &keys, &values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    defer if (opts) |o| CFRelease(o);
    return AXIsProcessTrustedWithOptions(opts);
}

test "CF strings and values read back" {
    const s = str("héllo");
    defer CFRelease(s);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("héllo", text(&buf, s));
    try std.testing.expectEqualStrings("hé", utf8Into(buf[0..3], s));
    const d: f64 = 2.5;
    const n = CFNumberCreate(null, number_double, &d).?;
    defer CFRelease(n);
    try std.testing.expectEqualStrings("2.5", text(&buf, n));
    try std.testing.expectEqual(@as(?bool, true), boolean(kCFBooleanTrue));
    try std.testing.expectEqual(@as(?bool, null), boolean(s));
}
