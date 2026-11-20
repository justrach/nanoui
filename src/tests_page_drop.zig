//! macOS AppKit NSDraggingDestination integration tests for `PageOptions.file_drop`
//! on hidden whole-window and docked WKWebView instances (no screen events).
const std = @import("std");
const testing = std.testing;
const objc = @import("objc.zig");
const nanoui = @import("nanoui.zig");
const ui = @import("ui/ui.zig");
const App = @import("app.zig").App;
const Window = @import("window.zig").Window;
const runFor = @import("platform.zig").runFor;

const DragMockData = struct {
    pasteboard: objc.Object,
    window: objc.Object,
    window_point: objc.CGPoint,
    count: usize,
};

fn mockPasteboard(obj: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    return objc.getZig(DragMockData, obj).?.pasteboard;
}

fn mockWindow(obj: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    return objc.getZig(DragMockData, obj).?.window;
}

fn mockLocation(obj: objc.Object, _: objc.SEL) callconv(.c) objc.CGPoint {
    return objc.getZig(DragMockData, obj).?.window_point;
}

fn mockMask(_: objc.Object, _: objc.SEL) callconv(.c) objc.NSUInteger {
    return 1 | 2 | 4 | 16;
}

fn mockSeq(_: objc.Object, _: objc.SEL) callconv(.c) objc.NSInteger {
    return 1;
}

fn mockCount(obj: objc.Object, _: objc.SEL) callconv(.c) objc.NSInteger {
    return @intCast(objc.getZig(DragMockData, obj).?.count);
}

fn mockNil(_: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    return null;
}

fn mockZeroInt(_: objc.Object, _: objc.SEL) callconv(.c) objc.NSInteger {
    return 0;
}

fn mockNo(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.NO;
}

fn mockNoopInt(_: objc.Object, _: objc.SEL, _: objc.NSInteger) callconv(.c) void {}
fn mockNoopBool(_: objc.Object, _: objc.SEL, _: objc.BOOL) callconv(.c) void {}
fn mockNoopPt(_: objc.Object, _: objc.SEL, _: objc.CGPoint) callconv(.c) void {}
fn mockPromised(_: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) ?objc.Object {
    return null;
}
fn mockEnum(_: objc.Object, _: objc.SEL, _: objc.NSUInteger, _: ?objc.Object, _: ?objc.Object, _: ?objc.Object, _: ?objc.Object) callconv(.c) void {}

fn mockClass() objc.Class {
    return objc.defineClass(.{
        .name = "NanoUITestDraggingInfo",
        .superclass = "NSObject",
        .methods = &.{
            .{ .name = "draggingPasteboard", .imp = &mockPasteboard, .types = "@@:" },
            .{ .name = "draggingDestinationWindow", .imp = &mockWindow, .types = "@@:" },
            .{ .name = "draggingLocation", .imp = &mockLocation, .types = "{CGPoint=dd}@:" },
            .{ .name = "draggingSourceOperationMask", .imp = &mockMask, .types = "Q@:" },
            .{ .name = "draggingSequenceNumber", .imp = &mockSeq, .types = "q@:" },
            .{ .name = "numberOfValidItemsForDrop", .imp = &mockCount, .types = "q@:" },
            .{ .name = "draggingSource", .imp = &mockNil, .types = "@@:" },
            .{ .name = "draggingFormation", .imp = &mockZeroInt, .types = "q@:" },
            .{ .name = "setDraggingFormation:", .imp = &mockNoopInt, .types = "v@:q" },
            .{ .name = "animatesToDestination", .imp = &mockNo, .types = "c@:" },
            .{ .name = "setAnimatesToDestination:", .imp = &mockNoopBool, .types = "v@:c" },
            .{ .name = "springLoadingHighlight", .imp = &mockZeroInt, .types = "q@:" },
            .{ .name = "setNumberOfValidItemsForDrop:", .imp = &mockNoopInt, .types = "v@:q" },
            .{ .name = "slideDraggedImageTo:", .imp = &mockNoopPt, .types = "v@:{CGPoint=dd}" },
            .{ .name = "namesOfPromisedFilesDroppedAtDestination:", .imp = &mockPromised, .types = "@@:@" },
            .{ .name = "enumerateDraggingItemsWithOptions:forView:classes:searchOptions:usingBlock:", .imp = &mockEnum, .types = "v@:Q@@@@?" },
        },
    });
}

fn makeFilePasteboard(paths: []const []const u8) objc.Object {
    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "pasteboardWithUniqueName", .{});
    const arr = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for (paths) |p| {
        const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(p)});
        objc.msg(void, arr, "addObject:", .{url});
    }
    _ = objc.msg(objc.NSInteger, pb, "clearContents", .{});
    _ = objc.msg(objc.BOOL, pb, "writeObjects:", .{arr});
    return pb;
}

fn winPointForViewTopLeft(view: objc.Object, tx: f64, ty: f64) objc.CGPoint {
    const bounds = objc.msg(objc.CGRect, view, "bounds", .{});
    const flipped = objc.msg(objc.BOOL, view, "isFlipped", .{});
    const vy = if (flipped) ty else bounds.size.height - ty;
    return objc.msg(objc.CGPoint, view, "convertPoint:toView:", .{ objc.CGPoint{ .x = tx, .y = vy }, @as(?objc.Object, null) });
}

fn makeHiddenApp(gpa: std.mem.Allocator) !*App {
    const app = try gpa.create(App);
    app.* = .{
        .gpa = gpa,
        .io = testing.io,
        .options = .{ .quit_on_last_window_closed = false },
        .nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{}),
        .delegate = objc.msg(objc.Object, objc.class("NSObject"), "new", .{}),
        .flags = .{ .hidden = true },
    };
    return app;
}

fn freeApp(app: *App) void {
    while (app.windows.items.len > 0) app.windows.items[app.windows.items.len - 1].close();
    runFor(0.05);
    @import("ui/surface_wake.zig").sweep();
    app.windows.deinit(app.gpa);
    objc.release(app.delegate);
    app.gpa.destroy(app);
}

const DropCapture = struct {
    gpa: std.mem.Allocator,
    mode: nanoui.PageDropDecision = .host,
    close_on_drop: ?*Window = null,
    offers: usize = 0,
    drops: usize = 0,
    cancels: usize = 0,
    last_x: f64 = 0,
    last_y: f64 = 0,
    copied_urls: std.ArrayList([]u8) = .empty,

    fn deinit(self: *DropCapture) void {
        for (self.copied_urls.items) |u| self.gpa.free(u);
        self.copied_urls.deinit(self.gpa);
    }

    fn onOffer(ctx: ?*anyopaque, offer: nanoui.PageDropOffer) nanoui.PageDropDecision {
        const self: *DropCapture = @ptrCast(@alignCast(ctx));
        self.offers += 1;
        self.last_x = offer.x;
        self.last_y = offer.y;
        return self.mode;
    }

    fn onDrop(ctx: ?*anyopaque, ev: nanoui.PageDropEvent) bool {
        const self: *DropCapture = @ptrCast(@alignCast(ctx));
        self.drops += 1;
        self.last_x = ev.x;
        self.last_y = ev.y;
        for (self.copied_urls.items) |u| self.gpa.free(u);
        self.copied_urls.clearRetainingCapacity();
        for (ev.urls) |u| {
            const copy = self.gpa.dupe(u8, u) catch continue;
            self.copied_urls.append(self.gpa, copy) catch self.gpa.free(copy);
        }
        if (self.close_on_drop) |w| {
            self.close_on_drop = null;
            w.close();
        }
        return true;
    }

    fn onCancel(ctx: ?*anyopaque) void {
        const self: *DropCapture = @ptrCast(@alignCast(ctx));
        self.cancels += 1;
    }
};

const html_asset = [_]nanoui.Asset{
    .{ .path = "/index.html", .data = "<!doctype html><body>drop</body>" },
    .{ .path = "/next.html", .data = "<!doctype html><body>next</body>" },
};

test "webview default pass-through leaves drops unhandled by host callbacks" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const gpa = testing.allocator;
    const app = try makeHiddenApp(gpa);
    defer freeApp(app);

    const win = try app.newWindow(.{
        .width = 480,
        .height = 360,
        .content = .{ .page = .{ .url = "/index.html", .assets = &html_asset, .private = true } },
    });
    const pg = win.page.?;
    const pb = makeFilePasteboard(&.{"/tmp/nanoui-default-pass.txt"});
    defer objc.msg(void, pb, "releaseGlobally", .{});

    var data: DragMockData = .{
        .pasteboard = pb,
        .window = win.nswindow,
        .window_point = winPointForViewTopLeft(pg.webview, 20, 30),
        .count = 1,
    };
    const info = objc.msg(objc.Object, mockClass(), "new", .{});
    defer objc.release(info);
    objc.setZig(info, &data);

    _ = objc.msg(objc.NSUInteger, pg.webview, "draggingEntered:", .{info});
    objc.msg(void, pg.webview, "draggingExited:", .{info});
}

test "webview host consumption, rejection, webview routing, navigation cancel, and reentrant close" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const gpa = testing.allocator;
    const app = try makeHiddenApp(gpa);
    defer freeApp(app);

    var cap: DropCapture = .{ .gpa = gpa };
    defer cap.deinit();

    const win = try app.newWindow(.{
        .width = 500,
        .height = 400,
        .content = .{ .page = .{
            .url = "/index.html",
            .assets = &html_asset,
            .private = true,
            .file_drop = .{
                .ctx = &cap,
                .on_offer = DropCapture.onOffer,
                .on_drop = DropCapture.onDrop,
                .on_cancel = DropCapture.onCancel,
            },
        } },
    });
    const pg = win.page.?;
    const pb = makeFilePasteboard(&.{ "/tmp/fixture-one.txt", "/tmp/caf\xc3\xa9 file.png" });
    defer objc.msg(void, pb, "releaseGlobally", .{});

    var data: DragMockData = .{
        .pasteboard = pb,
        .window = win.nswindow,
        .window_point = winPointForViewTopLeft(pg.webview, 75, 110),
        .count = 2,
    };
    const info = objc.msg(objc.Object, mockClass(), "new", .{});
    defer objc.release(info);
    objc.setZig(info, &data);

    // 1. Host consumption: enter + update -> 1 delivery, top-left coords & owned URL copies.
    cap.mode = .host;
    try testing.expectEqual(@as(objc.NSUInteger, 1), objc.msg(objc.NSUInteger, pg.webview, "draggingEntered:", .{info}));
    try testing.expectEqual(@as(objc.NSUInteger, 1), objc.msg(objc.NSUInteger, pg.webview, "draggingUpdated:", .{info}));
    try testing.expectEqual(objc.YES, objc.msg(objc.BOOL, pg.webview, "prepareForDragOperation:", .{info}));
    try testing.expectEqual(objc.YES, objc.msg(objc.BOOL, pg.webview, "performDragOperation:", .{info}));
    objc.msg(void, pg.webview, "concludeDragOperation:", .{info});
    try testing.expectEqual(@as(usize, 1), cap.drops);
    try testing.expectEqual(@as(usize, 2), cap.copied_urls.items.len);
    try testing.expectApproxEqAbs(75.0, cap.last_x, 1e-3);
    try testing.expectApproxEqAbs(110.0, cap.last_y, 1e-3);
    // Duplicate performDragOperation does not deliver twice.
    try testing.expectEqual(objc.NO, objc.msg(objc.BOOL, pg.webview, "performDragOperation:", .{info}));
    try testing.expectEqual(@as(usize, 1), cap.drops);

    // 2. Reject returns 0/NO cleanly without calling on_drop.
    cap.mode = .reject;
    try testing.expectEqual(@as(objc.NSUInteger, 0), objc.msg(objc.NSUInteger, pg.webview, "draggingEntered:", .{info}));
    try testing.expectEqual(objc.NO, objc.msg(objc.BOOL, pg.webview, "prepareForDragOperation:", .{info}));
    try testing.expectEqual(objc.NO, objc.msg(objc.BOOL, pg.webview, "performDragOperation:", .{info}));
    try testing.expectEqual(@as(usize, 1), cap.drops);
    try testing.expectEqual(@as(usize, 1), cap.cancels);

    // 3. Navigation cancels active offer and refuses subsequent drop.
    cap.mode = .host;
    try testing.expectEqual(@as(objc.NSUInteger, 1), objc.msg(objc.NSUInteger, pg.webview, "draggingEntered:", .{info}));
    win.setPageUrl("/next.html");
    try testing.expectEqual(@as(usize, 2), cap.cancels);
    try testing.expectEqual(objc.NO, objc.msg(objc.BOOL, pg.webview, "performDragOperation:", .{info}));
    try testing.expectEqual(@as(usize, 1), cap.drops);

    // 4. `.webview` decision declines host drop (hands off cleanly).
    cap.mode = .webview;
    _ = objc.msg(objc.NSUInteger, pg.webview, "draggingEntered:", .{info});
    objc.msg(void, pg.webview, "draggingExited:", .{info});
    try testing.expectEqual(@as(usize, 1), cap.drops);

    // 5. Reentrant window.close() inside on_drop completes safely without UAF or leak.
    cap.mode = .host;
    cap.close_on_drop = win;
    try testing.expectEqual(@as(objc.NSUInteger, 1), objc.msg(objc.NSUInteger, pg.webview, "draggingEntered:", .{info}));
    try testing.expectEqual(objc.YES, objc.msg(objc.BOOL, pg.webview, "performDragOperation:", .{info}));
    try testing.expectEqual(@as(usize, 2), cap.drops);
}

const DockDropHost = struct {
    native_drops: usize = 0,
    page: ?*nanoui.Page = null,

    fn view(self: *DockDropHost, c: *ui.Context) void {
        const root = ui.div(c).row().sizeFull();
        defer root.end();
        const left = ui.div(c).w(150).h(300);
        c.acceptDrop(left.index);
        if (c.dropAt(left.index) != null) self.native_drops += 1;
        left.end();
        ui.div(c).w(350).h(300).end();
    }
};

test "docked page vs native region hit-testing and view-local top-left coordinates" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const gpa = testing.allocator;
    const app = try makeHiddenApp(gpa);
    defer freeApp(app);

    var host: DockDropHost = .{};
    const win = try app.newWindow(.{
        .width = 500,
        .height = 300,
        .content = .{ .view = ui.View.init(&host, DockDropHost.view) },
    });
    var cap: DropCapture = .{ .gpa = gpa };
    defer cap.deinit();

    const pg = try win.dockPage(.{
        .parent = win.surface.?.nativeHandle(),
        .url = "/index.html",
        .assets = &html_asset,
        .private = true,
        .file_drop = .{
            .ctx = &cap,
            .on_offer = DropCapture.onOffer,
            .on_drop = DropCapture.onDrop,
        },
    });
    pg.setFrame(150, 0, 350, 300);
    runFor(0.02);

    const surf_view: objc.Object = @ptrCast(win.surface.?.nativeHandle().?);
    const super = objc.msg(?objc.Object, surf_view, "superview", .{});
    const pt_native = objc.msg(objc.CGPoint, surf_view, "convertPoint:toView:", .{ objc.CGPoint{ .x = 40, .y = 50 }, super });
    const pt_page = objc.msg(objc.CGPoint, surf_view, "convertPoint:toView:", .{ objc.CGPoint{ .x = 200, .y = 50 }, super });
    const in_native = objc.msg(?objc.Object, surf_view, "hitTest:", .{pt_native});
    const in_page = objc.msg(?objc.Object, surf_view, "hitTest:", .{pt_page});
    try testing.expect(in_native != null and @intFromPtr(in_native.?) == @intFromPtr(surf_view));
    try testing.expect(in_page != null and @intFromPtr(in_page.?) != @intFromPtr(surf_view));

    const pb = makeFilePasteboard(&.{"/tmp/docked-drop.txt"});
    defer objc.msg(void, pb, "releaseGlobally", .{});
    var data: DragMockData = .{
        .pasteboard = pb,
        .window = win.nswindow,
        .window_point = winPointForViewTopLeft(pg.webview, 33, 44),
        .count = 1,
    };
    const info = objc.msg(objc.Object, mockClass(), "new", .{});
    defer objc.release(info);
    objc.setZig(info, &data);

    try testing.expectEqual(@as(objc.NSUInteger, 1), objc.msg(objc.NSUInteger, pg.webview, "draggingEntered:", .{info}));
    try testing.expectEqual(objc.YES, objc.msg(objc.BOOL, pg.webview, "performDragOperation:", .{info}));
    try testing.expectEqual(@as(usize, 1), cap.drops);
    // Coordinates are relative to docked webview, NOT the outer native window (which starts at x=150).
    try testing.expectApproxEqAbs(33.0, cap.last_x, 1e-3);
    try testing.expectApproxEqAbs(44.0, cap.last_y, 1e-3);
}
