//! The array iterator, %IteratorPrototype%, %AsyncIteratorPrototype%, and the generator
//! prototypes. Generators' next/return/throw and the async-from-sync wrapper live here too.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const u = @import("b_util.zig");
const Value = u.Value;
const PropKey = u.PropKey;
const Object = u.Object;
const objmod = @import("object.zig");
const props = @import("props.zig");
const conv = @import("conv.zig");
const ops = @import("ops.zig");
const calls = @import("interp_call.zig");
const coroutine = @import("coroutine.zig");
const promise = @import("promise.zig");
const api = @import("vm_api.zig");
const str = @import("string.zig");
const iter = @import("iter.zig");
const typed = @import("b_typed.zig");

pub fn makeArrayIter(vm: *Vm, target: Value, kind: u8) Error!Value {
    const data = try vm.gpa.create(objmod.IterData);
    data.* = .{ .target = target, .kind = kind };
    const o = objmod.create(vm, vm.protos.array_iter, .array_iter) catch |e| {
        vm.gpa.destroy(data);
        return e;
    };
    o.payload = .{ .iter = data };
    return o.value();
}

fn iterFn(comptime kind: u8) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, _: []const Value) Error!Value {
            return makeArrayIter(vm, (try conv.toObject(vm, this)).value(), kind);
        }
    }.f;
}

fn arrayIterNext(vm: *Vm, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().class != .array_iter) return vm.throwError(.TypeError, "next method called on incompatible receiver");
    const it = this.asObject().payload.iter;
    if (it.done) return coroutine.iterResult(vm, Value.undefined, true);
    const o = it.target.asObject();
    const n = if (o.class == .typedarray) typed.length(o) else try conv.lengthOf(vm, o);
    if (it.index >= n) {
        it.done = true;
        return coroutine.iterResult(vm, Value.undefined, true);
    }
    const i = it.index;
    it.index += 1;
    const iv = Value.fromUsize(i);
    return coroutine.iterResult(vm, switch (it.kind) {
        0 => iv,
        1 => try props.get(vm, o, PropKey.fromIndex(@intCast(i))),
        else => (try objmod.newArray(vm, &.{ iv, try props.get(vm, o, PropKey.fromIndex(@intCast(i))) })).value(),
    }, false);
}

fn genOf(vm: *Vm, this: Value) Error!*coroutine.Coroutine {
    if (this.isObject() and this.asObject().class == .generator) return this.asObject().payload.co;
    return vm.throwError(.TypeError, "next method called on incompatible receiver");
}

fn genNext(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return coroutine.generatorResume(vm, try genOf(vm, this), u.arg(args, 0), 0);
}
fn genThrow(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return coroutine.generatorResume(vm, try genOf(vm, this), u.arg(args, 0), 1);
}
fn genReturn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return coroutine.generatorResume(vm, try genOf(vm, this), u.arg(args, 0), 2);
}

fn agenEnqueue(vm: *Vm, this: Value, v: Value, mode: i32) Error!Value {
    const p = try promise.newPromise(vm, vm.protos.promise);
    if (!this.isObject() or this.asObject().class != .async_generator) {
        const e = try api.makeError(vm, .TypeError, "next method called on incompatible receiver");
        try promise.reject(vm, p, e);
        return p.value();
    }
    const gen = this.asObject();
    const data = gen.payload.agen;
    try data.queue.append(vm.gpa, .{ .mode = mode, .value = v, .cap = .{ .promise = p.value() } });
    try coroutine.agenDrain(vm, gen);
    return p.value();
}
fn agenNext(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return agenEnqueue(vm, this, u.arg(args, 0), 0);
}
fn agenThrow(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return agenEnqueue(vm, this, u.arg(args, 0), 1);
}
fn agenReturn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return agenEnqueue(vm, this, u.arg(args, 0), 2);
}

fn unwrapDone(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return coroutine.iterResult(vm, u.arg(args, 0), vm.capture(0).asBool());
}

/// Wraps a sync iterator result: awaits its value, then rebuilds { value, done }.
fn continuation(vm: *Vm, cap: promise.Capability, result: Value) Error!void {
    if (!result.isObject()) return vm.throwError(.TypeError, "Iterator result is not an object");
    const done = ops.truthy(try props.get(vm, result.asObject(), vm.k.done));
    const v = try props.get(vm, result.asObject(), vm.k.value);
    const vp = try promise.promiseResolveIntrinsic(vm, v);
    const f = try api.newNativeClosure(vm, "", 1, unwrapDone, &.{Value.fromBool(done)});
    try promise.addReaction(vm, vp, .{ .kind = .then, .on_fulfill = f, .cap = cap });
}

fn asyncFromSyncStep(vm: *Vm, this: Value, v: Value, name: ?PropKey, has_v: bool) Error!Value {
    const it = this.asObject().payload.iter;
    const p = try promise.newPromise(vm, vm.protos.promise);
    const cap = promise.Capability{ .promise = p.value() };
    run: {
        var m = it.aux;
        if (name) |nk| {
            m = props.getV(vm, it.target, nk) catch |e| {
                if (e != error.Thrown) return e;
                break :run;
            };
            if (m.isNullish()) {
                if (nk.eql(vm.k.@"return")) {
                    try promise.resolve(vm, p, try coroutine.iterResult(vm, v, true));
                } else {
                    try promise.reject(vm, p, v);
                }
                return p.value();
            }
        }
        const single = [1]Value{v};
        const res = calls.call(vm, m, it.target, if (has_v) &single else &.{}) catch |e| {
            if (e != error.Thrown) return e;
            break :run;
        };
        continuation(vm, cap, res) catch |e| {
            if (e != error.Thrown) return e;
            break :run;
        };
        return p.value();
    }
    const ex = vm.exception;
    vm.exception = Value.undefined;
    try promise.reject(vm, p, ex);
    return p.value();
}

fn afsNext(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return asyncFromSyncStep(vm, this, u.arg(args, 0), null, args.len > 0);
}
fn afsReturn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return asyncFromSyncStep(vm, this, u.arg(args, 0), vm.k.@"return", args.len > 0);
}
fn afsThrow(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return asyncFromSyncStep(vm, this, u.arg(args, 0), vm.k.throw, args.len > 0);
}

pub fn initIterators(vm: *Vm) Error!void {
    const p = &vm.protos;
    p.iterator = try u.newProto(vm, p.object);
    try u.symMethod(vm, p.iterator, vm.sym.iterator, "[Symbol.iterator]", 0, u.returnThis);
    p.async_iterator = try u.newProto(vm, p.object);
    try u.symMethod(vm, p.async_iterator, vm.sym.asyncIterator, "[Symbol.asyncIterator]", 0, u.returnThis);

    p.array_iter = try u.newProto(vm, p.iterator);
    try u.method(vm, p.array_iter, "next", 0, arrayIterNext);
    try u.toStringTag(vm, p.array_iter, "Array Iterator");
    p.array_iter_next = (try props.get(vm, p.array_iter, vm.k.next)).asObject();

    p.generator = try u.newProto(vm, p.iterator);
    try u.method(vm, p.generator, "next", 1, genNext);
    try u.method(vm, p.generator, "return", 1, genReturn);
    try u.method(vm, p.generator, "throw", 1, genThrow);
    try u.toStringTag(vm, p.generator, "Generator");

    p.async_generator = try u.newProto(vm, p.async_iterator);
    try u.method(vm, p.async_generator, "next", 1, agenNext);
    try u.method(vm, p.async_generator, "return", 1, agenReturn);
    try u.method(vm, p.async_generator, "throw", 1, agenThrow);
    try u.toStringTag(vm, p.async_generator, "AsyncGenerator");

    p.async_from_sync = try u.newProto(vm, p.async_iterator);
    try u.method(vm, p.async_from_sync, "next", 1, afsNext);
    try u.method(vm, p.async_from_sync, "return", 1, afsReturn);
    try u.method(vm, p.async_from_sync, "throw", 1, afsThrow);

    p.generator_function = try u.newProto(vm, p.function);
    try props.addProp(vm, p.generator_function, vm.k.prototype, p.generator.value(), u.PropFlags.config_only);
    try props.defineData(vm, p.generator, vm.k.constructor, p.generator_function.value(), u.PropFlags.config_only);
    try u.toStringTag(vm, p.generator_function, "GeneratorFunction");
    p.async_generator_function = try u.newProto(vm, p.function);
    try props.addProp(vm, p.async_generator_function, vm.k.prototype, p.async_generator.value(), u.PropFlags.config_only);
    try props.defineData(vm, p.async_generator, vm.k.constructor, p.async_generator_function.value(), u.PropFlags.config_only);
    try u.toStringTag(vm, p.async_generator_function, "AsyncGeneratorFunction");
    p.async_function = try u.newProto(vm, p.function);
    try u.toStringTag(vm, p.async_function, "AsyncFunction");
}

pub fn init(vm: *Vm, p: *Object) Error!void {
    try u.method(vm, p, "keys", 0, iterFn(0));
    try u.method(vm, p, "values", 0, iterFn(1));
    try u.method(vm, p, "entries", 0, iterFn(2));
    const values = (try props.get(vm, p, try str.keyFromBytes(vm, "values"))).asObject();
    vm.protos.array_values = values;
    try props.defineData(vm, p, PropKey.fromSymbol(vm.sym.iterator), values.value(), u.PropFlags.hidden);
    const un = try objmod.create(vm, null, .object);
    for ([_][]const u8{ "at", "copyWithin", "entries", "fill", "find", "findIndex", "findLast", "findLastIndex", "flat", "flatMap", "includes", "keys", "toReversed", "toSorted", "toSpliced", "values" }) |name| {
        try props.defineData(vm, un, try str.keyFromBytes(vm, name), Value.true, u.PropFlags.all);
    }
    try props.defineData(vm, p, PropKey.fromSymbol(vm.sym.unscopables), un.value(), u.PropFlags.config_only);
}
