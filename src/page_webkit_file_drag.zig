//! An AppKit source for a page's copy-only offers of prepared file URLs.
//! AppKit and this module's state are used on the main thread.
const std = @import("std");
const objc = @import("objc.zig");
const drag = @import("window_types.zig").PageFileDrag;

const copy = 1;
const max_files = 64;

pub const Slot = struct {
    active: ?*Session = null,

    pub fn detach(slot: *Slot) void {
        if (slot.active) |session| session.owner = null;
        slot.active = null;
    }

    pub fn start(slot: *Slot, view: objc.Object, event: objc.Object, offer: drag) !void {
        if (slot.active != null) return error.FileDragBusy;
        try validatePaths(offer.paths);
        const window = objc.msg(?objc.Object, view, "window", .{}) orelse return error.NoFileDragGesture;
        const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        if (objc.msg(objc.BOOL, app, "isActive", .{}) == objc.NO or
            objc.msg(?objc.Object, event, "window", .{}) != window or
            objc.msg(objc.NSUInteger, event, "type", .{}) != 1 or
            objc.msg(objc.BOOL, window, "isKeyWindow", .{}) == objc.NO or
            objc.msg(objc.NSUInteger, objc.class("NSEvent"), "pressedMouseButtons", .{}) & 1 == 0)
            return error.NoFileDragGesture;

        const pool = objc.Pool.push();
        defer pool.pop();
        const items = objc.msg(objc.Object, objc.class("NSMutableArray"), "arrayWithCapacity:", .{offer.paths.len});
        const location = objc.msg(objc.CGPoint, event, "locationInWindow", .{});
        const point = objc.msg(objc.CGPoint, view, "convertPoint:fromView:", .{ location, @as(?objc.Object, null) });
        for (offer.paths) |path| {
            const name = objc.nsString(path);
            const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{name});
            const item = objc.msg(objc.Object, objc.alloc("NSDraggingItem"), "initWithPasteboardWriter:", .{url});
            defer objc.release(item);
            const workspace = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
            const icon = objc.msg(objc.Object, workspace, "iconForFile:", .{name});
            const frame: objc.CGRect = .{ .origin = point, .size = .{ .width = 48, .height = 48 } };
            objc.msg(void, item, "setDraggingFrame:contents:", .{ frame, icon });
            objc.msg(void, items, "addObject:", .{item});
        }

        const state = try std.heap.c_allocator.create(Session);
        state.* = .{ .owner = slot, .token = offer.token, .ctx = offer.ctx, .on_end = offer.on_end };
        const source = objc.msg(objc.Object, sourceClass(), "new", .{});
        // One reference stays with the callback, and one keeps the receiver
        // alive until begin returns (even if AppKit ends it inline).
        _ = objc.retain(source);
        defer objc.release(source);
        objc.setZig(source, state);
        slot.active = state;
        _ = objc.retain(view);
        defer objc.release(view);
        _ = objc.retain(event);
        defer objc.release(event);
        const session = objc.msg(?objc.Object, view, "beginDraggingSessionWithItems:event:source:", .{ items, event, source });
        if (session == null) {
            if (objc.getZig(Session, source)) |unstarted| {
                _ = unstarted.complete();
                objc.setZig(source, null);
                std.heap.c_allocator.destroy(unstarted);
                objc.release(source);
                return error.FileDragNotStarted;
            }
        }
    }
};

const Session = struct {
    owner: ?*Slot,
    token: u64,
    ctx: ?*anyopaque,
    on_end: drag.End,

    /// Release the slot before app code runs, so it can close the page or
    /// start another offer without reaching this session.
    fn complete(state: *Session) bool {
        const owner = state.owner orelse return false;
        owner.active = null;
        state.owner = null;
        return true;
    }
};

fn validatePaths(paths: []const []const u8) !void {
    if (paths.len == 0 or paths.len > max_files) return error.FileDragCount;
    for (paths) |path| {
        if (path.len < 2 or path.len >= std.Io.Dir.max_path_bytes or path[0] != '/' or
            std.mem.indexOfScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path))
            return error.InvalidFileDragPath;
    }
}

fn sourceClass() objc.Class {
    return objc.defineClass(.{
        .name = "NanoUIPageFileDragSource",
        .protocols = &.{"NSDraggingSource"},
        .methods = &.{
            .{ .name = "draggingSession:sourceOperationMaskForDraggingContext:", .imp = &operationMask, .types = "Q@:@q" },
            .{ .name = "draggingSession:endedAtPoint:operation:", .imp = &ended, .types = "v@:@{CGPoint=dd}Q" },
        },
    });
}

fn operationMask(_: objc.Object, _: objc.SEL, _: objc.Object, _: objc.NSInteger) callconv(.c) objc.NSUInteger {
    return copy;
}

fn ended(source: objc.Object, _: objc.SEL, _: objc.Object, _: objc.CGPoint, operation: objc.NSUInteger) callconv(.c) void {
    const state = objc.getZig(Session, source) orelse return;
    objc.setZig(source, null);
    defer std.heap.c_allocator.destroy(state);
    defer objc.release(source);
    if (state.complete()) state.on_end(state.ctx, state.token, if (operation & copy != 0) .copied else .cancelled);
}

test "outbound page file drag rejects an invalid batch before AppKit" {
    try validatePaths(&.{ "/tmp/one file.epub", "/tmp/資料.epub" });
    try std.testing.expectError(error.FileDragCount, validatePaths(&.{}));
    try std.testing.expectError(error.InvalidFileDragPath, validatePaths(&.{ "/tmp/ok", "relative" }));
    try std.testing.expectError(error.InvalidFileDragPath, validatePaths(&.{"/tmp/a\x00b"}));
}

test "outbound page file drag clears the owner once and ignores a late result" {
    const cb = struct {
        fn done(_: ?*anyopaque, _: u64, _: drag.Result) void {}
    }.done;
    var slot: Slot = .{};
    var session: Session = .{ .owner = &slot, .ctx = null, .token = 1, .on_end = cb };
    slot.active = &session;
    try std.testing.expect(session.complete());
    try std.testing.expect(slot.active == null);
    try std.testing.expect(!session.complete());
    session.owner = &slot;
    slot.active = &session;
    slot.detach();
    try std.testing.expect(slot.active == null);
    try std.testing.expect(!session.complete());
}

test "outbound page file drag does not start without an armed page gesture" {
    const Page = @import("page_webkit.zig").Page;
    var page: Page = undefined;
    page.queue.dead = false;
    page.file_drag_monitor = null;
    try std.testing.expectError(error.NoFileDragGesture, page.startFileDrag(.{
        .paths = &.{"/tmp/prepared.epub"},
        .token = 1,
        .on_end = struct {
            fn done(_: ?*anyopaque, _: u64, _: drag.Result) void {
                unreachable;
            }
        }.done,
    }));
}
