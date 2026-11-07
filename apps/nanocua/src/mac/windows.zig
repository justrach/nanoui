//! An app's main window from the window server's list, which needs no
//! permission for the numbers and frames used here: what a window screenshot
//! captures, and what a background click says it is over.
const std = @import("std");
const cf = @import("cf.zig");

extern "c" fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) ?cf.CFArrayRef;
extern "c" fn CGRectMakeWithDictionaryRepresentation(dict: cf.CFDictionaryRef, rect: *cf.CGRect) bool;
extern "c" fn CFDictionaryGetValue(dict: cf.CFDictionaryRef, key: *const anyopaque) ?*anyopaque;
extern "c" const kCGWindowNumber: cf.CFStringRef;
extern "c" const kCGWindowOwnerPID: cf.CFStringRef;
extern "c" const kCGWindowLayer: cf.CFStringRef;
extern "c" const kCGWindowBounds: cf.CFStringRef;
extern "c" const kCGWindowIsOnscreen: cf.CFStringRef;

const exclude_desktop: u32 = 16;
const number_sint64: cf.CFIndex = 4;

pub const Window = struct {
    id: u32,
    frame: cf.CGRect,
    onscreen: bool = true,
};

/// Which of two windows is the app's main one: what is on screen before what
/// isn't, then the largest (browsers keep toolbars in slim windows of their own).
pub fn better(a: Window, b: Window) bool {
    if (a.onscreen != b.onscreen) return a.onscreen;
    return a.frame.size.width * a.frame.size.height > b.frame.size.width * b.frame.size.height;
}

/// Whether it's big enough to be a window someone works in. An app can have
/// layer 0 strips and icons and nothing else: Finder with its windows closed has a
/// menu-bar-sized strip, whose picture is blank.
pub fn sizedLikeAWindow(w: Window) bool {
    return w.frame.size.width >= 100 and w.frame.size.height >= 40;
}

fn int(v: ?*anyopaque) ?i64 {
    const x = v orelse return null;
    if (cf.CFGetTypeID(x) != cf.CFNumberGetTypeID()) return null;
    var n: i64 = 0;
    return if (cf.CFNumberGetValue(@ptrCast(x), number_sint64, &n)) n else null;
}

fn read(d: cf.CFDictionaryRef, pid: i32) ?Window {
    if (int(CFDictionaryGetValue(d, kCGWindowOwnerPID)) != pid) return null;
    if (int(CFDictionaryGetValue(d, kCGWindowLayer)) != 0) return null;
    var w: Window = .{ .id = @intCast(int(CFDictionaryGetValue(d, kCGWindowNumber)) orelse return null), .frame = .{} };
    const bounds = CFDictionaryGetValue(d, kCGWindowBounds) orelse return null;
    if (!CGRectMakeWithDictionaryRepresentation(@ptrCast(bounds), &w.frame)) return null;
    if (w.frame.size.width < 2 or w.frame.size.height < 2) return null;
    w.onscreen = cf.boolean(CFDictionaryGetValue(d, kCGWindowIsOnscreen)) orelse false;
    return w;
}

/// App `pid`'s main window, if it has one.
pub fn main(pid: i32) ?Window {
    const list = CGWindowListCopyWindowInfo(exclude_desktop, 0) orelse return null;
    defer cf.CFRelease(list);
    var best: ?Window = null;
    const n: usize = @intCast(cf.CFArrayGetCount(list));
    for (0..n) |i| {
        const d: cf.CFDictionaryRef = @ptrCast(cf.CFArrayGetValueAtIndex(list, @intCast(i)) orelse continue);
        const w = read(d, pid) orelse continue;
        if (!sizedLikeAWindow(w)) continue;
        if (best == null or better(w, best.?)) best = w;
    }
    return best;
}

pub fn contains(w: Window, x: f64, y: f64) bool {
    const f = w.frame;
    return x >= f.origin.x and y >= f.origin.y and x < f.origin.x + f.size.width and y < f.origin.y + f.size.height;
}

/// App `pid`'s window at x, y: the frontmost that shows there, as the list runs
/// front to back. Else one that isn't on screen just now (another Space).
pub fn at(pid: i32, x: f64, y: f64) ?Window {
    const list = CGWindowListCopyWindowInfo(exclude_desktop, 0) orelse return null;
    defer cf.CFRelease(list);
    var hidden: ?Window = null;
    const n: usize = @intCast(cf.CFArrayGetCount(list));
    for (0..n) |i| {
        const d: cf.CFDictionaryRef = @ptrCast(cf.CFArrayGetValueAtIndex(list, @intCast(i)) orelse continue);
        const w = read(d, pid) orelse continue;
        if (!contains(w, x, y)) continue;
        if (w.onscreen) return w;
        if (hidden == null) hidden = w;
    }
    return hidden;
}

/// A window's frame as x, y, width, height.
pub fn box(w: Window) [4]f64 {
    return .{ w.frame.origin.x, w.frame.origin.y, w.frame.size.width, w.frame.size.height };
}

test "the main window: on screen first, then the largest" {
    const of = struct {
        fn f(w: f64, h: f64, on: bool) Window {
            return .{ .id = 1, .frame = .{ .size = .{ .width = w, .height = h } }, .onscreen = on };
        }
    }.f;
    try std.testing.expect(better(of(1352, 802, true), of(1352, 47, true)));
    try std.testing.expect(!better(of(1352, 47, true), of(1352, 802, true)));
    try std.testing.expect(better(of(10, 10, true), of(1352, 849, false)));
}

test "strips and icons aren't an app's main window" {
    const of = struct {
        fn f(w: f64, h: f64) Window {
            return .{ .id = 1, .frame = .{ .size = .{ .width = w, .height = h } }, .onscreen = false };
        }
    }.f;
    try std.testing.expect(!sizedLikeAWindow(of(1352, 29)));
    try std.testing.expect(!sizedLikeAWindow(of(64, 64)));
    try std.testing.expect(sizedLikeAWindow(of(1352, 47)));
    try std.testing.expect(sizedLikeAWindow(of(260, 400)));
}

test "a window contains the points in its frame" {
    const w: Window = .{ .id = 1, .frame = .{ .origin = .{ .x = 100, .y = 50 }, .size = .{ .width = 200, .height = 100 } } };
    try std.testing.expect(contains(w, 100, 50) and contains(w, 299, 149));
    try std.testing.expect(!contains(w, 300, 100) and !contains(w, 10, 10));
    try std.testing.expectEqual([4]f64{ 100, 50, 200, 100 }, box(w));
}
