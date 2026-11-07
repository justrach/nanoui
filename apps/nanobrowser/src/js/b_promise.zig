//! The Promise constructor, then/catch/finally, and the combinators.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const u = @import("b_util.zig");
const Value = u.Value;
const PropKey = u.PropKey;
const Object = u.Object;
const PropFlags = u.PropFlags;
const objmod = @import("object.zig");
const props = @import("props.zig");
const conv = @import("conv.zig");
const str = @import("string.zig");
const calls = @import("interp_call.zig");
const iter = @import("iter.zig");
const core = @import("promise.zig");
const Capability = core.Capability;
const api = @import("vm_api.zig");

fn promiseCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    if (vm.new_target.isUndefined()) return vm.throwError(.TypeError, "Promise constructor cannot be invoked without 'new'");
    const executor = u.arg(args, 0);
    if (!executor.isCallable()) return vm.throwError(.TypeError, "Promise resolver is not a function");
    const p = try core.newPromise(vm, try calls.protoFromNewTarget(vm, vm.protos.promise));
    const fns = try core.resolvingFunctions(vm, p);
    _ = calls.call(vm, executor, Value.undefined, &.{ fns.resolve, fns.reject }) catch |e| {
        if (e != error.Thrown) return e;
        const ex = vm.exception;
        vm.exception = Value.undefined;
        _ = try calls.call(vm, fns.reject, Value.undefined, &.{ex});
    };
    return p.value();
}

fn capabilityExecutor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const holder = vm.capture(0).asObject();
    if (holder.elems_len != 0) {
        if (!holder.elems[0].isUndefined() or !holder.elems[1].isUndefined()) {
            return vm.throwError(.TypeError, "Promise executor has already been invoked");
        }
    }
    holder.elems_len = 0;
    try objmod.arrayPush(vm, holder, u.arg(args, 0));
    try objmod.arrayPush(vm, holder, u.arg(args, 1));
    return Value.undefined;
}

/// NewPromiseCapability, always with real functions.
pub fn newCapability(vm: *Vm, c: Value) Error!Capability {
    if (c.isObject() and c.asObject() == vm.protos.promise_ctor) {
        return core.resolvingFunctions(vm, try core.newPromise(vm, vm.protos.promise));
    }
    if (!c.isConstructor()) return vm.throwError(.TypeError, "Promise capability constructor is not a constructor");
    const holder = try objmod.newArray(vm, &.{});
    const ex = try api.newNativeClosure(vm, "", 2, capabilityExecutor, &.{holder.value()});
    const p = try calls.construct(vm, c, &.{ex}, c);
    if (holder.elems_len < 2 or !holder.elems[0].isCallable() or !holder.elems[1].isCallable()) {
        return vm.throwError(.TypeError, "Promise resolve or reject function is not callable");
    }
    return .{ .promise = p, .resolve = holder.elems[0], .reject = holder.elems[1] };
}

fn thenFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().class != .promise) return vm.throwError(.TypeError, "Promise.prototype.then called on incompatible receiver");
    const p = this.asObject();
    const c = try u.speciesConstructor(vm, p, vm.protos.promise_ctor);
    var cap: Capability = undefined;
    if (c.asObject() == vm.protos.promise_ctor) {
        cap = .{ .promise = (try core.newPromise(vm, vm.protos.promise)).value() };
    } else {
        cap = try newCapability(vm, c);
    }
    const f = u.arg(args, 0);
    const r = u.arg(args, 1);
    try core.addReaction(vm, p, .{
        .kind = .then,
        .on_fulfill = if (f.isCallable()) f else Value.undefined,
        .on_reject = if (r.isCallable()) r else Value.undefined,
        .cap = cap,
    });
    return cap.promise;
}

fn invokeThen(vm: *Vm, target: Value, a: Value, b: Value) Error!Value {
    const t = try props.getV(vm, target, vm.k.then);
    return calls.call(vm, t, target, &.{ a, b });
}

fn catchFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return invokeThen(vm, this, Value.undefined, u.arg(args, 0));
}

/// PromiseResolve(C, x).
pub fn promiseResolve(vm: *Vm, c: Value, x: Value) Error!Value {
    if (x.isObject() and x.asObject().class == .promise) {
        const xc = try props.get(vm, x.asObject(), vm.k.constructor);
        if (xc.bits == c.bits) return x;
    }
    const cap = try newCapability(vm, c);
    _ = try calls.call(vm, cap.resolve, Value.undefined, &.{x});
    return cap.promise;
}

fn valueThunk(vm: *Vm, _: Value, _: []const Value) Error!Value {
    return vm.capture(0);
}
fn thrower(vm: *Vm, _: Value, _: []const Value) Error!Value {
    return vm.throwValue(vm.capture(0));
}

fn finallyThen(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const r = try calls.call(vm, vm.capture(0), Value.undefined, &.{});
    const p = try promiseResolve(vm, vm.capture(1), r);
    const thunk = try api.newNativeClosure(vm, "", 0, valueThunk, &.{u.arg(args, 0)});
    return invokeThen(vm, p, thunk, Value.undefined);
}
fn finallyCatch(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const r = try calls.call(vm, vm.capture(0), Value.undefined, &.{});
    const p = try promiseResolve(vm, vm.capture(1), r);
    const thunk = try api.newNativeClosure(vm, "", 0, thrower, &.{u.arg(args, 0)});
    return invokeThen(vm, p, thunk, Value.undefined);
}

fn finallyFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    if (!this.isObject()) return vm.throwError(.TypeError, "Promise.prototype.finally called on a non-object");
    const c = try u.speciesConstructor(vm, this.asObject(), vm.protos.promise_ctor);
    const f = u.arg(args, 0);
    if (!f.isCallable()) return invokeThen(vm, this, f, f);
    const a = try api.newNativeClosure(vm, "", 1, finallyThen, &.{ f, c });
    const b = try api.newNativeClosure(vm, "", 1, finallyCatch, &.{ f, c });
    return invokeThen(vm, this, a, b);
}

fn resolveStatic(vm: *Vm, this: Value, args: []const Value) Error!Value {
    if (!this.isObject()) return vm.throwError(.TypeError, "PromiseResolve called on non-object");
    return promiseResolve(vm, this, u.arg(args, 0));
}
fn rejectStatic(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const cap = try newCapability(vm, this);
    _ = try calls.call(vm, cap.reject, Value.undefined, &.{u.arg(args, 0)});
    return cap.promise;
}
fn withResolvers(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const cap = try newCapability(vm, this);
    const o = try objmod.newPlain(vm);
    try props.addProp(vm, o, try str.keyFromBytes(vm, "promise"), cap.promise, PropFlags.all);
    try props.addProp(vm, o, vm.k.resolve, cap.resolve, PropFlags.all);
    try props.addProp(vm, o, try str.keyFromBytes(vm, "reject"), cap.reject, PropFlags.all);
    return o.value();
}

const Mode = enum(u8) { all, all_settled, any };

/// Shared per-combinator state: values array, remaining count in host_tag, and the capability.
fn settleOne(vm: *Vm, v: Value, mode: Mode, is_reject_slot: bool) Error!Value {
    const values = vm.capture(0).asObject();
    const index: u32 = @intCast(vm.capture(1).asInt());
    const flag = vm.capture(2).asObject();
    const counter = vm.capture(3).asObject();
    const settle = vm.capture(4);
    if (flag.host_tag != 0) return Value.undefined;
    flag.host_tag = 1;
    var item = v;
    if (mode == .all_settled) {
        const o = try objmod.newPlain(vm);
        try props.addProp(vm, o, vm.k.status, Value.fromString(if (is_reject_slot) vm.k.rejected.atom() else vm.k.fulfilled.atom()), PropFlags.all);
        try props.addProp(vm, o, if (is_reject_slot) vm.k.reason else vm.k.value, v, PropFlags.all);
        item = o.value();
    }
    values.elems[index] = item;
    counter.host_tag -= 1;
    if (counter.host_tag == 0) return finishCombinator(vm, values, settle, mode);
    return Value.undefined;
}

fn finishCombinator(vm: *Vm, values: *Object, settle: Value, mode: Mode) Error!Value {
    if (mode == .any) {
        const e = try api.makeError(vm, .AggregateError, "All promises were rejected");
        try props.addProp(vm, e.asObject(), vm.k.errors, values.value(), PropFlags.hidden);
        return calls.call(vm, settle, Value.undefined, &.{e});
    }
    return calls.call(vm, settle, Value.undefined, &.{values.value()});
}

fn elemAll(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return settleOne(vm, u.arg(args, 0), .all, false);
}
fn elemSettledOk(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return settleOne(vm, u.arg(args, 0), .all_settled, false);
}
fn elemSettledErr(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return settleOne(vm, u.arg(args, 0), .all_settled, true);
}
fn elemAny(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return settleOne(vm, u.arg(args, 0), .any, false);
}

fn combinator(vm: *Vm, c: Value, iterable: Value, mode: Mode) Error!Value {
    const cap = try newCapability(vm, c);
    run: {
        const resolve_fn = props.getV(vm, c, vm.k.resolve) catch |e| {
            if (e != error.Thrown) return e;
            break :run;
        };
        if (!resolve_fn.isCallable()) {
            vm.throwError(.TypeError, "Promise resolve or reject function is not callable") catch {};
            break :run;
        }
        const values = try objmod.newArray(vm, &.{});
        const counter = try objmod.newPlain(vm);
        counter.host_tag = 1;
        const settle = if (mode == .any) cap.reject else cap.resolve;
        const Ctx = struct {
            vm: *Vm,
            c: Value,
            cap: Capability,
            values: *Object,
            counter: *Object,
            resolve_fn: Value,
            mode: Mode,
            settle: Value,
            fn add(x: @This(), item: Value) Error!void {
                const v = x.vm;
                const index = x.values.arr_len;
                try objmod.arrayPush(v, x.values, Value.undefined);
                const next = try calls.call(v, x.resolve_fn, x.c, &.{item});
                const flag = try objmod.newPlain(v);
                const caps = [_]Value{ x.values.value(), Value.fromInt(@intCast(index)), flag.value(), x.counter.value(), x.settle };
                x.counter.host_tag += 1;
                var on_ok: Value = undefined;
                var on_err: Value = undefined;
                switch (x.mode) {
                    .all => {
                        on_ok = try api.newNativeClosure(v, "", 1, elemAll, &caps);
                        on_err = x.cap.reject;
                    },
                    .all_settled => {
                        on_ok = try api.newNativeClosure(v, "", 1, elemSettledOk, &caps);
                        on_err = try api.newNativeClosure(v, "", 1, elemSettledErr, &caps);
                    },
                    .any => {
                        on_ok = x.cap.resolve;
                        on_err = try api.newNativeClosure(v, "", 1, elemAny, &caps);
                    },
                }
                _ = try invokeThen(v, next, on_ok, on_err);
            }
        };
        iter.forEach(vm, iterable, Ctx{
            .vm = vm,
            .c = c,
            .cap = cap,
            .values = values,
            .counter = counter,
            .resolve_fn = resolve_fn,
            .mode = mode,
            .settle = settle,
        }, Ctx.add) catch |e| {
            if (e != error.Thrown) return e;
            break :run;
        };
        counter.host_tag -= 1;
        if (counter.host_tag == 0) {
            _ = finishCombinator(vm, values, settle, mode) catch |e| {
                if (e != error.Thrown) return e;
                break :run;
            };
        }
        return cap.promise;
    }
    const ex = vm.exception;
    vm.exception = Value.undefined;
    _ = try calls.call(vm, cap.reject, Value.undefined, &.{ex});
    return cap.promise;
}

fn allFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return combinator(vm, this, u.arg(args, 0), .all);
}
fn allSettledFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return combinator(vm, this, u.arg(args, 0), .all_settled);
}
fn anyFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return combinator(vm, this, u.arg(args, 0), .any);
}

fn raceFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const cap = try newCapability(vm, this);
    run: {
        const resolve_fn = props.getV(vm, this, vm.k.resolve) catch |e| {
            if (e != error.Thrown) return e;
            break :run;
        };
        const Ctx = struct {
            vm: *Vm,
            c: Value,
            cap: Capability,
            resolve_fn: Value,
            fn add(x: @This(), item: Value) Error!void {
                const next = try calls.call(x.vm, x.resolve_fn, x.c, &.{item});
                _ = try invokeThen(x.vm, next, x.cap.resolve, x.cap.reject);
            }
        };
        iter.forEach(vm, u.arg(args, 0), Ctx{ .vm = vm, .c = this, .cap = cap, .resolve_fn = resolve_fn }, Ctx.add) catch |e| {
            if (e != error.Thrown) return e;
            break :run;
        };
        return cap.promise;
    }
    const ex = vm.exception;
    vm.exception = Value.undefined;
    _ = try calls.call(vm, cap.reject, Value.undefined, &.{ex});
    return cap.promise;
}

pub fn init(vm: *Vm) Error!void {
    const p = try u.newProto(vm, vm.protos.object);
    vm.protos.promise = p;
    const c = try u.ctor(vm, "Promise", 1, promiseCtor, p);
    vm.protos.promise_ctor = c;
    try u.symGetter(vm, c, vm.sym.species, "get [Symbol.species]", u.returnThis);
    try u.toStringTag(vm, p, "Promise");
    try u.method(vm, p, "then", 2, thenFn);
    try u.method(vm, p, "catch", 1, catchFn);
    try u.method(vm, p, "finally", 1, finallyFn);
    try u.method(vm, c, "resolve", 1, resolveStatic);
    try u.method(vm, c, "reject", 1, rejectStatic);
    try u.method(vm, c, "withResolvers", 0, withResolvers);
    try u.method(vm, c, "all", 1, allFn);
    try u.method(vm, c, "allSettled", 1, allSettledFn);
    try u.method(vm, c, "any", 1, anyFn);
    try u.method(vm, c, "race", 1, raceFn);
}
