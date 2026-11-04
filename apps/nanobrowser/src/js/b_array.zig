//! Array: the constructor, statics, and the methods that don't take callbacks.
//! Everything works on any array-like; plain arrays take fast paths where it shows.

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
const b_array2 = @import("b_array2.zig");
const b_iter = @import("b_array_iter.zig");

pub inline fn key(i: usize) PropKey {
    return PropKey.fromIndex(@intCast(i));
}

/// Dense and free of surprises: storage can be touched directly.
pub inline fn isPlain(o: *Object) bool {
    return o.class == .array and !o.flags.has_sparse and !o.flags.elems_frozen and !o.flags.elems_sealed and o.flags.extensible and !o.flags.length_readonly and o.elems_len == o.arr_len;
}

pub fn setLen(vm: *Vm, o: *Object, n: usize) Error!void {
    if (o.class == .array) {
        if (!try props.setArrayLengthValue(vm, o, Value.fromUsize(n))) {
            return vm.throwError(.TypeError, "Cannot set array length");
        }
        return;
    }
    try props.put(vm, o, vm.k.length, Value.fromUsize(n));
}

fn arrayCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const proto = if (vm.new_target.isUndefined()) vm.protos.array else try calls.protoFromNewTarget(vm, vm.protos.array);
    const a = try objmod.create(vm, proto, .array);
    if (args.len == 1 and args[0].isNumber()) {
        const n = args[0].asNumber();
        const len: u32 = @intFromFloat(if (n >= 0 and n <= 4294967295.0 and n == std.math.trunc(n)) n else return vm.throwError(.RangeError, "Invalid array length"));
        // Reasonable sizes are preallocated as holes, so filling from any end stays dense.
        if (len <= 1 << 24) {
            try objmod.growElems(vm, a, len);
            @memset(a.elems[0..len], Value.hole);
            a.elems_len = len;
        }
        a.arr_len = len;
        return a.value();
    }
    if (args.len != 0) {
        try objmod.growElems(vm, a, args.len);
        @memcpy(a.elems[0..args.len], args);
        a.elems_len = @intCast(args.len);
        a.arr_len = a.elems_len;
    }
    return a.value();
}

pub fn isArrayValue(vm: *Vm, v: Value) Error!bool {
    if (!v.isObject()) return false;
    var o = v.asObject();
    while (o.class == .proxy) {
        const d = o.payload.proxy;
        o = d.target orelse return vm.throwError(.TypeError, "Cannot perform 'IsArray' on a proxy that has been revoked");
    }
    return o.class == .array;
}

fn isArrayFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(try isArrayValue(vm, u.arg(args, 0)));
}

fn ofFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    if (this.isObject() and this.asObject() != vm.protos.array_ctor and this.isConstructor()) {
        const r = try calls.construct(vm, this, &.{Value.fromUsize(args.len)}, this);
        for (args, 0..) |v, i| try props.defineData(vm, r.asObject(), key(i), v, u.PropFlags.all);
        try setLen(vm, r.asObject(), args.len);
        return r;
    }
    return (try objmod.newArray(vm, args)).value();
}

fn fromFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const src = u.arg(args, 0);
    const mapper = u.arg(args, 1);
    if (!mapper.isUndefined() and !mapper.isCallable()) return vm.throwError(.TypeError, "Array.from: map function is not callable");
    const this_arg = u.arg(args, 2);
    const use_ctor = this.isConstructor() and this.asObject() != vm.protos.array_ctor;
    const out = if (use_ctor) (try calls.construct(vm, this, &.{}, this)).asObject() else try objmod.newArray(vm, &.{});
    const Ctx = struct {
        vm: *Vm,
        out: *Object,
        mapper: Value,
        this_arg: Value,
        i: *usize,
        fn add(c: @This(), v0: Value) Error!void {
            var v = v0;
            if (!c.mapper.isUndefined()) v = try calls.call(c.vm, c.mapper, c.this_arg, &.{ v, Value.fromUsize(c.i.*) });
            try props.defineData(c.vm, c.out, key(c.i.*), v, u.PropFlags.all);
            c.i.* += 1;
        }
    };
    var i: usize = 0;
    const ctx = Ctx{ .vm = vm, .out = out, .mapper = mapper, .this_arg = this_arg, .i = &i };
    const m = if (src.isNullish()) Value.undefined else try props.getV(vm, src, PropKey.fromSymbol(vm.sym.iterator));
    if (src.isNullish()) return vm.throwError(.TypeError, "Array.from requires an array-like or iterable");
    if (!m.isNullish()) {
        try iter.forEach(vm, src, ctx, Ctx.add);
    } else {
        const o = try conv.toObject(vm, src);
        const n = try conv.lengthOf(vm, o);
        var k: usize = 0;
        while (k < n) : (k += 1) try ctx.add(try props.get(vm, o, key(k)));
    }
    try setLen(vm, out, i);
    return out.value();
}

fn push(vm: *Vm, this: Value, args: []const Value) Error!Value {
    if (this.isObject() and isPlain(this.asObject())) {
        const a = this.asObject();
        const n = @as(usize, a.elems_len) + args.len;
        if (n > a.elems_cap) try objmod.growElems(vm, a, n);
        @memcpy(a.elems[a.elems_len..][0..args.len], args);
        a.elems_len = @intCast(n);
        a.arr_len = a.elems_len;
        return Value.fromUsize(n);
    }
    const o = try conv.toObject(vm, this);
    var n = try conv.lengthOf(vm, o);
    for (args) |v| {
        try props.put(vm, o, key(n), v);
        n += 1;
    }
    try setLen(vm, o, n);
    return Value.fromUsize(n);
}

fn pop(vm: *Vm, this: Value, _: []const Value) Error!Value {
    if (this.isObject() and isPlain(this.asObject())) {
        const a = this.asObject();
        if (a.elems_len == 0) return Value.undefined;
        const v = a.elems[a.elems_len - 1];
        a.elems_len -= 1;
        a.arr_len = a.elems_len;
        if (!v.isHole()) return v;
        return props.get(vm, a, key(a.arr_len));
    }
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    if (n == 0) {
        try setLen(vm, o, 0);
        return Value.undefined;
    }
    const v = try props.get(vm, o, key(n - 1));
    if (!try props.delete(vm, o, key(n - 1))) return vm.throwError(.TypeError, "Cannot delete property");
    try setLen(vm, o, n - 1);
    return v;
}

fn shift(vm: *Vm, this: Value, _: []const Value) Error!Value {
    if (this.isObject() and isPlain(this.asObject())) {
        const a = this.asObject();
        if (a.elems_len == 0) return Value.undefined;
        const v = a.elems[0];
        std.mem.copyForwards(Value, a.elems[0 .. a.elems_len - 1], a.elems[1..a.elems_len]);
        a.elems_len -= 1;
        a.arr_len = a.elems_len;
        return if (v.isHole()) Value.undefined else v;
    }
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    if (n == 0) {
        try setLen(vm, o, 0);
        return Value.undefined;
    }
    const first = try props.get(vm, o, key(0));
    var i: usize = 1;
    while (i < n) : (i += 1) {
        if (try props.has(vm, o, key(i))) {
            try props.put(vm, o, key(i - 1), try props.get(vm, o, key(i)));
        } else if (!try props.delete(vm, o, key(i - 1))) return vm.throwError(.TypeError, "Cannot delete property");
    }
    if (!try props.delete(vm, o, key(n - 1))) return vm.throwError(.TypeError, "Cannot delete property");
    try setLen(vm, o, n - 1);
    return first;
}

fn unshift(vm: *Vm, this: Value, args: []const Value) Error!Value {
    if (this.isObject() and isPlain(this.asObject())) {
        const a = this.asObject();
        const n = @as(usize, a.elems_len) + args.len;
        if (n > a.elems_cap) try objmod.growElems(vm, a, n);
        std.mem.copyBackwards(Value, a.elems[args.len..n], a.elems[0..a.elems_len]);
        @memcpy(a.elems[0..args.len], args);
        a.elems_len = @intCast(n);
        a.arr_len = a.elems_len;
        return Value.fromUsize(n);
    }
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    if (args.len != 0) {
        var i = n;
        while (i > 0) : (i -= 1) {
            if (try props.has(vm, o, key(i - 1))) {
                try props.put(vm, o, key(i - 1 + args.len), try props.get(vm, o, key(i - 1)));
            } else if (!try props.delete(vm, o, key(i - 1 + args.len))) return vm.throwError(.TypeError, "Cannot delete property");
        }
        for (args, 0..) |v, j| try props.put(vm, o, key(j), v);
    }
    try setLen(vm, o, n + args.len);
    return Value.fromUsize(n + args.len);
}

/// ArraySpeciesCreate.
pub fn speciesCreate(vm: *Vm, o: *Object, n: usize) Error!*Object {
    if (!try isArrayValue(vm, o.value())) return newWithLength(vm, n);
    var c = try props.get(vm, o, vm.k.constructor);
    if (c.isObject()) {
        if (c.asObject() == vm.protos.array_ctor) return newWithLength(vm, n);
        c = try props.get(vm, c.asObject(), PropKey.fromSymbol(vm.sym.species));
        if (c.isNull()) c = Value.undefined;
    }
    if (c.isUndefined()) return newWithLength(vm, n);
    if (!c.isConstructor()) return vm.throwError(.TypeError, "object.constructor[Symbol.species] is not a constructor");
    return (try calls.construct(vm, c, &.{Value.fromUsize(n)}, c)).asObject();
}

fn newWithLength(vm: *Vm, n: usize) Error!*Object {
    const a = try objmod.newArray(vm, &.{});
    a.arr_len = @intCast(n);
    return a;
}

fn slice(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const start = try u.relativeIndex(vm, u.arg(args, 0), n, 0);
    const end = try u.relativeIndex(vm, u.arg(args, 1), n, n);
    const count = if (end > start) end - start else 0;
    const r = try speciesCreate(vm, o, count);
    if (isPlain(o) and r.class == .array and r.shape.proto == vm.protos.array and end <= o.elems_len) {
        try objmod.growElems(vm, r, count);
        @memcpy(r.elems[0..count], o.elems[start..][0..count]);
        r.elems_len = @intCast(count);
        r.arr_len = r.elems_len;
        return r.value();
    }
    var k: usize = 0;
    while (k < count) : (k += 1) {
        if (try props.has(vm, o, key(start + k))) {
            try props.defineData(vm, r, key(k), try props.get(vm, o, key(start + k)), u.PropFlags.all);
        }
    }
    try setLen(vm, r, count);
    return r.value();
}

fn splice(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const start = try u.relativeIndex(vm, u.arg(args, 0), n, 0);
    const items = if (args.len > 2) args[2..] else args[0..0];
    var del: usize = 0;
    if (args.len == 1) {
        del = n - start;
    } else if (args.len > 1) {
        const d = try conv.toIntegerOrInf(vm, args[1]);
        del = @intFromFloat(@min(@max(d, 0), @as(f64, @floatFromInt(n - start))));
    }
    const removed = try speciesCreate(vm, o, del);
    if (isPlain(o) and removed.class == .array and removed.shape.proto == vm.protos.array) {
        try objmod.growElems(vm, removed, del);
        @memcpy(removed.elems[0..del], o.elems[start..][0..del]);
        removed.elems_len = @intCast(del);
        removed.arr_len = removed.elems_len;
        const new_len = n - del + items.len;
        if (new_len > o.elems_cap) try objmod.growElems(vm, o, new_len);
        const tail = n - start - del;
        if (items.len < del) {
            std.mem.copyForwards(Value, o.elems[start + items.len ..][0..tail], o.elems[start + del ..][0..tail]);
        } else if (items.len > del) {
            std.mem.copyBackwards(Value, o.elems[start + items.len ..][0..tail], o.elems[start + del ..][0..tail]);
        }
        @memcpy(o.elems[start..][0..items.len], items);
        o.elems_len = @intCast(new_len);
        o.arr_len = o.elems_len;
        return removed.value();
    }
    var k: usize = 0;
    while (k < del) : (k += 1) {
        if (try props.has(vm, o, key(start + k))) {
            try props.defineData(vm, removed, key(k), try props.get(vm, o, key(start + k)), u.PropFlags.all);
        }
    }
    try setLen(vm, removed, del);
    if (items.len < del) {
        k = start;
        while (k < n - del) : (k += 1) {
            if (try props.has(vm, o, key(k + del))) {
                try props.put(vm, o, key(k + items.len), try props.get(vm, o, key(k + del)));
            } else if (!try props.delete(vm, o, key(k + items.len))) return vm.throwError(.TypeError, "Cannot delete property");
        }
        k = n;
        while (k > n - del + items.len) : (k -= 1) {
            if (!try props.delete(vm, o, key(k - 1))) return vm.throwError(.TypeError, "Cannot delete property");
        }
    } else if (items.len > del) {
        k = n - del;
        while (k > start) : (k -= 1) {
            if (try props.has(vm, o, key(k + del - 1))) {
                try props.put(vm, o, key(k + items.len - 1), try props.get(vm, o, key(k + del - 1)));
            } else if (!try props.delete(vm, o, key(k + items.len - 1))) return vm.throwError(.TypeError, "Cannot delete property");
        }
    }
    for (items, 0..) |v, j| try props.put(vm, o, key(start + j), v);
    try setLen(vm, o, n - del + items.len);
    return removed.value();
}

fn concat(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const r = try speciesCreate(vm, o, 0);
    var at: usize = 0;
    var idx: usize = 0;
    const total = args.len + 1;
    while (idx < total) : (idx += 1) {
        const item = if (idx == 0) o.value() else args[idx - 1];
        var spread = false;
        if (item.isObject()) {
            const s = try props.get(vm, item.asObject(), PropKey.fromSymbol(vm.sym.isConcatSpreadable));
            spread = if (s.isUndefined()) try isArrayValue(vm, item) else ops.truthy(s);
        }
        if (!spread) {
            try props.defineData(vm, r, key(at), item, u.PropFlags.all);
            at += 1;
            continue;
        }
        const src = item.asObject();
        const n = try conv.lengthOf(vm, src);
        if (isPlain(src) and isPlain(r) and at == r.elems_len) {
            try objmod.growElems(vm, r, at + n);
            @memcpy(r.elems[at..][0..n], src.elems[0..n]);
            r.elems_len = @intCast(at + n);
            r.arr_len = r.elems_len;
            at += n;
            continue;
        }
        var k: usize = 0;
        while (k < n) : (k += 1) {
            if (try props.has(vm, src, key(k))) {
                try props.defineData(vm, r, key(at), try props.get(vm, src, key(k)), u.PropFlags.all);
            }
            at += 1;
        }
    }
    try setLen(vm, r, at);
    return r.value();
}

pub fn joinImpl(vm: *Vm, o: *Object, sep: *str.JSString) Error!Value {
    // A cycle joins as the empty string.
    for (vm.visiting.items) |x| {
        if (x == o) return Value.fromString(vm.empty);
    }
    try vm.checkNativeStack();
    try vm.visiting.append(vm.gpa, o);
    defer _ = vm.visiting.pop();
    const n = try conv.lengthOf(vm, o);
    var b = str.Builder.init(vm);
    defer b.deinit();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i != 0) try b.str(sep);
        const v = try props.get(vm, o, key(i));
        if (!v.isNullish()) try b.str(try conv.toStr(vm, v));
    }
    return Value.fromString(try b.finish());
}

fn join(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const sep = if (u.arg(args, 0).isUndefined()) vm.char_strs[','] else try conv.toStr(vm, args[0]);
    return joinImpl(vm, o, sep);
}

fn toStringFn(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const f = try props.get(vm, o, vm.k.join);
    if (f.isCallable()) return calls.call(vm, f, o.value(), &.{});
    return @import("b_object.zig").toStringFn(vm, o.value(), &.{});
}

fn toLocaleString(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    var b = str.Builder.init(vm);
    defer b.deinit();
    const name = try str.keyFromBytes(vm, "toLocaleString");
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i != 0) try b.byte(',');
        const v = try props.get(vm, o, key(i));
        if (v.isNullish()) continue;
        const f = try props.getV(vm, v, name);
        try b.str(try conv.toStr(vm, try calls.call(vm, f, v, &.{})));
    }
    return Value.fromString(try b.finish());
}

fn reverse(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    if (isPlain(o)) {
        std.mem.reverse(Value, o.elems[0..o.elems_len]);
        return o.value();
    }
    const n = try conv.lengthOf(vm, o);
    var i: usize = 0;
    while (i < n / 2) : (i += 1) {
        const j = n - 1 - i;
        const hi = try props.has(vm, o, key(i));
        const hj = try props.has(vm, o, key(j));
        const a = try props.get(vm, o, key(i));
        const b = try props.get(vm, o, key(j));
        if (hj) try props.put(vm, o, key(i), b) else _ = try props.delete(vm, o, key(i));
        if (hi) try props.put(vm, o, key(j), a) else _ = try props.delete(vm, o, key(j));
    }
    return o.value();
}

const SearchMode = enum { index_of, includes };

fn searchFrom(vm: *Vm, o: *Object, target: Value, from_v: Value, mode: SearchMode) Error!Value {
    const n = try conv.lengthOf(vm, o);
    const none = if (mode == .includes) Value.false else Value.fromInt(-1);
    if (n == 0) return none;
    var i = try u.relativeIndex(vm, from_v, n, 0);
    while (i < n) : (i += 1) {
        if (mode == .includes) {
            const v = if (i < o.elems_len and !o.flags.exotic and !o.elems[i].isHole()) o.elems[i] else try props.get(vm, o, key(i));
            if (conv.sameValueZero(vm, v, target)) return Value.true;
        } else {
            if (i < o.elems_len and !o.flags.exotic and !o.elems[i].isHole()) {
                if (try ops.strictEquals(vm, o.elems[i], target)) return Value.fromUsize(i);
            } else if (try props.has(vm, o, key(i))) {
                if (try ops.strictEquals(vm, try props.get(vm, o, key(i)), target)) return Value.fromUsize(i);
            }
        }
    }
    return none;
}

fn indexOf(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return searchFrom(vm, try conv.toObject(vm, this), u.arg(args, 0), u.arg(args, 1), .index_of);
}
fn includes(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return searchFrom(vm, try conv.toObject(vm, this), u.arg(args, 0), u.arg(args, 1), .includes);
}

fn lastIndexOf(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    if (n == 0) return Value.fromInt(-1);
    var f: f64 = @floatFromInt(n - 1);
    if (args.len > 1) {
        const k = try conv.toIntegerOrInf(vm, args[1]);
        f = if (k >= 0) @min(k, f) else @as(f64, @floatFromInt(n)) + k;
    }
    if (f < 0) return Value.fromInt(-1);
    var i: usize = @intFromFloat(f);
    while (true) {
        if (try props.has(vm, o, key(i))) {
            if (try ops.strictEquals(vm, try props.get(vm, o, key(i)), u.arg(args, 0))) return Value.fromUsize(i);
        }
        if (i == 0) return Value.fromInt(-1);
        i -= 1;
    }
}

pub fn init(vm: *Vm) Error!void {
    const p = vm.protos.array;
    const c = try u.ctor(vm, "Array", 1, arrayCtor, p);
    vm.protos.array_ctor = c;
    try u.method(vm, c, "isArray", 1, isArrayFn);
    try u.method(vm, c, "of", 0, ofFn);
    try u.method(vm, c, "from", 1, fromFn);
    try u.symGetter(vm, c, vm.sym.species, "get [Symbol.species]", u.returnThis);
    try u.method(vm, p, "push", 1, push);
    try u.method(vm, p, "pop", 0, pop);
    try u.method(vm, p, "shift", 0, shift);
    try u.method(vm, p, "unshift", 1, unshift);
    try u.method(vm, p, "slice", 2, slice);
    try u.method(vm, p, "splice", 2, splice);
    try u.method(vm, p, "concat", 1, concat);
    try u.method(vm, p, "join", 1, join);
    try u.method(vm, p, "toString", 0, toStringFn);
    try u.method(vm, p, "toLocaleString", 0, toLocaleString);
    try u.method(vm, p, "reverse", 0, reverse);
    try u.method(vm, p, "indexOf", 1, indexOf);
    try u.method(vm, p, "lastIndexOf", 1, lastIndexOf);
    try u.method(vm, p, "includes", 1, includes);
    try b_array2.init(vm, p);
    try b_iter.init(vm, p);
}
