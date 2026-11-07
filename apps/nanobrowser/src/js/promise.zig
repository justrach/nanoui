//! The core of promises: state, reactions, resolution, the microtask queue, and the
//! fast path `await` takes. The JS-visible Promise constructor and methods are in
//! b_promise.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const Value = @import("value.zig").Value;
const heap = @import("heap.zig");
const objmod = @import("object.zig");
const Object = objmod.Object;
const props = @import("props.zig");
const calls = @import("interp_call.zig");
const coroutine = @import("coroutine.zig");
const api = @import("vm_api.zig");

pub const State = enum(u8) { pending, fulfilled, rejected };

/// A promise with its settle functions. With undefined functions and a real promise,
/// settling goes straight to the promise, which saves making two closures.
pub const Capability = struct {
    promise: Value = Value.undefined,
    resolve: Value = Value.undefined,
    reject: Value = Value.undefined,

    pub fn trace(c: Capability, m: *heap.Marker) void {
        m.mark(c.promise);
        m.mark(c.resolve);
        m.mark(c.reject);
    }
};

pub const Reaction = struct {
    kind: enum(u8) { then, await_co, await_return },
    on_fulfill: Value = Value.undefined,
    on_reject: Value = Value.undefined,
    cap: Capability = .{},
    co: ?*coroutine.Coroutine = null,
    gen: ?*Object = null,

    fn trace(r: *const Reaction, m: *heap.Marker) void {
        m.mark(r.on_fulfill);
        m.mark(r.on_reject);
        r.cap.trace(m);
        if (r.co) |c| m.markCell(&c.cell);
        m.markObj(r.gen);
    }
};

pub const PromiseData = struct {
    state: State = .pending,
    handled: bool = false,
    result: Value = Value.undefined,
    reactions: std.ArrayList(Reaction) = .empty,

    pub fn trace(p: *PromiseData, m: *heap.Marker) void {
        m.mark(p.result);
        for (p.reactions.items) |*r| r.trace(m);
    }
    pub fn destroy(p: *PromiseData, gpa: Allocator) void {
        p.reactions.deinit(gpa);
        gpa.destroy(p);
    }
};

pub const Job = union(enum) {
    reaction: struct { r: Reaction, arg: Value, is_reject: bool },
    thenable: struct { promise: *Object, thenable: Value, then: Value },
    callback: Value,

    pub fn trace(j: *const Job, m: *heap.Marker) void {
        switch (j.*) {
            .reaction => |x| {
                x.r.trace(m);
                m.mark(x.arg);
            },
            .thenable => |x| {
                m.markObj(x.promise);
                m.mark(x.thenable);
                m.mark(x.then);
            },
            .callback => |v| m.mark(v),
        }
    }
};

/// Called for a rejection nothing handled by the end of a microtask drain, and for a
/// microtask callback that threw (with an undefined promise).
pub const RejectionHook = *const fn (ctx: ?*anyopaque, vm: *Vm, promise: Value, reason: Value) void;

pub fn setRejectionHook(vm: *Vm, ctx: ?*anyopaque, hook: ?RejectionHook) void {
    vm.rejection_ctx = ctx;
    vm.rejection_hook = hook;
}

pub fn newPromise(vm: *Vm, proto: *Object) Error!*Object {
    const data = try vm.gpa.create(PromiseData);
    data.* = .{};
    const o = objmod.create(vm, proto, .promise) catch |e| {
        vm.gpa.destroy(data);
        return e;
    };
    o.payload = .{ .promise = data };
    return o;
}

fn enqueue(vm: *Vm, j: Job) Error!void {
    try vm.jobs.append(vm.gpa, j);
}

pub fn enqueueCallback(vm: *Vm, f: Value) Error!void {
    try enqueue(vm, .{ .callback = f });
}

fn settle(vm: *Vm, p: *Object, state: State, v: Value) Error!void {
    const d = p.payload.promise;
    d.state = state;
    d.result = v;
    if (state == .rejected and !d.handled) try vm.pending_rejections.append(vm.gpa, p);
    for (d.reactions.items) |r| {
        try enqueue(vm, .{ .reaction = .{ .r = r, .arg = v, .is_reject = state == .rejected } });
    }
    d.reactions.clearAndFree(vm.gpa);
}

pub fn fulfill(vm: *Vm, p: *Object, v: Value) Error!void {
    return settle(vm, p, .fulfilled, v);
}

pub fn reject(vm: *Vm, p: *Object, v: Value) Error!void {
    if (p.payload.promise.state != .pending) return;
    return settle(vm, p, .rejected, v);
}

/// The promise resolve function's algorithm.
pub fn resolve(vm: *Vm, p: *Object, v: Value) Error!void {
    if (p.payload.promise.state != .pending) return;
    if (v.isObject() and v.asObject() == p) {
        const e = try api.makeError(vm, .TypeError, "Chaining cycle detected for promise");
        return reject(vm, p, e);
    }
    if (!v.isObject()) return fulfill(vm, p, v);
    const then = props.get(vm, v.asObject(), vm.k.then) catch |e| {
        if (e != error.Thrown) return e;
        const ex = vm.exception;
        vm.exception = Value.undefined;
        return reject(vm, p, ex);
    };
    if (!then.isCallable()) return fulfill(vm, p, v);
    try enqueue(vm, .{ .thenable = .{ .promise = p, .thenable = v, .then = then } });
}

/// Attaches a reaction, which fires now (as a job) if the promise has settled.
pub fn addReaction(vm: *Vm, p: *Object, r: Reaction) Error!void {
    const d = p.payload.promise;
    switch (d.state) {
        .pending => try d.reactions.append(vm.gpa, r),
        else => try enqueue(vm, .{ .reaction = .{ .r = r, .arg = d.result, .is_reject = d.state == .rejected } }),
    }
    d.handled = true;
}

/// PromiseResolve(%Promise%, v).
pub fn promiseResolveIntrinsic(vm: *Vm, v: Value) Error!*Object {
    if (v.isObject() and v.asObject().class == .promise) {
        const c = try props.get(vm, v.asObject(), vm.k.constructor);
        if (c.isObject() and c.asObject() == vm.protos.promise_ctor) return v.asObject();
    }
    const p = try newPromise(vm, vm.protos.promise);
    try resolve(vm, p, v);
    return p;
}

pub fn awaitValue(vm: *Vm, v: Value, co: *coroutine.Coroutine) Error!void {
    const p = try promiseResolveIntrinsic(vm, v);
    try addReaction(vm, p, .{ .kind = .await_co, .co = co });
}

pub fn awaitReturn(vm: *Vm, gen: *Object, v: Value) Error!void {
    const p = try promiseResolveIntrinsic(vm, v);
    try addReaction(vm, p, .{ .kind = .await_return, .gen = gen });
}

pub fn callResolve(vm: *Vm, c: Capability, v: Value) Error!void {
    if (c.resolve.isUndefined()) {
        if (c.promise.isObject()) try resolve(vm, c.promise.asObject(), v);
        return;
    }
    _ = try calls.call(vm, c.resolve, Value.undefined, &.{v});
}

pub fn callReject(vm: *Vm, c: Capability, v: Value) Error!void {
    if (c.reject.isUndefined()) {
        if (c.promise.isObject()) try reject(vm, c.promise.asObject(), v);
        return;
    }
    _ = try calls.call(vm, c.reject, Value.undefined, &.{v});
}

/// The resolve function made by CreateResolvingFunctions.
fn resolveFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const p = vm.capture(0).asObject();
    const flag = vm.capture(1).asObject();
    if (flag.host_tag != 0) return Value.undefined;
    flag.host_tag = 1;
    try resolve(vm, p, if (args.len > 0) args[0] else Value.undefined);
    return Value.undefined;
}

fn rejectFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const p = vm.capture(0).asObject();
    const flag = vm.capture(1).asObject();
    if (flag.host_tag != 0) return Value.undefined;
    flag.host_tag = 1;
    try reject(vm, p, if (args.len > 0) args[0] else Value.undefined);
    return Value.undefined;
}

pub fn resolvingFunctions(vm: *Vm, p: *Object) Error!Capability {
    const flag = try objmod.newPlain(vm);
    const caps = [_]Value{ p.value(), flag.value() };
    const res = try api.newNativeClosure(vm, "", 1, resolveFn, &caps);
    const rej = try api.newNativeClosure(vm, "", 1, rejectFn, &caps);
    return .{ .promise = p.value(), .resolve = res, .reject = rej };
}

fn runReaction(vm: *Vm, r: Reaction, arg: Value, is_reject: bool) Error!void {
    switch (r.kind) {
        .await_co => return coroutine.resumeAwait(vm, r.co.?, arg, is_reject),
        .await_return => return coroutine.agenReturnSettled(vm, r.gen.?, arg, is_reject),
        .then => {},
    }
    const handler = if (is_reject) r.on_reject else r.on_fulfill;
    if (handler.isUndefined()) {
        if (is_reject) return callReject(vm, r.cap, arg);
        return callResolve(vm, r.cap, arg);
    }
    const result = calls.call(vm, handler, Value.undefined, &.{arg}) catch |e| {
        if (e != error.Thrown) return e;
        const ex = vm.exception;
        vm.exception = Value.undefined;
        return callReject(vm, r.cap, ex);
    };
    return callResolve(vm, r.cap, result);
}

fn runThenable(vm: *Vm, p: *Object, thenable: Value, then: Value) Error!void {
    const fns = try resolvingFunctions(vm, p);
    _ = calls.call(vm, then, thenable, &.{ fns.resolve, fns.reject }) catch |e| {
        if (e != error.Thrown) return e;
        const ex = vm.exception;
        vm.exception = Value.undefined;
        _ = try calls.call(vm, fns.reject, Value.undefined, &.{ex});
    };
}

fn runJob(vm: *Vm, j: Job) Error!void {
    switch (j) {
        .reaction => |x| try runReaction(vm, x.r, x.arg, x.is_reject),
        .thenable => |x| try runThenable(vm, x.promise, x.thenable, x.then),
        .callback => |f| _ = try calls.call(vm, f, Value.undefined, &.{}),
    }
}

/// Drains the microtask queue, then reports rejections nobody handled. A termination
/// (deadline) stops the drain; the remaining jobs stay queued.
pub fn runJobs(vm: *Vm) void {
    vm.enterFromHost();
    while (vm.jobs_head < vm.jobs.items.len) {
        const j = vm.jobs.items[vm.jobs_head];
        vm.jobs_head += 1;
        runJob(vm, j) catch |e| switch (e) {
            error.Terminated => return,
            error.OutOfMemory, error.Thrown => {
                if (e == error.OutOfMemory) api.throwOutOfMemory(vm);
                const ex = vm.exception;
                vm.exception = Value.undefined;
                if (vm.rejection_hook) |h| h(vm.rejection_ctx, vm, Value.undefined, ex);
            },
        };
    }
    vm.jobs.clearRetainingCapacity();
    vm.jobs_head = 0;
    if (vm.pending_rejections.items.len != 0) {
        var i: usize = 0;
        while (i < vm.pending_rejections.items.len) : (i += 1) {
            const p = vm.pending_rejections.items[i];
            const d = p.payload.promise;
            if (!d.handled) {
                if (vm.rejection_hook) |h| h(vm.rejection_ctx, vm, p.value(), d.result);
            }
        }
        vm.pending_rejections.clearRetainingCapacity();
        // A hook may have queued work.
        if (vm.jobs.items.len != 0) runJobs(vm);
    }
}
