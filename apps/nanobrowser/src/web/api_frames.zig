//! What scripts see of other frames. Each page's world is a VM of its own, so a
//! window of the same origin reaches this one through proxies whose every operation
//! crosses to the VM that owns the object and carries its answer back: strings are
//! copied, numbers and the like are themselves, objects become proxies in turn (and
//! a proxy going home becomes what it stood for). A window of another origin is a
//! small object in `prelude_frames.js` that can post messages and be navigated.
//! A frame's window keeps its number while pages come and go in the frame, as scripts
//! hold on to `contentWindow` across a navigation; an object in a page goes with it.
const std = @import("std");
const js = @import("../js/js.zig");
const dom = @import("../dom.zig");
const bind = @import("bind.zig");
const web = @import("web.zig");
const frames = @import("../frames.zig");
const Page = @import("../page.zig").Page;
const Value = js.Value;
const Vm = js.Vm;
const Error = js.Error;
const World = bind.World;

/// Every page scripts have named, by number. Numbers aren't used twice.
var pages: std.AutoHashMapUnmanaged(u32, *Page) = .empty;
var pages_gpa: ?std.mem.Allocator = null;
var next_id: u32 = 1;
/// The frames whose window scripts have named, by a number from the same run.
var windows: std.AutoHashMapUnmanaged(u32, *frames.Frame) = .empty;

fn idOf(p: *Page) u32 {
    if (p.id == 0) {
        p.id = next_id;
        next_id +%= 1;
        pages_gpa = p.gpa;
        pages.put(p.gpa, p.id, p) catch {};
    }
    return p.id;
}

/// A page is going.
pub fn forget(p: *Page) void {
    if (p.id == 0) return;
    _ = pages.remove(p.id);
    tidy();
}

/// A frame is going, and its window with it.
pub fn forgetFrame(f: *frames.Frame) void {
    if (f.window_id == 0) return;
    _ = windows.remove(f.window_id);
    tidy();
}

fn tidy() void {
    if (pages.count() != 0 or windows.count() != 0) return;
    const a = pages_gpa orelse return;
    pages.deinit(a);
    pages = .empty;
    windows.deinit(a);
    windows = .empty;
}

/// The number of the window a page is in: its frame's, or for a tab's page its own.
fn windowIdOf(p: *Page) u32 {
    const f = p.frame orelse return idOf(p);
    if (f.window_id == 0) {
        f.window_id = next_id;
        next_id +%= 1;
        pages_gpa = p.gpa;
        windows.put(p.gpa, f.window_id, f) catch {};
    }
    return f.window_id;
}

/// An object one world holds that another's proxy stands for.
pub const Remote = struct { peer: u32, id: u32 };
/// A remote's `id` when it stands for the window itself.
const window_export = 0;

fn exported(from: *World, obj: *js.Object) Error!u32 {
    const got = try from.export_ids.getOrPut(from.gpa, obj);
    if (got.found_existing) return got.value_ptr.*;
    try from.exports.append(from.gpa, obj.value());
    const id: u32 = @intCast(from.exports.items.len);
    got.value_ptr.* = id;
    return id;
}

/// A value of `from`'s as `to` sees it.
pub fn carry(from: *World, to: *World, v: Value) Error!Value {
    if (v.isString()) return to.vm.newString(try from.vm.toStringSlice(v));
    if (v.isSymbol() or v.isBigInt()) return Value.undefined;
    if (!v.isObject()) return v;
    const obj = v.asObject();
    // A proxy going home.
    if (from.imports.get(obj)) |r| {
        if (r.id == window_export and r.peer == windowIdOf(to.page)) return to.vm.global().value();
        if (r.id != window_export and r.peer == idOf(to.page)) return to.exports.items[r.id - 1];
    }
    if (obj == from.vm.global()) return windowProxy(to, from.page);
    const peer = idOf(from.page);
    const id = try exported(from, obj);
    const remote_key = (@as(u64, peer) << 32) | id;
    if (to.import_by_remote.get(remote_key)) |p| return p.value();
    return makeProxy(to, peer, id, v.isCallable(), try @import("../js/b_array.zig").isArrayValue(from.vm, v));
}

fn makeProxy(to: *World, peer: u32, id: u32, callable: bool, array: bool) Error!Value {
    const remote_key = (@as(u64, peer) << 32) | id;
    if (to.import_by_remote.get(remote_key)) |p| return p.value();
    const proxy = try to.vm.call(to.h.makeRemote, Value.undefined, &.{ Value.fromUsize(peer), Value.fromUsize(id), Value.fromBool(callable), Value.fromBool(array) });
    if (proxy.isObject()) {
        const pobj = proxy.asObject();
        try to.imports.put(to.gpa, pobj, .{ .peer = peer, .id = id });
        try to.import_by_remote.put(to.gpa, remote_key, pobj);
    }
    return proxy;
}

fn windowProxy(to: *World, target: *Page) Error!Value {
    return makeProxy(to, windowIdOf(target), window_export, false, false);
}

/// `target`'s window, as the world of `w` may see it.
fn windowValue(w: *World, target: *Page) Error!Value {
    if (target == w.page) return w.vm.global().value();
    return windowProxy(w, target);
}

fn pageArg(args: []const Value, i: usize) ?*Page {
    const v = bind.arg(args, i);
    if (!v.isInt()) return null;
    const id: u32 = @intCast(@max(0, v.asInt()));
    if (pages.get(id)) |p| return p;
    if (windows.get(id)) |f| return f.page;
    return null;
}

/// `$.peerState(id)`: 0 nothing there, 1 this origin's, 2 another's.
fn peerState(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const p = pageArg(args, 0) orelse return Value.fromInt(0);
    if (p.dead) return Value.fromInt(0);
    return Value.fromInt(if (frames.sameOrigin(bind.world(vm).page, p)) 1 else 2);
}

fn carryArgs(from: *World, to: *World, v: Value) Error!Value {
    if (!v.isObject()) return (try to.vm.newArray(&.{})).value();
    const arr = v.asObject();
    const n: u32 = if (arr.isArray()) arr.arr_len else @intFromFloat(@max(0, try from.vm.toNumber(try arr.get(from.vm, "length"))));
    const out = try to.vm.newArray(&.{});
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const item = try arr.getIdx(from.vm, i);
        try out.setIdx(to.vm, i, try carry(from, to, item));
    }
    return out.value();
}

fn runRemoteOp(me: *World, o: *World, op_num: i32, object: Value, args: []const Value) Error!Value {
    switch (op_num) {
        0 => {
            const key_arg = bind.arg(args, 3);
            if (object.isObject()) {
                if (key_arg.isInt() and key_arg.asInt() >= 0) {
                    return object.asObject().getIdx(o.vm, @intCast(key_arg.asInt()));
                }
                if (key_arg.isString()) {
                    return object.asObject().get(o.vm, try me.vm.toStringSlice(key_arg));
                }
            }
        },
        1 => {
            const key_arg = bind.arg(args, 3);
            if (object.isObject() and key_arg.isString()) {
                try object.asObject().set(o.vm, try me.vm.toStringSlice(key_arg), try carry(me, o, bind.arg(args, 4)));
                return Value.true;
            }
        },
        6 => {
            if (object.isCallable()) {
                const this_arg = try carry(me, o, bind.arg(args, 3));
                const raw_args = bind.arg(args, 4);
                var stack_argv: [16]Value = undefined;
                if (raw_args.isObject() and raw_args.asObject().isArray()) {
                    const arr = raw_args.asObject();
                    const n = arr.arr_len;
                    if (n <= stack_argv.len) {
                        for (0..n) |i| stack_argv[i] = try carry(me, o, try arr.getIdx(me.vm, @intCast(i)));
                        return o.vm.call(object, this_arg, stack_argv[0..n]);
                    }
                }
            }
        },
        7 => {
            if (object.isConstructor()) {
                const raw_args = bind.arg(args, 3);
                var stack_argv: [16]Value = undefined;
                if (raw_args.isObject() and raw_args.asObject().isArray()) {
                    const arr = raw_args.asObject();
                    const n = arr.arr_len;
                    if (n <= stack_argv.len) {
                        for (0..n) |i| stack_argv[i] = try carry(me, o, try arr.getIdx(me.vm, @intCast(i)));
                        return o.vm.construct(object, stack_argv[0..n]);
                    }
                }
            }
        },
        else => {},
    }
    const a = if (op_num == 7) try carryArgs(me, o, bind.arg(args, 3)) else try carry(me, o, bind.arg(args, 3));
    const b = if (op_num == 6) try carryArgs(me, o, bind.arg(args, 4)) else try carry(me, o, bind.arg(args, 4));
    return o.vm.call(o.h.remoteOp, Value.undefined, &.{ bind.arg(args, 0), object, a, b });
}

/// `$.remote(op, peer, id, a, b)`: the proxies' every operation.
fn remote(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const me = bind.world(vm);
    // A frame that has gone answers as a browser's does: with nothing, not an error.
    const owner = pageArg(args, 1) orelse return Value.undefined;
    if (owner.dead) return Value.undefined;
    if (!frames.sameOrigin(me.page, owner)) return bind.throwDom(vm, "SecurityError", "Blocked a frame from accessing another origin's.");
    const o = web.ensureWorld(owner) orelse return Value.undefined;
    const id: usize = @intCast(@max(0, bind.arg(args, 2).asInt()));
    if (id > o.exports.items.len) return Value.undefined;
    const object = if (id == window_export) o.vm.global().value() else o.exports.items[id - 1];
    const op_num = if (bind.arg(args, 0).isInt()) bind.arg(args, 0).asInt() else -1;
    const was = o.caller;
    o.caller = me.page;
    o.enter();
    defer o.leaveRemote(was);
    const out = runRemoteOp(me, o, op_num, object, args) catch |e| switch (e) {
        error.Thrown => {
            const text = o.vm.exceptionString();
            const copy = try vm.newString(text);
            o.vm.exception = Value.undefined;
            return vm.throwError(.Error, try vm.toStringSlice(copy));
        },
        else => return e,
    };
    return carry(o, me, out);
}

fn frameWindow(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const n = try bind.nodeArg(vm, args, 0, "contentWindow");
    if (n.doc != w.page.doc) return Value.null;
    frames.note(w.page, n);
    const f = frames.frameOf(w.page, n) orelse return Value.null;
    if (f.page == null) frames.start(f);
    const child = f.page orelse return Value.null;
    return windowValue(w, child);
}

/// Whether a script here may touch that iframe's document.
fn frameShared(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const n = try bind.nodeArg(vm, args, 0, "contentDocument");
    const child = frames.childPage(w.page, n) orelse return Value.false;
    return Value.fromBool(frames.sameOrigin(w.page, child));
}

fn isFramed(vm: *Vm, _: Value, _: []const Value) Error!Value {
    return Value.fromBool(bind.world(vm).page.frame != null);
}

/// `$.relative("parent" | "top")`.
fn relative(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const which = try bind.str(vm, args, 0);
    const target: *Page = if (std.mem.eql(u8, which, "top")) frames.topOf(w.page) else if (w.page.frame) |f| f.owner else w.page;
    return windowValue(w, target);
}

fn childPages(p: *const Page, out: *std.ArrayList(*Page), gpa: std.mem.Allocator) Error!void {
    for (p.frames.list.items) |f| if (f.page) |c| try out.append(gpa, c);
}

/// `window.frames`: `[window, name, …]` of the frames in document order.
fn framesOf(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const on = if (bind.arg(args, 0).isInt()) pageArg(args, 0) orelse return (try vm.newArray(&.{})).value() else w.page;
    const arr = try vm.newArray(&.{});
    var i: u32 = 0;
    for (on.frames.list.items) |f| {
        const c = f.page orelse continue;
        try arr.setIdx(vm, i, try windowValue(w, c));
        try arr.setIdx(vm, i + 1, try vm.newString(f.node.attr("name") orelse ""));
        i += 2;
    }
    return arr.value();
}

/// How many frames a window has, for `window.length`.
fn framesCount(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const on = if (bind.arg(args, 0).isInt()) pageArg(args, 0) orelse return Value.fromInt(0) else w.page;
    var n: i32 = 0;
    for (on.frames.list.items) |f| {
        if (f.page != null) n += 1;
    }
    return Value.fromInt(n);
}

/// `$.windowOfPage(id)`, for a message's `source`.
fn windowOfPage(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const target = pageArg(args, 0) orelse return Value.null;
    return windowValue(bind.world(vm), target);
}

/// `$.neighbor(id, "parent"|"top"|"self")`: the number of a window near another.
fn neighbor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const p = pageArg(args, 0) orelse return Value.null;
    const which = try bind.str(vm, args, 1);
    const target: *Page = if (std.mem.eql(u8, which, "top")) frames.topOf(p) else if (p.frame) |f| f.owner else p;
    return windowValue(bind.world(vm), target);
}

fn frameElement(vm: *Vm, _: Value, _: []const Value) Error!Value {
    const w = bind.world(vm);
    const f = w.page.frame orelse return Value.null;
    if (!frames.sameOrigin(w.page, f.owner)) return Value.null;
    const twin = web.ensureWorld(f.owner) orelse return Value.null;
    return carry(twin, w, try bind.wrap(twin.vm, f.node));
}

fn frameName(vm: *Vm, _: Value, _: []const Value) Error!Value {
    const f = bind.world(vm).page.frame orelse return vm.newString("");
    return vm.newString(f.node.attr("name") orelse "");
}

/// A page calling in from another, while it does; 0 when none.
fn caller(vm: *Vm, _: Value, _: []const Value) Error!Value {
    const c = bind.world(vm).caller orelse return Value.fromInt(0);
    return Value.fromUsize(idOf(c));
}

fn pageOrigin(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const p = if (bind.arg(args, 0).isInt()) pageArg(args, 0) orelse return vm.newString("null") else w.page;
    return vm.newString(frames.originOf(w.page.arena(), p));
}

/// `$.postTo(id, json, targetOrigin)`: a message to a window of any origin.
fn postTo(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const target = pageArg(args, 0) orelse return Value.undefined;
    if (target.dead) return Value.undefined;
    const want = try bind.str(vm, args, 2);
    const a = w.page.arena();
    if (!std.mem.eql(u8, want, "*")) {
        const place = if (std.mem.eql(u8, want, "/")) frames.originOf(a, w.page) else want;
        if (!std.mem.eql(u8, frames.urlOrigin(place), frames.originOf(a, target)) and !std.mem.eql(u8, place, frames.originOf(a, target))) return Value.undefined;
    }
    const tw = web.ensureWorld(target) orelse return Value.undefined;
    if (!tw.h.deliverMessage.isCallable()) return Value.undefined;
    const data = try tw.vm.newString(try bind.str(vm, args, 1));
    const origin = try tw.vm.newString(frames.originOf(a, w.page));
    _ = try tw.timers.add(tw, tw.h.deliverMessage, 0, &.{ data, origin, Value.fromUsize(windowIdOf(w.page)) }, false);
    return Value.undefined;
}

/// `$.portSend(page, port, text)`: what a port's partner in another world is sent.
fn portSend(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const target = pageArg(args, 0) orelse return Value.undefined;
    if (target.dead) return Value.undefined;
    const tw = target.js orelse return Value.undefined;
    if (!tw.h.portMessage.isCallable()) return Value.undefined;
    const text = try tw.vm.newString(try bind.str(vm, args, 2));
    _ = try tw.timers.add(tw, tw.h.portMessage, 0, &.{ bind.arg(args, 1), text }, false);
    return Value.undefined;
}

/// A cross-origin window's `location = ...`: only ever a navigation.
fn navigateFrame(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const target = pageArg(args, 0) orelse return Value.undefined;
    const to = @import("../loader.zig").linkFrom(w.page, try bind.str(vm, args, 1)) orelse return Value.undefined;
    if (target.frame) |f| frames.navigateTo(f, to, .{}) else target.navigate(.{ .url = to });
    return Value.undefined;
}

/// `$.pageId()`: this page's number.
fn pageId(vm: *Vm, _: Value, _: []const Value) Error!Value {
    return Value.fromUsize(idOf(bind.world(vm).page));
}

/// `$.topLayer(el, up, modal)`.
fn topLayer(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const n = try bind.nodeArg(vm, args, 0, "topLayer");
    const up = vm.toBoolean(bind.arg(args, 1));
    n.modal = up and vm.toBoolean(bind.arg(args, 2));
    n.doc.setTopLayer(n, up);
    bind.world(vm).changed();
    return Value.undefined;
}

/// `$.popoverOpen(el, open)`; without `open`, whether it is.
fn popoverOpen(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const n = try bind.nodeArg(vm, args, 0, "popover");
    if (args.len < 2) return Value.fromBool(n.popover_open);
    n.popover_open = vm.toBoolean(args[1]);
    n.doc.setTopLayer(n, n.popover_open);
    bind.world(vm).changed();
    return Value.undefined;
}

/// A port from another same-origin realm still has its transferable type there.
fn remotePort(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const v = bind.arg(args, 0);
    if (!v.isObject()) return Value.false;
    const r = bind.world(vm).imports.get(v.asObject()) orelse return Value.false;
    return remote(vm, Value.undefined, &.{ Value.fromInt(10), Value.fromUsize(r.peer), Value.fromUsize(r.id) });
}

pub const internals = [_]bind.Method{
    .{ .name = "remotePort", .arity = 1, .f = remotePort },
    .{ .name = "remote", .arity = 5, .f = remote },
    .{ .name = "peerState", .arity = 1, .f = peerState },
    .{ .name = "frameWindow", .arity = 1, .f = frameWindow },
    .{ .name = "frameShared", .arity = 1, .f = frameShared },
    .{ .name = "isFramed", .arity = 0, .f = isFramed },
    .{ .name = "relative", .arity = 1, .f = relative },
    .{ .name = "framesOf", .arity = 1, .f = framesOf },
    .{ .name = "framesCount", .arity = 1, .f = framesCount },
    .{ .name = "windowOfPage", .arity = 1, .f = windowOfPage },
    .{ .name = "neighbor", .arity = 2, .f = neighbor },
    .{ .name = "frameElement", .arity = 0, .f = frameElement },
    .{ .name = "frameName", .arity = 0, .f = frameName },
    .{ .name = "callerPage", .arity = 0, .f = caller },
    .{ .name = "pageOrigin", .arity = 1, .f = pageOrigin },
    .{ .name = "postTo", .arity = 3, .f = postTo },
    .{ .name = "portSend", .arity = 3, .f = portSend },
    .{ .name = "navigateFrame", .arity = 2, .f = navigateFrame },
    .{ .name = "pageId", .arity = 0, .f = pageId },
    .{ .name = "topLayer", .arity = 3, .f = topLayer },
    .{ .name = "popoverOpen", .arity = 2, .f = popoverOpen },
};
