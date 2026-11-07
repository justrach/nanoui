//! Object internal methods: [[Get]], [[Set]], [[HasProperty]], [[Delete]] and the
//! storage helpers they share. Exotic objects (proxies, typed arrays, string
//! wrappers, host collections, module namespaces) branch to props_exotic.zig;
//! [[DefineOwnProperty]] and [[OwnPropertyKeys]] are in props_define.zig.

const std = @import("std");
const Value = @import("value.zig").Value;
const PropKey = @import("value.zig").PropKey;
const heap = @import("heap.zig");
const shape_mod = @import("shape.zig");
const PropFlags = shape_mod.PropFlags;
const objmod = @import("object.zig");
const Object = objmod.Object;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const str = @import("string.zig");
const exotic = @import("props_exotic.zig");
const define = @import("props_define.zig");
const interp = @import("interp_call.zig");

pub const defineOwn = define.defineOwn;
pub const Desc = define.Desc;
pub const ownKeys = define.ownKeys;
pub const getOwn = define.getOwn;
pub const Own = define.Own;
pub const setArrayLength = define.setArrayLength;
pub const setArrayLengthValue = define.setArrayLengthValue;

const dict_threshold = 512;
/// How far past the end a write may land and still extend dense storage.
const max_dense_gap = 1024;

pub inline fn callGetter(vm: *Vm, slot: Value, receiver: Value) Error!Value {
    const a: *heap.Accessor = @fieldParentPtr("cell", slot.asCell());
    if (a.get.isUndefined()) return Value.undefined;
    return interp.call(vm, a.get, receiver, &.{});
}

/// Materializes a function's lazy name/length/prototype when key is one of them.
pub inline fn touchLazy(vm: *Vm, o: *Object, key: PropKey) Error!void {
    if (o.flags.lazy_fn and (key.eql(vm.k.prototype) or key.eql(vm.k.name) or key.eql(vm.k.length))) {
        try materialize(vm, o);
    }
}

/// Creates a function's standard own properties, in spec order.
pub fn materialize(vm: *Vm, o: *Object) Error!void {
    if (!o.flags.lazy_fn) return;
    o.flags.lazy_fn = false;
    var name: *str.JSString = vm.empty;
    var arity: u32 = 0;
    var make_proto = false;
    switch (o.class) {
        .closure => {
            const fp = o.payload.fp;
            name = fp.name;
            arity = fp.length;
            make_proto = fp.has_prototype;
        },
        .native => {
            name = o.payload.native.name;
            arity = o.payload.native.arity;
        },
        else => {},
    }
    try addProp(vm, o, vm.k.length, Value.fromInt(@intCast(arity)), PropFlags.config_only);
    try addProp(vm, o, vm.k.name, Value.fromString(name), PropFlags.config_only);
    if (make_proto) {
        const fp = o.payload.fp;
        const p = if (fp.is_generator)
            try objmod.create(vm, if (fp.is_async) vm.protos.async_generator else vm.protos.generator, .object)
        else
            try objmod.newPlain(vm);
        if (!fp.is_generator) try addProp(vm, p, vm.k.constructor, o.value(), PropFlags.hidden);
        try addProp(vm, o, vm.k.prototype, p.value(), .{ .writable = true, .enumerable = false, .configurable = false });
    }
}

pub fn get(vm: *Vm, o: *Object, key: PropKey) Error!Value {
    return getR(vm, o, key, Value.fromObject(o));
}

pub fn getR(vm: *Vm, obj: *Object, key: PropKey, receiver: Value) Error!Value {
    var o = obj;
    const is_index = key.isIndex();
    while (true) {
        if (o.flags.exotic) {
            if (try exotic.get(vm, o, key, receiver)) |v| return v;
        }
        if (is_index) {
            const i = key.index();
            if (i < o.elems_len) {
                const v = o.elems[i];
                if (!v.isHole()) return v;
            }
            if (o.flags.has_sparse) {
                if (o.shape.find(key)) |s| {
                    if (o.shape.flagsAt(s).accessor) return callGetter(vm, o.slots[s], receiver);
                    return o.slots[s];
                }
            }
        } else {
            if (o.flags.lazy_fn) try touchLazy(vm, o, key);
            if (o.shape.find(key)) |s| {
                if (o.shape.flagsAt(s).accessor) return callGetter(vm, o.slots[s], receiver);
                return o.slots[s];
            }
            if (o.class == .array and key.eql(vm.k.length)) return Value.fromUsize(o.arr_len);
        }
        o = o.shape.proto orelse return Value.undefined;
    }
}

/// GetV: property of any value, boxing primitives only conceptually.
pub fn getV(vm: *Vm, v: Value, key: PropKey) Error!Value {
    if (v.isObject()) return getR(vm, v.asObject(), key, v);
    if (v.isString()) {
        const s = v.asString();
        if (key.eql(vm.k.length)) return Value.fromUsize(s.len16);
        if (key.isIndex() and key.index() < s.len16) {
            return Value.fromString(try str.fromCodeUnit(vm, try s.unitAt(vm, key.index())));
        }
        return getR(vm, vm.protos.string, key, v);
    }
    if (v.isNumber()) return getR(vm, vm.protos.number, key, v);
    if (v.isBool()) return getR(vm, vm.protos.boolean, key, v);
    if (v.isSymbol()) return getR(vm, vm.protos.symbol, key, v);
    if (v.isBigInt()) return getR(vm, vm.protos.bigint, key, v);
    var buf: [128]u8 = undefined;
    const t = str.keyText(vm, key, buf[0..64]);
    const msg = std.fmt.bufPrint(&buf, "Cannot read properties of {s} (reading '{s}')", .{
        if (v.isNull()) "null" else "undefined",
        t[0..@min(t.len, 32)],
    }) catch "Cannot read properties of nullish value";
    return vm.throwError(.TypeError, msg);
}

pub fn set(vm: *Vm, o: *Object, key: PropKey, val: Value) Error!bool {
    return setR(vm, o, key, val, Value.fromObject(o));
}

/// Set(O, P, V, true): failure throws TypeError.
pub fn put(vm: *Vm, o: *Object, key: PropKey, val: Value) Error!void {
    if (!try set(vm, o, key, val)) return throwReadonly(vm, key);
}

pub fn throwReadonly(vm: *Vm, key: PropKey) Error {
    var buf: [128]u8 = undefined;
    const t = str.keyText(vm, key, buf[0..64]);
    const msg = std.fmt.bufPrint(buf[64..], "Cannot assign to read only property '{s}'", .{t[0..@min(t.len, 16)]}) catch "Cannot assign to read only property";
    return vm.throwError(.TypeError, msg);
}

pub fn setR(vm: *Vm, obj: *Object, key: PropKey, val: Value, receiver: Value) Error!bool {
    var o = obj;
    const is_index = key.isIndex();
    const same = receiver.isObject() and receiver.asObject() == obj;
    while (true) {
        if (o.flags.exotic) {
            if (try exotic.set(vm, o, key, val, receiver)) |r| return r;
        }
        if (is_index) {
            const i = key.index();
            if (i < o.elems_len and !o.elems[i].isHole()) {
                if (o.flags.elems_frozen) return false;
                if (same and o == obj) {
                    o.elems[i] = val;
                    return true;
                }
                break;
            }
            if (o.flags.has_sparse) {
                if (o.shape.find(key)) |s| return setFound(vm, o, s, key, val, receiver, same and o == obj);
            }
        } else {
            if (o.flags.lazy_fn) try touchLazy(vm, o, key);
            if (o.shape.find(key)) |s| return setFound(vm, o, s, key, val, receiver, same and o == obj);
            if (o.class == .array and key.eql(vm.k.length)) {
                if (same and o == obj) return define.setArrayLengthValue(vm, o, val);
                if (o.flags.length_readonly) return false;
                break;
            }
        }
        o = o.shape.proto orelse break;
    }
    if (!receiver.isObject()) return false;
    const r = receiver.asObject();
    if (same and !r.flags.exotic) {
        if (is_index and r.class == .array and r.flags.length_readonly and key.index() >= r.arr_len) return false;
        // obj has no own key here (the walk started at obj), so this is a plain add.
        if (!r.flags.extensible) return false;
        try addProp(vm, r, key, val, PropFlags.all);
        return true;
    }
    return setOnReceiver(vm, r, key, val);
}

fn setFound(vm: *Vm, o: *Object, s: u32, key: PropKey, val: Value, receiver: Value, own: bool) Error!bool {
    const f = o.shape.flagsAt(s);
    if (f.accessor) {
        const a: *heap.Accessor = @fieldParentPtr("cell", o.slots[s].asCell());
        if (a.set.isUndefined()) return false;
        _ = try interp.call(vm, a.set, receiver, &.{val});
        return true;
    }
    if (!f.writable) return false;
    if (own) {
        o.slots[s] = val;
        return true;
    }
    if (!receiver.isObject()) return false;
    return setOnReceiver(vm, receiver.asObject(), key, val);
}

fn setOnReceiver(vm: *Vm, r: *Object, key: PropKey, val: Value) Error!bool {
    if (try getOwn(vm, r, key)) |own| {
        if (own.flags.accessor or !own.flags.writable) return false;
        return defineOwn(vm, r, key, .{ .value = val });
    }
    return defineOwn(vm, r, key, .{ .value = val, .writable = true, .enumerable = true, .configurable = true });
}

/// Adds a property known not to exist yet, ignoring extensibility. Index keys
/// land in dense storage when they are near it and the flags are the defaults.
pub fn addProp(vm: *Vm, o: *Object, key: PropKey, val: Value, flags: PropFlags) Error!void {
    if (key.isIndex()) {
        const i = key.index();
        if (@as(u8, @bitCast(flags)) == @as(u8, @bitCast(PropFlags.all)) and !o.flags.elems_sealed and !o.flags.elems_frozen) {
            if (try addDense(vm, o, i, val)) return;
        }
        if (o.class == .array and i >= o.arr_len) {
            if (o.flags.length_readonly) return vm.throwError(.TypeError, "Cannot add property, array length is read only");
            o.arr_len = i + 1;
        }
        o.flags.has_sparse = true;
        if (!o.shape.is_dict) o.shape = try shape_mod.toDict(vm, o.shape, o.shape.proto);
    }
    const sh = o.shape;
    const slot = sh.count;
    if (slot >= o.slot_cap) try objmod.growSlots(vm, o, slot + 1);
    if (sh.is_dict) {
        try shape_mod.dictAdd(vm, sh, key, flags);
    } else if (slot >= dict_threshold) {
        const d = try shape_mod.toDict(vm, sh, sh.proto);
        try shape_mod.dictAdd(vm, d, key, flags);
        o.shape = d;
    } else {
        o.shape = try shape_mod.transition(vm, sh, key, flags);
    }
    o.slots[slot] = val;
}

/// Tries to store index i in dense elements. False means the gap is too big.
fn addDense(vm: *Vm, o: *Object, i: u32, val: Value) Error!bool {
    if (i < o.elems_len) {
        o.elems[i] = val;
    } else {
        if (i > @as(u64, o.elems_len) + max_dense_gap and i >= o.elems_cap) return false;
        if (i >= o.elems_cap) try objmod.growElems(vm, o, @as(usize, i) + 1);
        var k: usize = o.elems_len;
        while (k < i) : (k += 1) o.elems[k] = Value.hole;
        o.elems[i] = val;
        o.elems_len = i + 1;
    }
    if (o.class == .array and i >= o.arr_len) {
        if (o.flags.length_readonly) return vm.throwError(.TypeError, "Cannot add property, array length is read only");
        o.arr_len = i + 1;
    }
    return true;
}

pub fn has(vm: *Vm, obj: *Object, key: PropKey) Error!bool {
    var o = obj;
    while (true) {
        if (o.class == .proxy) return exotic.proxyHas(vm, o, key);
        if (try hasOwn(vm, o, key)) return true;
        if (o.class == .typedarray and key.isIndex()) return false;
        o = o.shape.proto orelse return false;
    }
}

pub fn hasOwn(vm: *Vm, o: *Object, key: PropKey) Error!bool {
    if (o.flags.exotic) return (try getOwn(vm, o, key)) != null;
    if (key.isIndex()) {
        const i = key.index();
        if (i < o.elems_len and !o.elems[i].isHole()) return true;
        return o.flags.has_sparse and o.shape.find(key) != null;
    }
    if (o.flags.lazy_fn) try touchLazy(vm, o, key);
    if (o.shape.find(key) != null) return true;
    return o.class == .array and key.eql(vm.k.length);
}

pub fn delete(vm: *Vm, o: *Object, key: PropKey) Error!bool {
    if (o.flags.exotic) {
        if (try exotic.delete(vm, o, key)) |r| return r;
    }
    if (key.isIndex()) {
        const i = key.index();
        if (i < o.elems_len and !o.elems[i].isHole()) {
            if (o.flags.elems_frozen or o.flags.elems_sealed) return false;
            o.elems[i] = Value.hole;
            if (i + 1 == o.elems_len) o.elems_len = i;
            return true;
        }
        if (!o.flags.has_sparse) return true;
    } else {
        if (o.flags.lazy_fn) try materialize(vm, o);
        if (o.class == .array and key.eql(vm.k.length)) return false;
    }
    const s = o.shape.find(key) orelse return true;
    if (!o.shape.flagsAt(s).configurable) return false;
    if (!o.shape.is_dict) o.shape = try shape_mod.toDict(vm, o.shape, o.shape.proto);
    shape_mod.dictRemove(o.shape, s);
    o.slots[s] = Value.undefined;
    if (o.shape.count > 32 and o.shape.live * 2 < o.shape.count) try shape_mod.dictCompact(vm, o.shape, o.slots);
    return true;
}

/// Moves an object's prototype; other objects sharing the old shape are untouched.
pub fn setProtoRaw(vm: *Vm, o: *Object, proto: ?*Object) Error!void {
    if (o.shape.proto == proto) return;
    if (o.shape.is_dict) {
        const d = try shape_mod.toDict(vm, o.shape, proto);
        o.shape = d;
        return;
    }
    var s = if (o.flags.exotic) try shape_mod.exoticRootFor(vm, proto) else try shape_mod.rootFor(vm, proto);
    for (o.shape.entries()) |e| s = try shape_mod.transition(vm, s, e.key, e.flags);
    o.shape = s;
}

pub fn getProto(vm: *Vm, o: *Object) Error!?*Object {
    if (o.class == .proxy) return exotic.proxyGetProto(vm, o);
    return o.shape.proto;
}

/// OrdinarySetPrototypeOf, with the cycle check and the proxy trap.
pub fn setProto(vm: *Vm, o: *Object, proto: ?*Object) Error!bool {
    if (o.class == .proxy) return exotic.proxySetProto(vm, o, proto);
    if (o.shape.proto == proto) return true;
    if (!o.flags.extensible or o == vm.protos.object) return false;
    var p = proto;
    while (p) |q| {
        if (q == o) return false;
        if (q.class == .proxy) break;
        p = q.shape.proto;
    }
    try setProtoRaw(vm, o, proto);
    return true;
}

pub fn isExtensible(vm: *Vm, o: *Object) Error!bool {
    if (o.class == .proxy) return exotic.proxyIsExtensible(vm, o);
    return o.flags.extensible;
}

pub fn preventExtensions(vm: *Vm, o: *Object) Error!bool {
    if (o.class == .proxy) return exotic.proxyPreventExtensions(vm, o);
    if (o.flags.lazy_fn) try materialize(vm, o);
    o.flags.extensible = false;
    return true;
}

/// CreateDataProperty on an ordinary, freshly made object; overwrites any existing.
pub fn defineData(vm: *Vm, o: *Object, key: PropKey, val: Value, flags: PropFlags) Error!void {
    if (o.flags.lazy_fn) try materialize(vm, o);
    if (o.flags.exotic or (o.class == .array and key.eql(vm.k.length))) {
        if (!try defineOwn(vm, o, key, .{ .value = val, .writable = flags.writable, .enumerable = flags.enumerable, .configurable = flags.configurable })) {
            return vm.throwError(.TypeError, "Cannot redefine property");
        }
        return;
    }
    if (key.isIndex()) {
        const i = key.index();
        if (i < o.elems_len and !o.elems[i].isHole() and !o.flags.elems_frozen) {
            if (@as(u8, @bitCast(flags)) == @as(u8, @bitCast(PropFlags.all))) {
                o.elems[i] = val;
                return;
            }
        }
    }
    if (key.isIndex() and !o.flags.has_sparse and o.elems_len <= key.index() and @as(u8, @bitCast(flags)) == @as(u8, @bitCast(PropFlags.all))) {
        return addProp(vm, o, key, val, flags);
    }
    if (!key.isIndex()) {
        if (o.shape.find(key)) |s| {
            if (@as(u8, @bitCast(o.shape.flagsAt(s))) == @as(u8, @bitCast(flags))) {
                o.slots[s] = val;
                return;
            }
        } else {
            return addProp(vm, o, key, val, flags);
        }
    }
    if (!try defineOwn(vm, o, key, .{ .value = val, .writable = flags.writable, .enumerable = flags.enumerable, .configurable = flags.configurable })) {
        return vm.throwError(.TypeError, "Cannot redefine property");
    }
}

/// Defines one half of an accessor, keeping the other half of an existing pair.
pub fn defineAccessorMerge(vm: *Vm, o: *Object, key: PropKey, getter: ?Value, setter: ?Value, enumerable: bool) Error!void {
    if (!try defineOwn(vm, o, key, .{ .get = getter, .set = setter, .enumerable = enumerable, .configurable = true })) {
        return vm.throwError(.TypeError, "Cannot redefine property");
    }
}

/// Defines an accessor property directly, replacing any existing one.
pub fn defineAccessor(vm: *Vm, o: *Object, key: PropKey, getter: Value, setter: Value, enumerable: bool) Error!void {
    if (!try defineOwn(vm, o, key, .{
        .get = getter,
        .set = setter,
        .enumerable = enumerable,
        .configurable = true,
    })) return vm.throwError(.TypeError, "Cannot redefine property");
}
