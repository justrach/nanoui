//! Pictures: one window, even behind others (ScreenCaptureKit's window filter,
//! macOS 14 and later), or a rectangle of the screen (macOS 15.2 and later;
//! CGWindowListCreateImage before either), encoded as JPEG by ImageIO at most
//! `max_size` pixels on the longer side. Runs on the backend's queue, waiting
//! there for ScreenCaptureKit's answer.
const std = @import("std");
const objc = @import("nanoui").objc;
const cf = @import("cf.zig");

const CGImageRef = *opaque {};
const Destination = *opaque {};
extern "c" fn CGImageGetWidth(img: CGImageRef) usize;
extern "c" fn CGImageGetHeight(img: CGImageRef) usize;
extern "c" fn CGImageRelease(img: CGImageRef) void;
extern "c" fn CGWindowListCreateImage(rect: cf.CGRect, list: u32, window: u32, options: u32) ?CGImageRef;
extern "c" fn CGImageDestinationCreateWithData(data: cf.CFMutableDataRef, kind: cf.CFStringRef, count: usize, options: ?cf.CFDictionaryRef) ?Destination;
extern "c" fn CGImageDestinationAddImage(dest: Destination, img: CGImageRef, props: ?cf.CFDictionaryRef) void;
extern "c" fn CGImageDestinationFinalize(dest: Destination) bool;
extern "c" const kCGImageDestinationLossyCompressionQuality: cf.CFStringRef;
extern "c" const kCGImageDestinationImageMaxPixelSize: cf.CFStringRef;
extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Class;
extern "c" const CGRectNull: cf.CGRect;

const list_including_window: u32 = 8;
const image_bounds_ignore_framing: u32 = 1;

pub const Shot = struct {
    /// Base64 of the JPEG.
    data: []u8,
    /// The image's size in pixels, after scaling.
    width: usize,
    height: usize,
};

pub const Error = error{ NoPermission, CaptureFailed, EncodeFailed, OutOfMemory };

/// The main display's frame in points.
pub fn screen() cf.CGRect {
    return cf.CGDisplayBounds(cf.CGMainDisplayID());
}

pub fn allowed() bool {
    return cf.CGPreflightScreenCaptureAccess();
}

var nothing: u8 = 0;

fn ignore(_: *u8, _: ?objc.Object, _: ?objc.Object) void {}

/// Asks ScreenCaptureKit for what it could capture and ignores the answer:
/// without permission, this is what gets the app listed in System Settings,
/// where the permission request alone may not.
pub fn register() void {
    const cls = objc_getClass("SCShareableContent") orelse return;
    var block = objc.Block(u8, &.{ ?objc.Object, ?objc.Object }).init(&nothing, ignore);
    objc.msg(void, cls, "getShareableContentWithCompletionHandler:", .{@as(*anyopaque, @ptrCast(&block))});
}

/// A rectangle of the screen.
pub fn capture(gpa: std.mem.Allocator, rect: cf.CGRect, max_size: u32) Error!Shot {
    // Asking would put up the system's prompt for an agent: only the user
    // asks, from the panel.
    if (!allowed()) return error.NoPermission;
    const img = try grab(gpa, rect) orelse return error.CaptureFailed;
    defer CGImageRelease(img);
    return encode(gpa, img, max_size);
}

/// One window, whatever is in front of it. `frame` is its size in points.
pub fn window(gpa: std.mem.Allocator, id: u32, frame: cf.CGRect, max_size: u32) Error!Shot {
    if (!allowed()) return error.NoPermission;
    const img = try grabWindow(gpa, id, frame, max_size) orelse return error.CaptureFailed;
    defer CGImageRelease(img);
    return encode(gpa, img, max_size);
}

fn encode(gpa: std.mem.Allocator, img: CGImageRef, max_size: u32) Error!Shot {
    const w = CGImageGetWidth(img);
    const h = CGImageGetHeight(img);
    const longer = @max(w, h, 1);
    const scale = @min(1.0, @as(f64, @floatFromInt(max_size)) / @as(f64, @floatFromInt(longer)));
    const out_w: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(w)) * scale))));
    const out_h: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(h)) * scale))));

    const data = cf.CFDataCreateMutable(null, 0) orelse return error.OutOfMemory;
    defer cf.CFRelease(data);
    const kind = cf.str("public.jpeg");
    defer cf.CFRelease(kind);
    const dest = CGImageDestinationCreateWithData(data, kind, 1, null) orelse return error.EncodeFailed;
    defer cf.CFRelease(dest);
    const quality: f64 = 0.75;
    const max_px: f64 = @floatFromInt(@max(out_w, out_h));
    const q = cf.CFNumberCreate(null, cf.number_double, &quality) orelse return error.OutOfMemory;
    defer cf.CFRelease(q);
    const m = cf.CFNumberCreate(null, cf.number_double, &max_px) orelse return error.OutOfMemory;
    defer cf.CFRelease(m);
    const keys = [_]?*const anyopaque{ kCGImageDestinationLossyCompressionQuality, kCGImageDestinationImageMaxPixelSize };
    const values = [_]?*const anyopaque{ q, m };
    const props = cf.CFDictionaryCreate(null, &keys, &values, 2, &cf.kCFTypeDictionaryKeyCallBacks, &cf.kCFTypeDictionaryValueCallBacks) orelse return error.OutOfMemory;
    defer cf.CFRelease(props);
    CGImageDestinationAddImage(dest, img, props);
    if (!CGImageDestinationFinalize(dest)) return error.EncodeFailed;
    const bytes = cf.CFDataGetBytePtr(data)[0..@intCast(cf.CFDataGetLength(data))];
    const enc = std.base64.standard.Encoder;
    const b64 = try gpa.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(b64, bytes);
    return .{ .data = b64, .width = out_w, .height = out_h };
}

const Wait = struct {
    sem: objc.dispatch_semaphore_t,
    image: ?CGImageRef = null,

    fn done(w: *Wait, img: ?*anyopaque, err: ?objc.Object) void {
        _ = err;
        if (img) |i| w.image = @ptrCast(cf.CFRetain(i));
        _ = objc.dispatch_semaphore_signal(w.sem);
    }
};

/// The window server's windows, for finding one to capture.
const Shareable = struct {
    sem: objc.dispatch_semaphore_t,
    content: ?objc.Object = null,

    fn done(w: *Shareable, content: ?objc.Object, err: ?objc.Object) void {
        _ = err;
        if (content) |c| w.content = objc.retain(c);
        _ = objc.dispatch_semaphore_signal(w.sem);
    }
};

const answer_timeout: u64 = 10 * std.time.ns_per_s;

/// What ScreenCaptureKit could capture, retained.
fn shareableContent(gpa: std.mem.Allocator, cls: objc.Class) !?objc.Object {
    const wait = try gpa.create(Shareable);
    wait.* = .{ .sem = objc.dispatch_semaphore_create(0) };
    var block = objc.Block(Shareable, &.{ ?objc.Object, ?objc.Object }).init(wait, Shareable.done);
    objc.msg(void, cls, "getShareableContentWithCompletionHandler:", .{@as(*anyopaque, @ptrCast(&block))});
    // As with a picture: a late answer still has somewhere to go.
    if (objc.dispatch_semaphore_wait(wait.sem, dispatchTime(answer_timeout)) != 0) return null;
    defer gpa.destroy(wait);
    defer objc.dispatch_release(@ptrCast(wait.sem));
    return wait.content;
}

fn findWindow(content: objc.Object, id: u32) ?objc.Object {
    const list = objc.msg(objc.Object, content, "windows", .{});
    for (0..objc.msg(usize, list, "count", .{})) |i| {
        const w = objc.msg(objc.Object, list, "objectAtIndex:", .{i});
        if (objc.msg(u32, w, "windowID", .{}) == id) return w;
    }
    return null;
}

/// How much of `frame` lies in `other`, in square points.
pub fn overlap(frame: objc.CGRect, other: objc.CGRect) f64 {
    const w = @min(frame.origin.x + frame.size.width, other.origin.x + other.size.width) - @max(frame.origin.x, other.origin.x);
    const h = @min(frame.origin.y + frame.size.height, other.origin.y + other.size.height) - @max(frame.origin.y, other.origin.y);
    return if (w > 0 and h > 0) w * h else 0;
}

/// The display showing most of `frame`.
fn displayOf(content: objc.Object, frame: objc.CGRect) ?objc.Object {
    const list = objc.msg(objc.Object, content, "displays", .{});
    var best: ?objc.Object = null;
    var most: f64 = 0;
    for (0..objc.msg(usize, list, "count", .{})) |i| {
        const d = objc.msg(objc.Object, list, "objectAtIndex:", .{i});
        const shared = overlap(frame, objc.msg(objc.CGRect, d, "frame", .{}));
        if (shared > most) {
            most = shared;
            best = d;
        }
    }
    return best;
}

/// `frame` in the coordinates of a display at `display`.
pub fn inDisplay(frame: objc.CGRect, display: objc.CGRect) objc.CGRect {
    return .{ .origin = .{ .x = frame.origin.x - display.origin.x, .y = frame.origin.y - display.origin.y }, .size = frame.size };
}

fn grabWindow(gpa: std.mem.Allocator, id: u32, frame: cf.CGRect, max_size: u32) !?CGImageRef {
    const manager = objc_getClass("SCScreenshotManager");
    const shareable = objc_getClass("SCShareableContent");
    const modern = if (manager) |c| objc.msg(bool, c, "respondsToSelector:", .{objc.sel("captureImageWithFilter:configuration:completionHandler:")}) else false;
    if (!modern or shareable == null) return CGWindowListCreateImage(CGRectNull, list_including_window, id, image_bounds_ignore_framing);
    const content = try shareableContent(gpa, shareable.?) orelse return null;
    defer objc.release(content);
    const sc = findWindow(content, id) orelse return null;
    const rect: objc.CGRect = .{ .origin = .{ .x = frame.origin.x, .y = frame.origin.y }, .size = .{ .width = frame.size.width, .height = frame.size.height } };
    const config = objc.new("SCStreamConfiguration");
    defer objc.release(config);
    // Retina's pixels, unless that's more than the picture will keep.
    const longer = @max(frame.size.width, frame.size.height, 1);
    const scale = @min(2.0, @as(f64, @floatFromInt(max_size)) / longer);
    objc.msg(void, config, "setWidth:", .{@as(usize, @intFromFloat(@max(1, @round(frame.size.width * scale))))});
    objc.msg(void, config, "setHeight:", .{@as(usize, @intFromFloat(@max(1, @round(frame.size.height * scale))))});
    objc.msg(void, config, "setShowsCursor:", .{false});
    // On a display: that display with only this window on it, whatever is in
    // front, cut to its frame, so pixels map exactly to points. The window's own
    // filter widens to fit child windows (a floating orb, a popover) and shrinks
    // the picture, and its source rect isn't in one coordinate system. A window
    // off the displays (another Space) has only that filter.
    const display = if (objc.msg(bool, sc, "isOnScreen", .{})) displayOf(content, rect) else null;
    const filter = if (display) |d| blk: {
        objc.msg(void, config, "setSourceRect:", .{inDisplay(rect, objc.msg(objc.CGRect, d, "frame", .{}))});
        if (objc.msg(bool, config, "respondsToSelector:", .{objc.sel("setIncludeChildWindows:")}))
            objc.msg(void, config, "setIncludeChildWindows:", .{false});
        const only = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{sc});
        break :blk objc.msg(objc.Object, objc.alloc("SCContentFilter"), "initWithDisplay:includingWindows:", .{ d, only });
    } else objc.msg(objc.Object, objc.alloc("SCContentFilter"), "initWithDesktopIndependentWindow:", .{sc});
    defer objc.release(filter);
    const wait = try gpa.create(Wait);
    wait.* = .{ .sem = objc.dispatch_semaphore_create(0) };
    var block = objc.Block(Wait, &.{ ?*anyopaque, ?objc.Object }).init(wait, Wait.done);
    objc.msg(void, manager.?, "captureImageWithFilter:configuration:completionHandler:", .{ filter, config, @as(*anyopaque, @ptrCast(&block)) });
    if (objc.dispatch_semaphore_wait(wait.sem, dispatchTime(answer_timeout)) != 0) return null;
    defer gpa.destroy(wait);
    defer objc.dispatch_release(@ptrCast(wait.sem));
    return wait.image;
}

fn grab(gpa: std.mem.Allocator, rect: cf.CGRect) !?CGImageRef {
    const r: objc.CGRect = .{ .origin = .{ .x = rect.origin.x, .y = rect.origin.y }, .size = .{ .width = rect.size.width, .height = rect.size.height } };
    const cls = objc_getClass("SCScreenshotManager");
    const modern = if (cls) |c| objc.msg(bool, c, "respondsToSelector:", .{objc.sel("captureImageInRect:completionHandler:")}) else false;
    if (!modern) {
        // Below macOS 15.2: on screen windows, at the display's resolution.
        return CGWindowListCreateImage(rect, 1, 0, 0);
    }
    // On the heap: if ScreenCaptureKit never answers, its late answer
    // still has somewhere to go (left allocated, rare and small).
    const wait = try gpa.create(Wait);
    wait.* = .{ .sem = objc.dispatch_semaphore_create(0) };
    var block = objc.Block(Wait, &.{ ?*anyopaque, ?objc.Object }).init(wait, Wait.done);
    objc.msg(void, cls.?, "captureImageInRect:completionHandler:", .{ r, @as(*anyopaque, @ptrCast(&block)) });
    if (objc.dispatch_semaphore_wait(wait.sem, dispatchTime(answer_timeout)) != 0) return null;
    defer gpa.destroy(wait);
    defer objc.dispatch_release(@ptrCast(wait.sem));
    return wait.image;
}

extern "c" fn dispatch_time(when: u64, delta: i64) u64;
fn dispatchTime(ns: u64) u64 {
    return dispatch_time(0, @intCast(ns));
}

test "a window's place on its display" {
    const win: objc.CGRect = .{ .origin = .{ .x = 1500, .y = 100 }, .size = .{ .width = 400, .height = 300 } };
    const left: objc.CGRect = .{ .size = .{ .width = 1440, .height = 900 } };
    const right: objc.CGRect = .{ .origin = .{ .x = 1440 }, .size = .{ .width = 1920, .height = 1080 } };
    try std.testing.expectEqual(@as(f64, 0), overlap(win, left));
    try std.testing.expectEqual(@as(f64, 120000), overlap(win, right));
    const placed = inDisplay(win, right);
    try std.testing.expectEqual(@as(f64, 60), placed.origin.x);
    try std.testing.expectEqual(@as(f64, 100), placed.origin.y);
    try std.testing.expectEqual(@as(f64, 400), placed.size.width);
}
