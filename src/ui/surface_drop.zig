//! Drops from other apps onto the macOS surface: a drag's place while it
//! moves over the view, and the drop's links (files as file URLs) and text,
//! for one frame (`surface_events.zig` registers them).
const std = @import("std");
const objc = @import("../objc.zig");
const types = @import("types.zig");
const Surface = @import("surface.zig").Surface;

fn surfaceOf(obj: objc.Object) ?*Surface {
    return objc.getZig(Surface, obj);
}

/// Where a drag is, in view points.
fn dragPoint(s: *Surface, info: objc.Object) types.Point {
    return s.toView(objc.msg(objc.CGPoint, info, "draggingLocation", .{}));
}

/// A drag from another app moves over the view: a copy where a box takes drops.
pub fn draggingUpdated(obj: objc.Object, _: objc.SEL, info: objc.Object) callconv(.c) objc.NSUInteger {
    const s = surfaceOf(obj) orelse return 0;
    const tok = s.token();
    const p = dragPoint(s, info);
    s.ctx.input.drag_over = p;
    s.frame();
    if (!Surface.alive(tok)) return 0;
    return if (s.ctx.acceptsDropAt(p)) 1 else 0; // NSDragOperationCopy
}

pub fn draggingExited(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.ctx.input.drag_over = null;
    s.frame();
}

/// The drop: its links (files as file URLs) and text, for one frame.
pub fn performDragOperation(obj: objc.Object, _: objc.SEL, info: objc.Object) callconv(.c) objc.BOOL {
    const s = surfaceOf(obj) orelse return objc.NO;
    const pool = objc.Pool.push();
    defer pool.pop();
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const p = dragPoint(s, info);
    const pb = objc.msg(objc.Object, info, "draggingPasteboard", .{});
    const classes = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{objc.class("NSURL")});
    var urls: std.ArrayList([]const u8) = .empty;
    if (objc.msg(?objc.Object, pb, "readObjectsForClasses:options:", .{ classes, @as(?objc.Object, null) })) |arr| {
        const n = objc.msg(objc.NSUInteger, arr, "count", .{});
        for (0..n) |i| {
            const url = objc.msg(objc.Object, arr, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
            const str = a.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{}))) catch continue;
            urls.append(a, str) catch {};
        }
    }
    const text = a.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, pb, "stringForType:", .{objc.nsString("public.utf8-plain-text")}))) catch "";
    s.ctx.input.drag_over = null;
    s.ctx.input.drop = .{ .point = p, .urls = urls.items, .text = text };
    const tok = s.token();
    s.frame();
    if (!Surface.alive(tok)) return objc.NO;
    s.ctx.input.drop = null;
    return if (s.ctx.acceptsDropAt(p)) objc.YES else objc.NO;
}
