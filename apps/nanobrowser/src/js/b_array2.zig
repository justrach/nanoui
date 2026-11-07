//! Array methods with callbacks, the flat family, and the ES2023 copying methods.

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
const arr = @import("b_array.zig");
const key = arr.key;
const sorter = @import("b_array_sort.zig");

fn needCallback(vm: *Vm, v: Value) Error!void {
    if (!v.isCallable()) return vm.throwError(.TypeError, "callback is not a function");
}

/// The element at i, if present.
inline fn elemIf(vm: *Vm, o: *Object, i: usize) Error!?Value {
    if (i < o.elems_len and !o.flags.exotic) {
        const v = o.elems[i];
        if (!v.isHole()) return v;
    }
    if (try props.has(vm, o, key(i))) return try props.get(vm, o, key(i));
    return null;
}

inline fn invoke(vm: *Vm, cb: Value, this_arg: Value, v: Value, i: usize, o: *Object) Error!Value {
    return calls.call(vm, cb, this_arg, &.{ v, Value.fromUsize(i), o.value() });
}

fn forEach(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const cb = u.arg(args, 0);
    try needCallback(vm, cb);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (try elemIf(vm, o, i)) |v| _ = try invoke(vm, cb, u.arg(args, 1), v, i, o);
    }
    return Value.undefined;
}

fn map(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const cb = u.arg(args, 0);
    try needCallback(vm, cb);
    const r = try arr.speciesCreate(vm, o, n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (try elemIf(vm, o, i)) |v| {
            try props.defineData(vm, r, key(i), try invoke(vm, cb, u.arg(args, 1), v, i, o), u.PropFlags.all);
        }
    }
    return r.value();
}

fn filter(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const cb = u.arg(args, 0);
    try needCallback(vm, cb);
    const r = try arr.speciesCreate(vm, o, 0);
    var at: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (try elemIf(vm, o, i)) |v| {
            if (ops.truthy(try invoke(vm, cb, u.arg(args, 1), v, i, o))) {
                try props.defineData(vm, r, key(at), v, u.PropFlags.all);
                at += 1;
            }
        }
    }
    return r.value();
}

fn every(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const cb = u.arg(args, 0);
    try needCallback(vm, cb);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (try elemIf(vm, o, i)) |v| {
            if (!ops.truthy(try invoke(vm, cb, u.arg(args, 1), v, i, o))) return Value.false;
        }
    }
    return Value.true;
}

fn some(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const cb = u.arg(args, 0);
    try needCallback(vm, cb);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (try elemIf(vm, o, i)) |v| {
            if (ops.truthy(try invoke(vm, cb, u.arg(args, 1), v, i, o))) return Value.true;
        }
    }
    return Value.false;
}

fn reduceImpl(vm: *Vm, this: Value, args: []const Value, right: bool) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const cb = u.arg(args, 0);
    try needCallback(vm, cb);
    var step: usize = 0;
    var acc: ?Value = if (args.len > 1) args[1] else null;
    while (step < n) : (step += 1) {
        const i = if (right) n - 1 - step else step;
        const v = (try elemIf(vm, o, i)) orelse continue;
        if (acc) |a| {
            acc = try calls.call(vm, cb, Value.undefined, &.{ a, v, Value.fromUsize(i), o.value() });
        } else acc = v;
    }
    return acc orelse vm.throwError(.TypeError, "Reduce of empty array with no initial value");
}
fn reduce(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return reduceImpl(vm, this, args, false);
}
fn reduceRight(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return reduceImpl(vm, this, args, true);
}

const FindMode = enum { value, index };

fn findImpl(vm: *Vm, this: Value, args: []const Value, backward: bool, mode: FindMode) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const cb = u.arg(args, 0);
    try needCallback(vm, cb);
    var step: usize = 0;
    while (step < n) : (step += 1) {
        const i = if (backward) n - 1 - step else step;
        const v = try props.get(vm, o, key(i));
        if (ops.truthy(try invoke(vm, cb, u.arg(args, 1), v, i, o))) {
            return if (mode == .value) v else Value.fromUsize(i);
        }
    }
    return if (mode == .value) Value.undefined else Value.fromInt(-1);
}
fn find(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return findImpl(vm, this, args, false, .value);
}
fn findIndex(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return findImpl(vm, this, args, false, .index);
}
fn findLast(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return findImpl(vm, this, args, true, .value);
}
fn findLastIndex(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return findImpl(vm, this, args, true, .index);
}

fn flatten(vm: *Vm, target: *Object, at: *usize, src: *Object, depth: f64, mapper: Value, this_arg: Value) Error!void {
    try vm.checkNativeStack();
    const n = try conv.lengthOf(vm, src);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var v = (try elemIf(vm, src, i)) orelse continue;
        if (!mapper.isUndefined()) v = try invoke(vm, mapper, this_arg, v, i, src);
        if (depth > 0 and try arr.isArrayValue(vm, v)) {
            try flatten(vm, target, at, v.asObject(), depth - 1, Value.undefined, Value.undefined);
        } else {
            try props.defineData(vm, target, key(at.*), v, u.PropFlags.all);
            at.* += 1;
        }
    }
}

fn flat(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const depth = if (u.arg(args, 0).isUndefined()) 1 else try conv.toIntegerOrInf(vm, args[0]);
    const r = try arr.speciesCreate(vm, o, 0);
    var at: usize = 0;
    try flatten(vm, r, &at, o, depth, Value.undefined, Value.undefined);
    return r.value();
}

fn flatMap(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    try needCallback(vm, u.arg(args, 0));
    const r = try arr.speciesCreate(vm, o, 0);
    var at: usize = 0;
    try flatten(vm, r, &at, o, 1, u.arg(args, 0), u.arg(args, 1));
    return r.value();
}

fn fill(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const start = try u.relativeIndex(vm, u.arg(args, 1), n, 0);
    const end = try u.relativeIndex(vm, u.arg(args, 2), n, n);
    var i = start;
    while (i < end) : (i += 1) try props.put(vm, o, key(i), u.arg(args, 0));
    return o.value();
}

fn copyWithin(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    var to = try u.relativeIndex(vm, u.arg(args, 0), n, 0);
    var from = try u.relativeIndex(vm, u.arg(args, 1), n, 0);
    const end = try u.relativeIndex(vm, u.arg(args, 2), n, n);
    var count = @min(if (end > from) end - from else 0, n - to);
    const backward = from < to and to < from + count;
    if (backward) {
        from += count;
        to += count;
    }
    while (count > 0) : (count -= 1) {
        const f = if (backward) from - 1 else from;
        const t = if (backward) to - 1 else to;
        if (try props.has(vm, o, key(f))) {
            try props.put(vm, o, key(t), try props.get(vm, o, key(f)));
        } else if (!try props.delete(vm, o, key(t))) return vm.throwError(.TypeError, "Cannot delete property");
        if (backward) {
            from -= 1;
            to -= 1;
        } else {
            from += 1;
            to += 1;
        }
    }
    return o.value();
}

fn atFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n: f64 = @floatFromInt(try conv.lengthOf(vm, o));
    var i = try conv.toIntegerOrInf(vm, u.arg(args, 0));
    if (i < 0) i += n;
    if (i < 0 or i >= n) return Value.undefined;
    return props.get(vm, o, key(@intFromFloat(i)));
}

/// Copies an array-like with holes read through as undefined, for the copying methods.
fn copied(vm: *Vm, o: *Object) Error!*Object {
    const n = try conv.lengthOf(vm, o);
    const r = try objmod.newArray(vm, &.{});
    try objmod.growElems(vm, r, n);
    var i: usize = 0;
    while (i < n) : (i += 1) try objmod.arrayPush(vm, r, try props.get(vm, o, key(i)));
    return r;
}

fn toReversed(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const r = try copied(vm, try conv.toObject(vm, this));
    std.mem.reverse(Value, r.elems[0..r.elems_len]);
    return r.value();
}

fn toSorted(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const cmp = u.arg(args, 0);
    if (!cmp.isUndefined() and !cmp.isCallable()) return vm.throwError(.TypeError, "The comparison function must be either a function or undefined");
    const r = try copied(vm, try conv.toObject(vm, this));
    try sorter.sortValues(vm, r.elems[0..r.elems_len], cmp, false);
    return r.value();
}

fn toSpliced(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const start = try u.relativeIndex(vm, u.arg(args, 0), n, 0);
    var skip: usize = 0;
    if (args.len == 1) {
        skip = n - start;
    } else if (args.len > 1) {
        const d = try conv.toIntegerOrInf(vm, args[1]);
        skip = @intFromFloat(@min(@max(d, 0), @as(f64, @floatFromInt(n - start))));
    }
    const r = try objmod.newArray(vm, &.{});
    var i: usize = 0;
    while (i < start) : (i += 1) try objmod.arrayPush(vm, r, try props.get(vm, o, key(i)));
    if (args.len > 2) {
        for (args[2..]) |v| try objmod.arrayPush(vm, r, v);
    }
    i = start + skip;
    while (i < n) : (i += 1) try objmod.arrayPush(vm, r, try props.get(vm, o, key(i)));
    return r.value();
}

fn withFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n: f64 = @floatFromInt(try conv.lengthOf(vm, o));
    var i = try conv.toIntegerOrInf(vm, u.arg(args, 0));
    if (i < 0) i += n;
    if (i < 0 or i >= n) return vm.throwError(.RangeError, "Invalid index");
    const r = try copied(vm, o);
    r.elems[@intFromFloat(i)] = u.arg(args, 1);
    return r.value();
}

pub fn init(vm: *Vm, p: *Object) Error!void {
    try u.method(vm, p, "forEach", 1, forEach);
    try u.method(vm, p, "map", 1, map);
    try u.method(vm, p, "filter", 1, filter);
    try u.method(vm, p, "every", 1, every);
    try u.method(vm, p, "some", 1, some);
    try u.method(vm, p, "reduce", 1, reduce);
    try u.method(vm, p, "reduceRight", 1, reduceRight);
    try u.method(vm, p, "find", 1, find);
    try u.method(vm, p, "findIndex", 1, findIndex);
    try u.method(vm, p, "findLast", 1, findLast);
    try u.method(vm, p, "findLastIndex", 1, findLastIndex);
    try u.method(vm, p, "flat", 0, flat);
    try u.method(vm, p, "flatMap", 1, flatMap);
    try u.method(vm, p, "fill", 1, fill);
    try u.method(vm, p, "copyWithin", 2, copyWithin);
    try u.method(vm, p, "at", 1, atFn);
    try u.method(vm, p, "toReversed", 0, toReversed);
    try u.method(vm, p, "toSorted", 1, toSorted);
    try u.method(vm, p, "toSpliced", 2, toSpliced);
    try u.method(vm, p, "with", 2, withFn);
    try u.method(vm, p, "sort", 1, sorter.sort);
}
