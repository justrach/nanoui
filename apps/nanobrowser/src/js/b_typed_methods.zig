//! %TypedArray%.prototype and the from/of statics.

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
const str = @import("string.zig");
const calls = @import("interp_call.zig");
const iter = @import("iter.zig");
const typed = @import("b_typed.zig");
const b_array = @import("b_array_iter.zig");

fn thisT(vm: *Vm, this: Value) Error!*Object {
    if (this.isObject() and this.asObject().class == .typedarray) return this.asObject();
    return vm.throwError(.TypeError, "this is not a typed array.");
}

inline fn at(vm: *Vm, o: *Object, i: usize) Error!Value {
    return typed.getIndex(vm, o, @intCast(i));
}

fn create(vm: *Vm, like: *Object, n: usize) Error!*Object {
    const c = try u.speciesConstructor(vm, like, vm.protos.typed_ctor[@backingInt(like.payload.typed.kind)]);
    const r = try calls.construct(vm, c, &.{Value.fromUsize(n)}, c);
    if (!r.isObject() or r.asObject().class != .typedarray) return vm.throwError(.TypeError, "species did not make a typed array");
    return r.asObject();
}

fn getBuffer(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return (try thisT(vm, this)).payload.typed.buffer.value();
}
fn getByteLength(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const o = try thisT(vm, this);
    return Value.fromUsize(typed.length(o) * typed.elemSize(o.payload.typed.kind));
}
fn getByteOffset(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return Value.fromUsize((try thisT(vm, this)).payload.typed.offset);
}
fn getLength(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return Value.fromUsize(typed.length(try thisT(vm, this)));
}
fn getTag(vm: *Vm, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().class != .typedarray) return Value.undefined;
    const name = typed.kind_names[@backingInt(this.asObject().payload.typed.kind)];
    return Value.fromString(try str.intern(vm, name));
}

fn atFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisT(vm, this);
    const len: f64 = @floatFromInt(typed.length(o));
    var n = try conv.toIntegerOrInf(vm, u.arg(args, 0));
    if (n < 0) n += len;
    if (n < 0 or n >= len) return Value.undefined;
    return at(vm, o, @intFromFloat(n));
}

fn fill(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisT(vm, this);
    const len = typed.length(o);
    const start = try u.relativeIndex(vm, u.arg(args, 1), len, 0);
    const end = try u.relativeIndex(vm, u.arg(args, 2), len, len);
    var i = start;
    while (i < end) : (i += 1) try typed.setIndex(vm, o, @intCast(i), u.arg(args, 0));
    return this;
}

const Pred = enum { every, some, find, find_index, find_last, find_last_index, for_each };

fn callbackLoop(comptime mode: Pred) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, args: []const Value) Error!Value {
            const o = try thisT(vm, this);
            const cb = u.arg(args, 0);
            if (!cb.isCallable()) return vm.throwError(.TypeError, "callback is not a function");
            const len = typed.length(o);
            const backward = mode == .find_last or mode == .find_last_index;
            var n: usize = 0;
            while (n < len) : (n += 1) {
                const i = if (backward) len - 1 - n else n;
                const v = try at(vm, o, i);
                const r = ops.truthy(try calls.call(vm, cb, u.arg(args, 1), &.{ v, Value.fromUsize(i), this }));
                switch (mode) {
                    .every => if (!r) return Value.false,
                    .some => if (r) return Value.true,
                    .find, .find_last => if (r) return v,
                    .find_index, .find_last_index => if (r) return Value.fromUsize(i),
                    .for_each => {},
                }
            }
            return switch (mode) {
                .every => Value.true,
                .some => Value.false,
                .find_index, .find_last_index => Value.fromInt(-1),
                else => Value.undefined,
            };
        }
    }.f;
}

fn indexOfImpl(vm: *Vm, this: Value, args: []const Value, mode: enum { index_of, last, includes }) Error!Value {
    const o = try thisT(vm, this);
    const len = typed.length(o);
    const none: Value = if (mode == .includes) Value.false else Value.fromInt(-1);
    if (len == 0) return none;
    if (mode == .last) {
        var n: f64 = @floatFromInt(len - 1);
        if (args.len > 1) {
            const k = try conv.toIntegerOrInf(vm, args[1]);
            n = if (k >= 0) @min(k, n) else @as(f64, @floatFromInt(len)) + k;
        }
        if (n < 0) return none;
        var i: usize = @intFromFloat(n);
        while (true) {
            if (try ops.strictEquals(vm, try at(vm, o, i), u.arg(args, 0))) return Value.fromUsize(i);
            if (i == 0) return none;
            i -= 1;
        }
    }
    var i = try u.relativeIndex(vm, u.arg(args, 1), len, 0);
    while (i < len) : (i += 1) {
        const v = try at(vm, o, i);
        if (mode == .includes) {
            if (conv.sameValueZero(vm, v, u.arg(args, 0))) return Value.true;
        } else if (try ops.strictEquals(vm, v, u.arg(args, 0))) return Value.fromUsize(i);
    }
    return none;
}
fn indexOf(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return indexOfImpl(vm, this, args, .index_of);
}
fn lastIndexOf(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return indexOfImpl(vm, this, args, .last);
}
fn includes(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return indexOfImpl(vm, this, args, .includes);
}

fn join(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisT(vm, this);
    const sep = if (u.arg(args, 0).isUndefined()) vm.char_strs[','] else try conv.toStr(vm, args[0]);
    var b = str.Builder.init(vm);
    defer b.deinit();
    var i: usize = 0;
    const len = typed.length(o);
    while (i < len) : (i += 1) {
        if (i != 0) try b.str(sep);
        try b.str(try conv.toStr(vm, try at(vm, o, i)));
    }
    return Value.fromString(try b.finish());
}

fn map(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisT(vm, this);
    const cb = u.arg(args, 0);
    if (!cb.isCallable()) return vm.throwError(.TypeError, "callback is not a function");
    const len = typed.length(o);
    const r = try create(vm, o, len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const v = try calls.call(vm, cb, u.arg(args, 1), &.{ try at(vm, o, i), Value.fromUsize(i), this });
        try typed.setIndex(vm, r, @intCast(i), v);
    }
    return r.value();
}

fn filter(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisT(vm, this);
    const cb = u.arg(args, 0);
    if (!cb.isCallable()) return vm.throwError(.TypeError, "callback is not a function");
    var kept: std.ArrayList(Value) = .empty;
    defer kept.deinit(vm.gpa);
    const len = typed.length(o);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const v = try at(vm, o, i);
        if (ops.truthy(try calls.call(vm, cb, u.arg(args, 1), &.{ v, Value.fromUsize(i), this }))) try kept.append(vm.gpa, v);
    }
    const r = try create(vm, o, kept.items.len);
    for (kept.items, 0..) |v, j| try typed.setIndex(vm, r, @intCast(j), v);
    return r.value();
}

fn reduceImpl(vm: *Vm, this: Value, args: []const Value, right: bool) Error!Value {
    const o = try thisT(vm, this);
    const cb = u.arg(args, 0);
    if (!cb.isCallable()) return vm.throwError(.TypeError, "callback is not a function");
    const len = typed.length(o);
    var n: usize = 0;
    var acc: Value = undefined;
    if (args.len > 1) {
        acc = args[1];
    } else {
        if (len == 0) return vm.throwError(.TypeError, "Reduce of empty array with no initial value");
        acc = try at(vm, o, if (right) len - 1 else 0);
        n = 1;
    }
    while (n < len) : (n += 1) {
        const i = if (right) len - 1 - n else n;
        acc = try calls.call(vm, cb, Value.undefined, &.{ acc, try at(vm, o, i), Value.fromUsize(i), this });
    }
    return acc;
}
fn reduce(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return reduceImpl(vm, this, args, false);
}
fn reduceRight(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return reduceImpl(vm, this, args, true);
}

fn reverse(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const o = try thisT(vm, this);
    const len = typed.length(o);
    var i: usize = 0;
    while (i < len / 2) : (i += 1) {
        const a = try at(vm, o, i);
        const b = try at(vm, o, len - 1 - i);
        try typed.setIndex(vm, o, @intCast(i), b);
        try typed.setIndex(vm, o, @intCast(len - 1 - i), a);
    }
    return this;
}

fn setFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisT(vm, this);
    const offset = try conv.toIntegerOrInf(vm, u.arg(args, 1));
    if (offset < 0) return vm.throwError(.RangeError, "offset is out of bounds");
    const off: usize = @intFromFloat(offset);
    const src = try conv.toObject(vm, u.arg(args, 0));
    const n = try conv.lengthOf(vm, src);
    if (off + n > typed.length(o)) return vm.throwError(.RangeError, "offset is out of bounds");
    // Snapshot first: source and target may share a buffer.
    const tmp = try vm.gpa.alloc(Value, n);
    defer vm.gpa.free(tmp);
    for (tmp, 0..) |*t, i| t.* = try props.get(vm, src, PropKey.fromIndex(@intCast(i)));
    for (tmp, 0..) |v, i| try typed.setIndex(vm, o, @intCast(off + i), v);
    return Value.undefined;
}

fn slice(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisT(vm, this);
    const len = typed.length(o);
    const start = try u.relativeIndex(vm, u.arg(args, 0), len, 0);
    const end = try u.relativeIndex(vm, u.arg(args, 1), len, len);
    const n = if (end > start) end - start else 0;
    const r = try create(vm, o, n);
    var i: usize = 0;
    while (i < n) : (i += 1) try typed.setIndex(vm, r, @intCast(i), try at(vm, o, start + i));
    return r.value();
}

fn subarray(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisT(vm, this);
    const d = o.payload.typed;
    const len = typed.length(o);
    const start = try u.relativeIndex(vm, u.arg(args, 0), len, 0);
    const end = try u.relativeIndex(vm, u.arg(args, 1), len, len);
    const n = if (end > start) end - start else 0;
    const c = try u.speciesConstructor(vm, o, vm.protos.typed_ctor[@backingInt(d.kind)]);
    const offset = d.offset + start * typed.elemSize(d.kind);
    return calls.construct(vm, c, &.{ d.buffer.value(), Value.fromUsize(offset), Value.fromUsize(n) }, c);
}

fn copyWithin(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisT(vm, this);
    const len = typed.length(o);
    const to = try u.relativeIndex(vm, u.arg(args, 0), len, 0);
    const from = try u.relativeIndex(vm, u.arg(args, 1), len, 0);
    const end = try u.relativeIndex(vm, u.arg(args, 2), len, len);
    const size = typed.elemSize(o.payload.typed.kind);
    const n = @min(if (end > from) end - from else 0, len - to);
    if (n == 0) return this;
    const b = typed.bytesOf(o);
    if (to < from) {
        std.mem.copyForwards(u8, b[to * size ..][0 .. n * size], b[from * size ..][0 .. n * size]);
    } else {
        std.mem.copyBackwards(u8, b[to * size ..][0 .. n * size], b[from * size ..][0 .. n * size]);
    }
    return this;
}

fn valuesSorted(vm: *Vm, o: *Object, cmp: Value) Error![]Value {
    const len = typed.length(o);
    const vals = try vm.gpa.alloc(Value, len);
    errdefer vm.gpa.free(vals);
    for (vals, 0..) |*v, i| v.* = try at(vm, o, i);
    try @import("b_array_sort.zig").sortValues(vm, vals, cmp, true);
    return vals;
}

fn sort(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisT(vm, this);
    const cmp = u.arg(args, 0);
    if (!cmp.isUndefined() and !cmp.isCallable()) return vm.throwError(.TypeError, "The comparison function must be either a function or undefined");
    const vals = try valuesSorted(vm, o, cmp);
    defer vm.gpa.free(vals);
    for (vals, 0..) |v, i| try typed.setIndex(vm, o, @intCast(i), v);
    return this;
}

fn toSorted(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisT(vm, this);
    const vals = try valuesSorted(vm, o, u.arg(args, 0));
    defer vm.gpa.free(vals);
    const r = try typed.newTyped(vm, o.payload.typed.kind, vals.len);
    for (vals, 0..) |v, i| try typed.setIndex(vm, r, @intCast(i), v);
    return r.value();
}

fn toReversed(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const o = try thisT(vm, this);
    const len = typed.length(o);
    const r = try typed.newTyped(vm, o.payload.typed.kind, len);
    var i: usize = 0;
    while (i < len) : (i += 1) try typed.setIndex(vm, r, @intCast(i), try at(vm, o, len - 1 - i));
    return r.value();
}

fn withFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisT(vm, this);
    const len = typed.length(o);
    const flen: f64 = @floatFromInt(len);
    var n = try conv.toIntegerOrInf(vm, u.arg(args, 0));
    if (n < 0) n += flen;
    if (n < 0 or n >= flen) return vm.throwError(.RangeError, "Invalid typed array index");
    const r = try typed.newTyped(vm, o.payload.typed.kind, len);
    var i: usize = 0;
    while (i < len) : (i += 1) try typed.setIndex(vm, r, @intCast(i), try at(vm, o, i));
    try typed.setIndex(vm, r, @intFromFloat(n), u.arg(args, 1));
    return r.value();
}

fn iterFn(comptime kind: u8) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, _: []const Value) Error!Value {
            _ = try thisT(vm, this);
            return b_array.makeArrayIter(vm, this, kind);
        }
    }.f;
}

fn fromFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    if (!this.isConstructor()) return vm.throwError(.TypeError, "this is not a constructor");
    const mapper = u.arg(args, 1);
    if (!mapper.isUndefined() and !mapper.isCallable()) return vm.throwError(.TypeError, "map function is not callable");
    const list = try objmod.newArray(vm, &.{});
    const src = u.arg(args, 0);
    const o = try conv.toObject(vm, src);
    const m = try props.get(vm, o, PropKey.fromSymbol(vm.sym.iterator));
    if (m.isNullish()) {
        const n = try conv.lengthOf(vm, o);
        var i: usize = 0;
        while (i < n) : (i += 1) try objmod.arrayPush(vm, list, try props.get(vm, o, PropKey.fromIndex(@intCast(i))));
    } else {
        try iter.appendAll(vm, list, src);
    }
    const r = try calls.construct(vm, this, &.{Value.fromUsize(list.arr_len)}, this);
    var i: u32 = 0;
    while (i < list.arr_len) : (i += 1) {
        var v = list.elems[i];
        if (!mapper.isUndefined()) v = try calls.call(vm, mapper, u.arg(args, 2), &.{ v, Value.fromUsize(i) });
        try props.put(vm, r.asObject(), PropKey.fromIndex(i), v);
    }
    return r;
}

fn ofFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    if (!this.isConstructor()) return vm.throwError(.TypeError, "this is not a constructor");
    const r = try calls.construct(vm, this, &.{Value.fromUsize(args.len)}, this);
    for (args, 0..) |v, i| try props.put(vm, r.asObject(), PropKey.fromIndex(@intCast(i)), v);
    return r;
}

pub fn init(vm: *Vm, base: *Object) Error!void {
    const p = vm.protos.typed_array;
    try u.method(vm, base, "from", 1, fromFn);
    try u.method(vm, base, "of", 0, ofFn);
    try u.symGetter(vm, base, vm.sym.species, "get [Symbol.species]", u.returnThis);
    try u.getter(vm, p, "buffer", getBuffer);
    try u.getter(vm, p, "byteLength", getByteLength);
    try u.getter(vm, p, "byteOffset", getByteOffset);
    try u.getter(vm, p, "length", getLength);
    try u.symGetter(vm, p, vm.sym.toStringTag, "get [Symbol.toStringTag]", getTag);
    try u.method(vm, p, "at", 1, atFn);
    try u.method(vm, p, "copyWithin", 2, copyWithin);
    try u.method(vm, p, "entries", 0, iterFn(2));
    try u.method(vm, p, "every", 1, callbackLoop(.every));
    try u.method(vm, p, "fill", 1, fill);
    try u.method(vm, p, "filter", 1, filter);
    try u.method(vm, p, "find", 1, callbackLoop(.find));
    try u.method(vm, p, "findIndex", 1, callbackLoop(.find_index));
    try u.method(vm, p, "findLast", 1, callbackLoop(.find_last));
    try u.method(vm, p, "findLastIndex", 1, callbackLoop(.find_last_index));
    try u.method(vm, p, "forEach", 1, callbackLoop(.for_each));
    try u.method(vm, p, "includes", 1, includes);
    try u.method(vm, p, "indexOf", 1, indexOf);
    try u.method(vm, p, "join", 1, join);
    try u.method(vm, p, "keys", 0, iterFn(0));
    try u.method(vm, p, "lastIndexOf", 1, lastIndexOf);
    try u.method(vm, p, "map", 1, map);
    try u.method(vm, p, "reduce", 1, reduce);
    try u.method(vm, p, "reduceRight", 1, reduceRight);
    try u.method(vm, p, "reverse", 0, reverse);
    try u.method(vm, p, "set", 1, setFn);
    try u.method(vm, p, "slice", 2, slice);
    try u.method(vm, p, "some", 1, callbackLoop(.some));
    try u.method(vm, p, "sort", 1, sort);
    try u.method(vm, p, "subarray", 2, subarray);
    try u.method(vm, p, "toLocaleString", 0, join);
    try u.method(vm, p, "toReversed", 0, toReversed);
    try u.method(vm, p, "toSorted", 1, toSorted);
    try u.method(vm, p, "with", 2, withFn);
    try u.method(vm, p, "values", 0, iterFn(1));
    const values = try props.get(vm, p, try str.keyFromBytes(vm, "values"));
    try props.defineData(vm, p, PropKey.fromSymbol(vm.sym.iterator), values, u.PropFlags.hidden);
    const ts = try props.get(vm, vm.protos.array, vm.k.toString);
    try props.defineData(vm, p, vm.k.toString, ts, u.PropFlags.hidden);
}
