//! AppKit NSDraggingDestination interception and view-local top-left coordinate
//! normalization for `NanoUIWebView` (`page_webkit.zig`), forwarding `.webview`
//! decisions directly to WKWebView while routing `.host` and `.reject` cleanly.
const std = @import("std");
const objc = @import("objc.zig");
const page_drop = @import("page_drop.zig");
const Page = @import("page_webkit.zig").Page;

const drag_copy: objc.NSUInteger = 1;
const drag_none: objc.NSUInteger = 0;

pub const methods = [_]objc.Method{
    .{ .name = "draggingEntered:", .imp = &draggingEntered, .types = "Q@:@" },
    .{ .name = "draggingUpdated:", .imp = &draggingUpdated, .types = "Q@:@" },
    .{ .name = "draggingExited:", .imp = &draggingExited, .types = "v@:@" },
    .{ .name = "prepareForDragOperation:", .imp = &prepareForDragOperation, .types = "c@:@" },
    .{ .name = "performDragOperation:", .imp = &performDragOperation, .types = "c@:@" },
    .{ .name = "concludeDragOperation:", .imp = &concludeDragOperation, .types = "v@:@" },
};

/// Preserves WKWebView's existing dragged types while ensuring `public.file-url`
/// is registered whenever host file drops are opted in.
pub fn registerTypes(webview: objc.Object, enabled: bool) void {
    if (!enabled) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const set = objc.msg(objc.Object, objc.class("NSMutableSet"), "set", .{});
    if (objc.msg(?objc.Object, webview, "registeredDraggedTypes", .{})) |existing| {
        objc.msg(void, set, "addObjectsFromArray:", .{existing});
    }
    objc.msg(void, set, "addObject:", .{objc.nsString("public.file-url")});
    objc.msg(void, set, "addObject:", .{objc.nsString("NSFilenamesPboardType")});
    const all = objc.msg(objc.Object, set, "allObjects", .{});
    objc.msg(void, webview, "registerForDraggedTypes:", .{all});
}

fn pageOf(obj: objc.Object) ?*Page {
    const p = objc.getZig(Page, obj) orelse return null;
    return if (p.queue.dead) null else p;
}

fn wkSuper() objc.Class {
    return objc.class("WKWebView");
}

fn respondsSuper(comptime selector: [:0]const u8) bool {
    return objc.msg(objc.BOOL, wkSuper(), "instancesRespondToSelector:", .{objc.sel(selector)});
}

fn superDragMask(obj: objc.Object, comptime selector: [:0]const u8, info: objc.Object) objc.NSUInteger {
    if (!respondsSuper(selector)) return drag_none;
    return objc.msgSuper(objc.NSUInteger, obj, wkSuper(), selector, .{info});
}

fn superBool(obj: objc.Object, comptime selector: [:0]const u8, info: objc.Object) objc.BOOL {
    if (!respondsSuper(selector)) return objc.NO;
    return objc.msgSuper(objc.BOOL, obj, wkSuper(), selector, .{info});
}

fn superVoid(obj: objc.Object, comptime selector: [:0]const u8, info: ?objc.Object) void {
    if (!respondsSuper(selector)) return;
    objc.msgSuper(void, obj, wkSuper(), selector, .{info});
}

/// View-local top-left logical point independent of window/backing DPI scale.
fn localTopLeft(obj: objc.Object, info: objc.Object) struct { x: f64, y: f64 } {
    const win_pt = objc.msg(objc.CGPoint, info, "draggingLocation", .{});
    const local = objc.msg(objc.CGPoint, obj, "convertPoint:fromView:", .{ win_pt, @as(?objc.Object, null) });
    const bounds = objc.msg(objc.CGRect, obj, "bounds", .{});
    const flipped = objc.msg(objc.BOOL, obj, "isFlipped", .{});
    const pt = page_drop.toTopLeft(@floatCast(local.x), @floatCast(local.y), @floatCast(bounds.size.height), flipped);
    return .{ .x = pt.x, .y = pt.y };
}

/// Extracts `file://` URLs from `draggingPasteboard` using `NSPasteboardURLReadingFileURLsOnlyKey`.
pub fn readFileUrls(gpa: std.mem.Allocator, info: objc.Object) []const []const u8 {
    const pb = objc.msg(?objc.Object, info, "draggingPasteboard", .{}) orelse return &.{};
    const classes = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{objc.class("NSURL")});
    const key = objc.nsString("NSPasteboardURLReadingFileURLsOnlyKey");
    const yes_num = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES});
    const opts = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ yes_num, key });
    const arr = objc.msg(?objc.Object, pb, "readObjectsForClasses:options:", .{ classes, opts }) orelse return &.{};
    const n = objc.msg(objc.NSUInteger, arr, "count", .{});
    var urls: std.ArrayList([]const u8) = .empty;
    for (0..n) |i| {
        const url = objc.msg(objc.Object, arr, "objectAtIndex:", .{i});
        if (!objc.msg(objc.BOOL, url, "isFileURL", .{})) continue;
        const raw = objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{}));
        if (!page_drop.startsWithFileScheme(raw) or raw.len <= "file://".len) continue;
        const dup = gpa.dupe(u8, raw) catch continue;
        urls.append(gpa, dup) catch gpa.free(dup);
    }
    return urls.toOwnedSlice(gpa) catch &.{};
}

fn handleOffer(obj: objc.Object, comptime selector: [:0]const u8, info: objc.Object, phase: page_drop.Phase) objc.NSUInteger {
    const p = pageOf(obj) orelse return superDragMask(obj, selector, info);
    if (!p.drop_session.isEnabled()) return superDragMask(obj, selector, info);
    const pool = objc.Pool.push();
    defer pool.pop();
    var arena: std.heap.ArenaAllocator = .init(p.queue.gpa);
    defer arena.deinit();
    const urls = readFileUrls(arena.allocator(), info);
    const pt = localTopLeft(obj, info);
    p.enterDrop();
    defer p.leaveDrop();
    const dec = p.drop_session.onOffer(phase, pt.x, pt.y, urls, urls.len > 0);
    if (p.queue.dead) return drag_none;
    return switch (dec) {
        .host => drag_copy,
        .reject => drag_none,
        .webview => superDragMask(obj, selector, info),
    };
}

fn draggingEntered(obj: objc.Object, _: objc.SEL, info: objc.Object) callconv(.c) objc.NSUInteger {
    return handleOffer(obj, "draggingEntered:", info, .enter);
}

fn draggingUpdated(obj: objc.Object, _: objc.SEL, info: objc.Object) callconv(.c) objc.NSUInteger {
    return handleOffer(obj, "draggingUpdated:", info, .update);
}

fn draggingExited(obj: objc.Object, _: objc.SEL, info: ?objc.Object) callconv(.c) void {
    const p = pageOf(obj) orelse return superVoid(obj, "draggingExited:", info);
    if (!p.drop_session.isEnabled() or !p.drop_session.active) return superVoid(obj, "draggingExited:", info);
    const prev_dec = p.drop_session.decision;
    p.enterDrop();
    defer p.leaveDrop();
    p.drop_session.onExit();
    if (!p.queue.dead and prev_dec == .webview) superVoid(obj, "draggingExited:", info);
}

fn prepareForDragOperation(obj: objc.Object, _: objc.SEL, info: objc.Object) callconv(.c) objc.BOOL {
    const p = pageOf(obj) orelse return superBool(obj, "prepareForDragOperation:", info);
    if (!p.drop_session.isEnabled() or !p.drop_session.active) return superBool(obj, "prepareForDragOperation:", info);
    return switch (p.drop_session.decision) {
        .host => objc.YES,
        .reject => objc.NO,
        .webview => superBool(obj, "prepareForDragOperation:", info),
    };
}

fn performDragOperation(obj: objc.Object, _: objc.SEL, info: objc.Object) callconv(.c) objc.BOOL {
    const p = pageOf(obj) orelse return superBool(obj, "performDragOperation:", info);
    if (!p.drop_session.isEnabled()) return superBool(obj, "performDragOperation:", info);
    if (!p.drop_session.active) {
        p.last_drop_webview = false;
        p.drop_session.active_epoch = 0;
        return objc.NO;
    }
    switch (p.drop_session.decision) {
        .reject => {
            p.last_drop_webview = false;
            p.enterDrop();
            defer p.leaveDrop();
            p.drop_session.onExit();
            return objc.NO;
        },
        .webview => {
            p.last_drop_webview = true;
            p.drop_session.finishWebviewDrop();
            return superBool(obj, "performDragOperation:", info);
        },
        .host => {
            p.last_drop_webview = false;
            const pool = objc.Pool.push();
            defer pool.pop();
            var arena: std.heap.ArenaAllocator = .init(p.queue.gpa);
            defer arena.deinit();
            const urls = readFileUrls(arena.allocator(), info);
            const pt = localTopLeft(obj, info);
            p.enterDrop();
            defer p.leaveDrop();
            const ok = p.drop_session.deliverDrop(null, pt.x, pt.y, urls);
            return if (ok) objc.YES else objc.NO;
        },
    }
}

fn concludeDragOperation(obj: objc.Object, _: objc.SEL, info: ?objc.Object) callconv(.c) void {
    const p = pageOf(obj) orelse return superVoid(obj, "concludeDragOperation:", info);
    if (!p.drop_session.isEnabled() or p.last_drop_webview) {
        superVoid(obj, "concludeDragOperation:", info);
    }
    p.last_drop_webview = true;
}
