//! Map, Set, WeakMap, WeakSet, WeakRef and FinalizationRegistry. Map and Set share an
//! insertion-ordered hash table whose deleted slots stay as tombstones, so iterators
//! holding a position survive mutation during iteration.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const heap = @import("heap.zig");
const u = @import("b_util.zig");
const Value = u.Value;
const PropKey = u.PropKey;
const Object = u.Object;
const objmod = @import("object.zig");
const props = @import("props.zig");
const conv = @import("conv.zig");
const str = @import("string.zig");
const calls = @import("interp_call.zig");
const iter = @import("iter.zig");
const coroutine = @import("coroutine.zig");
const big = @import("b_bigint.zig");

fn hashValue(vm: *Vm, v: Value) Error!u64 {
    if (v.isString()) {
        return std.hash.Wyhash.hash(0, try v.asString().flat(vm));
    }
    if (v.isNumber()) {
        const d = v.asNumber();
        // +0 and -0 are one key; int and double forms of a number too.
        return std.hash.Wyhash.hash(1, std.mem.asBytes(&(if (d == 0) @as(f64, 0) else d)));
    }
    if (v.isBigInt()) return big.hash(v);
    return v.bits *% 0x9E37_79B9_7F4A_7C15;
}

const Entry = struct { key: Value, value: Value, hash: u64 };

pub const MapData = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Entry index + 1; 0 empty. Deleted entries keep their index slot with a hole key.
    index: []u32 = &.{},
    live: u32 = 0,

    pub fn trace(d: *MapData, m: *heap.Marker) void {
        for (d.entries.items) |e| {
            m.mark(e.key);
            m.mark(e.value);
        }
    }
    pub fn destroy(d: *MapData, gpa: Allocator) void {
        d.entries.deinit(gpa);
        gpa.free(d.index);
        gpa.destroy(d);
    }

    fn rehash(d: *MapData, gpa: Allocator) Allocator.Error!void {
        var cap: usize = 16;
        while (cap < (d.entries.items.len + 1) * 2) cap *= 2;
        const idx = try gpa.alloc(u32, cap);
        @memset(idx, 0);
        gpa.free(d.index);
        d.index = idx;
        for (d.entries.items, 0..) |e, i| {
            if (e.key.isHole()) continue;
            var h: usize = @intCast(e.hash & (cap - 1));
            while (idx[h] != 0) h = (h + 1) & (cap - 1);
            idx[h] = @intCast(i + 1);
        }
    }

    fn find(d: *MapData, vm: *Vm, key: Value, hash: u64) ?u32 {
        if (d.index.len == 0) return null;
        const mask = d.index.len - 1;
        var h: usize = @intCast(hash & mask);
        while (true) {
            const v = d.index[h];
            if (v == 0) return null;
            const e = &d.entries.items[v - 1];
            if (e.hash == hash and !e.key.isHole() and conv.sameValueZero(vm, e.key, key)) return v - 1;
            h = (h + 1) & mask;
        }
    }

    fn put(d: *MapData, vm: *Vm, key_in: Value, val: Value) Error!void {
        // -0 normalizes to +0, per spec.
        const key = if (key_in.isDouble() and key_in.asDouble() == 0) Value.fromInt(0) else key_in;
        const hash = try hashValue(vm, key);
        if (d.find(vm, key, hash)) |i| {
            d.entries.items[i].value = val;
            return;
        }
        try d.entries.append(vm.gpa, .{ .key = key, .value = val, .hash = hash });
        d.live += 1;
        if (d.index.len == 0 or d.entries.items.len * 2 >= d.index.len) {
            try d.rehash(vm.gpa);
        } else {
            const mask = d.index.len - 1;
            var h: usize = @intCast(hash & mask);
            while (d.index[h] != 0) h = (h + 1) & mask;
            d.index[h] = @intCast(d.entries.items.len);
        }
    }

    fn remove(d: *MapData, vm: *Vm, key: Value) Error!bool {
        const hash = try hashValue(vm, key);
        const i = d.find(vm, key, hash) orelse return false;
        const e = &d.entries.items[i];
        e.key = Value.hole;
        e.value = Value.undefined;
        d.live -= 1;
        return true;
    }

    fn clear(d: *MapData) void {
        // Iterators positioned past these slots just see the end.
        for (d.entries.items) |*e| {
            e.key = Value.hole;
            e.value = Value.undefined;
        }
        @memset(d.index, 0);
        d.live = 0;
    }
};

fn thisData(vm: *Vm, this: Value, class: objmod.Class) Error!*MapData {
    if (this.isObject() and this.asObject().class == class) return this.asObject().payload.map;
    return vm.throwError(.TypeError, if (class == .map) "Method Map.prototype called on incompatible receiver" else "Method Set.prototype called on incompatible receiver");
}

fn newCollection(vm: *Vm, proto: *Object, class: objmod.Class) Error!*Object {
    const d = try vm.gpa.create(MapData);
    d.* = .{};
    const o = objmod.create(vm, proto, class) catch |e| {
        vm.gpa.destroy(d);
        return e;
    };
    o.payload = .{ .map = d };
    return o;
}

fn mapCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    if (vm.new_target.isUndefined()) return vm.throwError(.TypeError, "Constructor Map requires 'new'");
    const o = try newCollection(vm, try calls.protoFromNewTarget(vm, vm.protos.map), .map);
    const src = u.arg(args, 0);
    if (src.isNullish()) return o.value();
    const adder = try props.get(vm, o, vm.k.set);
    if (!adder.isCallable()) return vm.throwError(.TypeError, "'set' is not a function");
    const Ctx = struct {
        vm: *Vm,
        o: *Object,
        adder: Value,
        fn add(c: @This(), item: Value) Error!void {
            if (!item.isObject()) return c.vm.throwError(.TypeError, "Iterator value is not an entry object");
            const k = try props.get(c.vm, item.asObject(), PropKey.fromIndex(0));
            const v = try props.get(c.vm, item.asObject(), PropKey.fromIndex(1));
            _ = try calls.call(c.vm, c.adder, c.o.value(), &.{ k, v });
        }
    };
    try iter.forEach(vm, src, Ctx{ .vm = vm, .o = o, .adder = adder }, Ctx.add);
    return o.value();
}

fn setCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    if (vm.new_target.isUndefined()) return vm.throwError(.TypeError, "Constructor Set requires 'new'");
    const o = try newCollection(vm, try calls.protoFromNewTarget(vm, vm.protos.set), .set);
    const src = u.arg(args, 0);
    if (src.isNullish()) return o.value();
    const adder = try props.get(vm, o, try str.keyFromBytes(vm, "add"));
    if (!adder.isCallable()) return vm.throwError(.TypeError, "'add' is not a function");
    const Ctx = struct {
        vm: *Vm,
        o: *Object,
        adder: Value,
        fn add(c: @This(), item: Value) Error!void {
            _ = try calls.call(c.vm, c.adder, c.o.value(), &.{item});
        }
    };
    try iter.forEach(vm, src, Ctx{ .vm = vm, .o = o, .adder = adder }, Ctx.add);
    return o.value();
}

fn mapGet(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const d = try thisData(vm, this, .map);
    const k = u.arg(args, 0);
    const i = d.find(vm, k, try hashValue(vm, k)) orelse return Value.undefined;
    return d.entries.items[i].value;
}
fn mapSet(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const d = try thisData(vm, this, .map);
    try d.put(vm, u.arg(args, 0), u.arg(args, 1));
    return this;
}
fn setAdd(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const d = try thisData(vm, this, .set);
    try d.put(vm, u.arg(args, 0), u.arg(args, 0));
    return this;
}
fn hasFn(comptime class: objmod.Class) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, args: []const Value) Error!Value {
            const d = try thisData(vm, this, class);
            const k = u.arg(args, 0);
            return Value.fromBool(d.find(vm, k, try hashValue(vm, k)) != null);
        }
    }.f;
}
fn deleteFn(comptime class: objmod.Class) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, args: []const Value) Error!Value {
            return Value.fromBool(try (try thisData(vm, this, class)).remove(vm, u.arg(args, 0)));
        }
    }.f;
}
fn clearFn(comptime class: objmod.Class) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, _: []const Value) Error!Value {
            (try thisData(vm, this, class)).clear();
            return Value.undefined;
        }
    }.f;
}
fn sizeFn(comptime class: objmod.Class) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, _: []const Value) Error!Value {
            return Value.fromUsize((try thisData(vm, this, class)).live);
        }
    }.f;
}
fn forEachFn(comptime class: objmod.Class) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, args: []const Value) Error!Value {
            const d = try thisData(vm, this, class);
            const cb = u.arg(args, 0);
            if (!cb.isCallable()) return vm.throwError(.TypeError, "callback is not a function");
            var i: usize = 0;
            while (i < d.entries.items.len) : (i += 1) {
                const e = d.entries.items[i];
                if (e.key.isHole()) continue;
                _ = try calls.call(vm, cb, u.arg(args, 1), &.{ e.value, e.key, this });
            }
            return Value.undefined;
        }
    }.f;
}

fn makeIter(vm: *Vm, this: Value, kind: u8, proto: *Object, class: objmod.Class) Error!Value {
    const data = try vm.gpa.create(objmod.IterData);
    data.* = .{ .target = this, .kind = kind };
    const o = objmod.create(vm, proto, class) catch |e| {
        vm.gpa.destroy(data);
        return e;
    };
    o.payload = .{ .iter = data };
    return o.value();
}

fn iterFn(comptime class: objmod.Class, comptime kind: u8) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, _: []const Value) Error!Value {
            _ = try thisData(vm, this, class);
            if (class == .map) return makeIter(vm, this, kind, vm.protos.map_iter, .map_iter);
            return makeIter(vm, this, kind, vm.protos.set_iter, .set_iter);
        }
    }.f;
}

fn collectionIterNext(vm: *Vm, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() or (this.asObject().class != .map_iter and this.asObject().class != .set_iter)) {
        return vm.throwError(.TypeError, "next method called on incompatible receiver");
    }
    const it = this.asObject().payload.iter;
    if (it.done) return coroutine.iterResult(vm, Value.undefined, true);
    const d = it.target.asObject().payload.map;
    while (it.index < d.entries.items.len) {
        const e = d.entries.items[it.index];
        it.index += 1;
        if (e.key.isHole()) continue;
        return coroutine.iterResult(vm, switch (it.kind) {
            0 => e.key,
            1 => e.value,
            else => (try objmod.newArray(vm, &.{ e.key, e.value })).value(),
        }, false);
    }
    it.done = true;
    return coroutine.iterResult(vm, Value.undefined, true);
}

fn speciesGetter(_: *Vm, this: Value, _: []const Value) Error!Value {
    return this;
}

fn groupByMap(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const out = try newCollection(vm, vm.protos.map, .map);
    const cb = u.arg(args, 1);
    if (!cb.isCallable()) return vm.throwError(.TypeError, "callback is not a function");
    const Ctx = struct {
        vm: *Vm,
        d: *MapData,
        cb: Value,
        i: *u32,
        fn add(c: @This(), item: Value) Error!void {
            const k = try calls.call(c.vm, c.cb, Value.undefined, &.{ item, Value.fromUsize(c.i.*) });
            c.i.* += 1;
            if (c.d.find(c.vm, k, try hashValue(c.vm, k))) |slot| {
                try objmod.arrayPush(c.vm, c.d.entries.items[slot].value.asObject(), item);
            } else {
                try c.d.put(c.vm, k, (try objmod.newArray(c.vm, &.{item})).value());
            }
        }
    };
    var i: u32 = 0;
    try iter.forEach(vm, u.arg(args, 0), Ctx{ .vm = vm, .d = out.payload.map, .cb = cb, .i = &i }, Ctx.add);
    return out.value();
}

/// Weak containers: entries are key cell -> value, the value marked only through the key.
pub const WeakData = struct {
    table: std.AutoHashMapUnmanaged(u64, Value) = .empty,
    kind: objmod.Class,

    pub fn destroy(d: *WeakData, gpa: Allocator) void {
        d.table.deinit(gpa);
        gpa.destroy(d);
    }

    /// One ephemeron pass; true if a value newly became reachable.
    pub fn traceWeak(d: *WeakData, m: *heap.Marker) bool {
        var progress = false;
        var it = d.table.iterator();
        while (it.next()) |e| {
            const key = Value{ .bits = e.key_ptr.* };
            const cell = key.heapCell() orelse continue;
            if (!cell.marked) continue;
            if (e.value_ptr.heapCell()) |vc| {
                if (!vc.marked) {
                    m.mark(e.value_ptr.*);
                    progress = true;
                }
            }
        }
        return progress;
    }

    /// Forgets entries whose key died.
    pub fn sweep(d: *WeakData, vm: *Vm) void {
        var dead: std.ArrayList(u64) = .empty;
        defer dead.deinit(vm.raw_gpa);
        var it = d.table.iterator();
        while (it.next()) |e| {
            const key = Value{ .bits = e.key_ptr.* };
            const cell = key.heapCell() orelse continue;
            if (!cell.marked) dead.append(vm.raw_gpa, e.key_ptr.*) catch @panic("gc: out of memory");
        }
        for (dead.items) |k| _ = d.table.remove(k);
    }
};

fn newWeak(vm: *Vm, proto: *Object, class: objmod.Class) Error!*Object {
    const d = try vm.gpa.create(WeakData);
    d.* = .{ .kind = class };
    const o = objmod.create(vm, proto, class) catch |e| {
        vm.gpa.destroy(d);
        return e;
    };
    o.payload = .{ .weak = d };
    return o;
}

fn weakData(vm: *Vm, this: Value, class: objmod.Class) Error!*WeakData {
    if (this.isObject() and this.asObject().class == class) return this.asObject().payload.weak;
    return vm.throwError(.TypeError, "Method called on incompatible receiver");
}

fn canBeWeak(v: Value) bool {
    if (v.isObject()) return true;
    return v.isSymbol() and !v.asSymbol().is_registered;
}

fn weakMapCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    if (vm.new_target.isUndefined()) return vm.throwError(.TypeError, "Constructor WeakMap requires 'new'");
    const o = try newWeak(vm, try calls.protoFromNewTarget(vm, vm.protos.weakmap), .weakmap);
    const src = u.arg(args, 0);
    if (src.isNullish()) return o.value();
    const Ctx = struct {
        vm: *Vm,
        o: *Object,
        fn add(c: @This(), item: Value) Error!void {
            if (!item.isObject()) return c.vm.throwError(.TypeError, "Iterator value is not an entry object");
            const k = try props.get(c.vm, item.asObject(), PropKey.fromIndex(0));
            const v = try props.get(c.vm, item.asObject(), PropKey.fromIndex(1));
            _ = try weakMapSet(c.vm, c.o.value(), &.{ k, v });
        }
    };
    try iter.forEach(vm, src, Ctx{ .vm = vm, .o = o }, Ctx.add);
    return o.value();
}
fn weakSetCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    if (vm.new_target.isUndefined()) return vm.throwError(.TypeError, "Constructor WeakSet requires 'new'");
    const o = try newWeak(vm, try calls.protoFromNewTarget(vm, vm.protos.weakset), .weakset);
    const src = u.arg(args, 0);
    if (src.isNullish()) return o.value();
    const Ctx = struct {
        vm: *Vm,
        o: *Object,
        fn add(c: @This(), item: Value) Error!void {
            _ = try weakSetAdd(c.vm, c.o.value(), &.{item});
        }
    };
    try iter.forEach(vm, src, Ctx{ .vm = vm, .o = o }, Ctx.add);
    return o.value();
}
fn weakMapGet(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return (try weakData(vm, this, .weakmap)).table.get(u.arg(args, 0).bits) orelse Value.undefined;
}
fn weakMapSet(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const d = try weakData(vm, this, .weakmap);
    if (!canBeWeak(u.arg(args, 0))) return vm.throwError(.TypeError, "Invalid value used as weak map key");
    try d.table.put(vm.gpa, u.arg(args, 0).bits, u.arg(args, 1));
    return this;
}
fn weakSetAdd(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const d = try weakData(vm, this, .weakset);
    if (!canBeWeak(u.arg(args, 0))) return vm.throwError(.TypeError, "Invalid value used in weak set");
    try d.table.put(vm.gpa, u.arg(args, 0).bits, Value.true);
    return this;
}
fn weakHas(comptime class: objmod.Class) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, args: []const Value) Error!Value {
            return Value.fromBool((try weakData(vm, this, class)).table.contains(u.arg(args, 0).bits));
        }
    }.f;
}
fn weakDelete(comptime class: objmod.Class) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, args: []const Value) Error!Value {
            return Value.fromBool((try weakData(vm, this, class)).table.remove(u.arg(args, 0).bits));
        }
    }.f;
}

fn weakRefCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    if (vm.new_target.isUndefined()) return vm.throwError(.TypeError, "Constructor WeakRef requires 'new'");
    const t = u.arg(args, 0);
    if (!canBeWeak(t)) return vm.throwError(.TypeError, "WeakRef: target must be an object");
    const o = try newWeak(vm, try calls.protoFromNewTarget(vm, vm.protos.weakref), .weakref);
    try o.payload.weak.table.put(vm.gpa, t.bits, Value.true);
    return o.value();
}
fn weakRefDeref(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const d = try weakData(vm, this, .weakref);
    var it = d.table.keyIterator();
    if (it.next()) |k| return .{ .bits = k.* };
    return Value.undefined;
}
fn finRegCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    if (vm.new_target.isUndefined()) return vm.throwError(.TypeError, "Constructor FinalizationRegistry requires 'new'");
    if (!u.arg(args, 0).isCallable()) return vm.throwError(.TypeError, "FinalizationRegistry: cleanup must be callable");
    return (try newWeak(vm, try calls.protoFromNewTarget(vm, vm.protos.finreg), .finreg)).value();
}
/// The registry never calls back: the spec allows that, and it keeps collection simple.
fn finRegRegister(vm: *Vm, _: Value, args: []const Value) Error!Value {
    if (!canBeWeak(u.arg(args, 0))) return vm.throwError(.TypeError, "FinalizationRegistry.register: invalid target");
    return Value.undefined;
}
fn finRegUnregister(_: *Vm, _: Value, _: []const Value) Error!Value {
    return Value.false;
}

pub fn init(vm: *Vm) Error!void {
    const p = &vm.protos;
    p.map = try u.newProto(vm, p.object);
    p.set = try u.newProto(vm, p.object);
    p.map_iter = try u.newProto(vm, p.iterator);
    p.set_iter = try u.newProto(vm, p.iterator);
    const mc = try u.ctor(vm, "Map", 0, mapCtor, p.map);
    try u.symGetter(vm, mc, vm.sym.species, "get [Symbol.species]", speciesGetter);
    try u.method(vm, mc, "groupBy", 2, groupByMap);
    try u.toStringTag(vm, p.map, "Map");
    try u.method(vm, p.map, "get", 1, mapGet);
    try u.method(vm, p.map, "set", 2, mapSet);
    try u.method(vm, p.map, "has", 1, hasFn(.map));
    try u.method(vm, p.map, "delete", 1, deleteFn(.map));
    try u.method(vm, p.map, "clear", 0, clearFn(.map));
    try u.method(vm, p.map, "forEach", 1, forEachFn(.map));
    try u.getter(vm, p.map, "size", sizeFn(.map));
    try u.method(vm, p.map, "keys", 0, iterFn(.map, 0));
    try u.method(vm, p.map, "values", 0, iterFn(.map, 1));
    try u.method(vm, p.map, "entries", 0, iterFn(.map, 2));
    const entries = try props.get(vm, p.map, try str.keyFromBytes(vm, "entries"));
    try props.defineData(vm, p.map, PropKey.fromSymbol(vm.sym.iterator), entries, u.PropFlags.hidden);
    try u.method(vm, p.map_iter, "next", 0, collectionIterNext);
    try u.toStringTag(vm, p.map_iter, "Map Iterator");

    const sc = try u.ctor(vm, "Set", 0, setCtor, p.set);
    try u.symGetter(vm, sc, vm.sym.species, "get [Symbol.species]", speciesGetter);
    try u.toStringTag(vm, p.set, "Set");
    try u.method(vm, p.set, "add", 1, setAdd);
    try u.method(vm, p.set, "has", 1, hasFn(.set));
    try u.method(vm, p.set, "delete", 1, deleteFn(.set));
    try u.method(vm, p.set, "clear", 0, clearFn(.set));
    try u.method(vm, p.set, "forEach", 1, forEachFn(.set));
    try u.getter(vm, p.set, "size", sizeFn(.set));
    try u.method(vm, p.set, "values", 0, iterFn(.set, 0));
    try u.method(vm, p.set, "entries", 0, iterFn(.set, 2));
    const values = try props.get(vm, p.set, try str.keyFromBytes(vm, "values"));
    try u.data(vm, p.set, "keys", values);
    try props.defineData(vm, p.set, PropKey.fromSymbol(vm.sym.iterator), values, u.PropFlags.hidden);
    try u.method(vm, p.set_iter, "next", 0, collectionIterNext);
    try u.toStringTag(vm, p.set_iter, "Set Iterator");

    p.weakmap = try u.newProto(vm, p.object);
    _ = try u.ctor(vm, "WeakMap", 0, weakMapCtor, p.weakmap);
    try u.toStringTag(vm, p.weakmap, "WeakMap");
    try u.method(vm, p.weakmap, "get", 1, weakMapGet);
    try u.method(vm, p.weakmap, "set", 2, weakMapSet);
    try u.method(vm, p.weakmap, "has", 1, weakHas(.weakmap));
    try u.method(vm, p.weakmap, "delete", 1, weakDelete(.weakmap));
    p.weakset = try u.newProto(vm, p.object);
    _ = try u.ctor(vm, "WeakSet", 0, weakSetCtor, p.weakset);
    try u.toStringTag(vm, p.weakset, "WeakSet");
    try u.method(vm, p.weakset, "add", 1, weakSetAdd);
    try u.method(vm, p.weakset, "has", 1, weakHas(.weakset));
    try u.method(vm, p.weakset, "delete", 1, weakDelete(.weakset));
    p.weakref = try u.newProto(vm, p.object);
    _ = try u.ctor(vm, "WeakRef", 1, weakRefCtor, p.weakref);
    try u.toStringTag(vm, p.weakref, "WeakRef");
    try u.method(vm, p.weakref, "deref", 0, weakRefDeref);
    p.finreg = try u.newProto(vm, p.object);
    _ = try u.ctor(vm, "FinalizationRegistry", 1, finRegCtor, p.finreg);
    try u.toStringTag(vm, p.finreg, "FinalizationRegistry");
    try u.method(vm, p.finreg, "register", 2, finRegRegister);
    try u.method(vm, p.finreg, "unregister", 1, finRegUnregister);
}
