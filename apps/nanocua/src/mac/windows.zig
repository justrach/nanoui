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

fn int(v: ?*anyopaque) ?i64 {
    const x = v orelse return null;
    if (cf.CFGetTypeID(x) != cf.CFNumberGetTypeID()) return null;
    var n: i64 = 0;
    return if (cf.CFNumberGetValue(@ptrCast(x), number_sint64, &n)) n else null;
}

/// App `pid`'s main window, if it has one.
pub fn main(pid: i32) ?Window {
    const list = CGWindowListCopyWindowInfo(exclude_desktop, 0) orelse return null;
    defer cf.CFRelease(list);
    var best: ?Window = null;
    const n: usize = @intCast(cf.CFArrayGetCount(list));
    for (0..n) |i| {
        const d: cf.CFDictionaryRef = @ptrCast(cf.CFArrayGetValueAtIndex(list, @intCast(i)) orelse continue);
        if (int(CFDictionaryGetValue(d, kCGWindowOwnerPID)) != pid) continue;
        if (int(CFDictionaryGetValue(d, kCGWindowLayer)) != 0) continue;
        var w: Window = .{ .id = @intCast(int(CFDictionaryGetValue(d, kCGWindowNumber)) orelse continue), .frame = .{} };
        const bounds = CFDictionaryGetValue(d, kCGWindowBounds) orelse continue;
        if (!CGRectMakeWithDictionaryRepresentation(@ptrCast(bounds), &w.frame)) continue;
        if (w.frame.size.width < 2 or w.frame.size.height < 2) continue;
        w.onscreen = cf.boolean(CFDictionaryGetValue(d, kCGWindowIsOnscreen)) orelse false;
        if (best == null or better(w, best.?)) best = w;
    }
    return best;
}

test "the main window: on screen first, then the largest" {
    const at = struct {
        fn f(w: f64, h: f64, on: bool) Window {
            return .{ .id = 1, .frame = .{ .size = .{ .width = w, .height = h } }, .onscreen = on };
        }
    }.f;
    try std.testing.expect(better(at(1352, 802, true), at(1352, 47, true)));
    try std.testing.expect(!better(at(1352, 47, true), at(1352, 802, true)));
    try std.testing.expect(better(at(10, 10, true), at(1352, 849, false)));
}
