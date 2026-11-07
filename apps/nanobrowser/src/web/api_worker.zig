//! `new Worker`: a page with no window and no one to draw it, whose scripts have a
//! global of their own. Everything scripts can do there already works the way it
//! does on a page: timers, `fetch`, `crypto`.
//!
//! It runs on the UI thread, a turn at a time among the page's, so a worker that
//! computes for a long time holds the window up. That's the honest cost of having
//! one VM per thread and one thread: what it gets right is everything a script
//! can see of a worker, which is what sites need of it. The script side is in
//! `prelude_worker.js`.
const std = @import("std");
const nanoui = @import("nanoui");
const js = @import("../js/js.zig");
const bind = @import("bind.zig");
const Page = @import("../page.zig").Page;
const Value = js.Value;
const Vm = js.Vm;
const Error = js.Error;

/// So many workers under one page; past them `new Worker` throws.
const max_workers = 16;

pub const Worker = struct {
    id: u32,
    owner: *Page,
    page: *Page,
    /// What its first script is to run: `prelude_worker.js`'s, as one string.
    source: []const u8 = "",
};

var next_id: u32 = 1;

fn from(ctx: *anyopaque) *Worker {
    return @ptrCast(@alignCast(ctx));
}

fn noNavigate(_: *anyopaque, _: *Page, _: Page.Navigation) void {}
fn noRedraw(_: *anyopaque) void {}
fn noLoaded(_: *anyopaque, _: *Page) void {}
fn noUi(_: *anyopaque) ?*nanoui.ui.Context {
    return null;
}
fn noViewport(_: *anyopaque) [2]f32 {
    return .{ 0, 0 };
}
fn noUrl(_: *anyopaque, _: *Page, _: bool) void {}
fn noHistory(_: *anyopaque, _: *Page, _: i32) void {}
fn retire(ctx: *anyopaque, page: *Page) void {
    const o = from(ctx).owner;
    o.host.retire(o.host.ctx, page);
}

fn find(p: *const Page, id: i64) ?*Worker {
    for (p.workers.items) |x| if (x.id == id) return x;
    return null;
}

fn end(p: *Page, x: *Worker) void {
    for (p.workers.items, 0..) |y, i| if (y == x) {
        _ = p.workers.orderedRemove(i);
        break;
    };
    x.page.destroy();
    p.gpa.free(x.source);
    p.gpa.destroy(x);
}

/// A dying page's workers go with it.
pub fn destroyAll(p: *Page) void {
    while (p.workers.items.len > 0) end(p, p.workers.items[p.workers.items.len - 1]);
    p.workers.deinit(p.gpa);
    p.workers = .empty;
}

/// `$.workerNew(url)`: its number; `url` is where it says it is.
fn workerNew(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const o = bind.world(vm).page;
    if (o.workers.items.len >= max_workers) return bind.throwDom(vm, "NotSupportedError", "Too many workers on this page.");
    const url = try bind.str(vm, args, 0);
    const gpa = o.gpa;
    const x = try gpa.create(Worker);
    errdefer gpa.destroy(x);
    const child = Page.create(gpa, .{ .ctx = x, .navigate = noNavigate, .redraw = noRedraw, .loaded = noLoaded, .uiContext = noUi, .viewport = noViewport, .urlChanged = noUrl, .history = noHistory, .retire = retire }) catch return error.OutOfMemory;
    x.* = .{ .id = next_id, .owner = o, .page = child };
    next_id += 1;
    child.worker = x;
    child.dark = o.dark;
    child.final_url = try gpa.dupe(u8, url);
    child.doc.url = child.final_url;
    try o.workers.append(gpa, x);
    return Value.fromUsize(x.id);
}

/// `$.workerBoot(id, html, source)`: the document that loads its scripts, and what
/// its last script is to run.
fn workerBoot(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const o = bind.world(vm).page;
    const x = find(o, bind.arg(args, 0).asInt()) orelse return Value.undefined;
    x.source = try o.gpa.dupe(u8, try bind.str(vm, args, 2));
    const url = try o.gpa.dupe(u8, x.page.final_url);
    defer o.gpa.free(url);
    x.page.documentArrived(200, try bind.str(vm, args, 1), url, "text/html", "");
    return Value.undefined;
}

/// `$.workerPost(id, text)` from the page, `$.workerPost(0, text)` from the worker:
/// a turn of the other side's, the same way a timer is.
fn workerPost(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const to_owner = w.page.worker;
    const id: u32 = if (to_owner) |x| x.id else @intCast(@max(0, bind.arg(args, 0).asInt()));
    const target: *Page = if (bind.arg(args, 0).asInt() == 0) (if (to_owner) |x| x.owner else return Value.undefined) else if (find(w.page, bind.arg(args, 0).asInt())) |x| x.page else return Value.undefined;
    if (target.dead) return Value.undefined;
    const tw = target.js orelse return Value.undefined;
    if (!tw.h.workerMessage.isCallable()) return Value.undefined;
    const text = try tw.vm.newString(try bind.str(vm, args, 1));
    _ = try tw.timers.add(tw, tw.h.workerMessage, 0, &.{ Value.fromUsize(id), text }, false);
    return Value.undefined;
}

/// `$.workerEnd(id)`: `terminate()`. `$.workerEnd(0)`: its own `close()`.
fn workerEnd(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const id = bind.arg(args, 0).asInt();
    if (id == 0) {
        // Not while its own script runs: the owner takes it down in a turn of its own.
        const x = w.page.worker orelse return Value.undefined;
        const tw = x.owner.js orelse return Value.undefined;
        if (!tw.h.workerMessage.isCallable()) return Value.undefined;
        const text = try tw.vm.newString("#");
        _ = try tw.timers.add(tw, tw.h.workerMessage, 0, &.{ Value.fromUsize(x.id), text }, false);
        return Value.undefined;
    }
    if (find(w.page, id)) |x| end(w.page, x);
    return Value.undefined;
}

/// `$.workerSelf()`: whether this page is a worker's.
fn workerSelf(vm: *Vm, _: Value, _: []const Value) Error!Value {
    return Value.fromBool(bind.world(vm).page.worker != null);
}

/// `$.workerSource()`: what `workerBoot` was given.
fn workerSource(vm: *Vm, _: Value, _: []const Value) Error!Value {
    const x = bind.world(vm).page.worker orelse return Value.undefined;
    return vm.newString(x.source);
}

pub const internals = [_]bind.Method{
    .{ .name = "workerNew", .arity = 1, .f = workerNew },
    .{ .name = "workerBoot", .arity = 3, .f = workerBoot },
    .{ .name = "workerPost", .arity = 2, .f = workerPost },
    .{ .name = "workerEnd", .arity = 1, .f = workerEnd },
    .{ .name = "workerSelf", .arity = 0, .f = workerSelf },
    .{ .name = "workerSource", .arity = 0, .f = workerSource },
};
