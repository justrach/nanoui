//! Object: the constructor, every static, and Object.prototype.

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
const define = @import("props_define.zig");
const Desc = define.Desc;
const conv = @import("conv.zig");
const ops = @import("ops.zig");
const str = @import("string.zig");
const calls = @import("interp_call.zig");
const iter = @import("iter.zig");
const api = @import("vm_api.zig");
const typed = @import("b_typed.zig");

fn objectCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const nt = vm.new_target;
    if (nt.isObject() and nt.asObject() != vm.callee) {
        const p = try calls.protoFromNewTarget(vm, vm.protos.object);
        return (try objmod.create(vm, p, .object)).value();
    }
    const v = u.arg(args, 0);
    if (v.isNullish()) return (try objmod.newPlain(vm)).value();
    return (try conv.toObject(vm, v)).value();
}

pub fn toPropertyDescriptor(vm: *Vm, v: Value) Error!Desc {
    if (!v.isObject()) return vm.throwError(.TypeError, "Property description must be an object");
    const o = v.asObject();
    var d = Desc{};
    const k = &vm.k;
    if (try props.has(vm, o, k.enumerable)) d.enumerable = ops.truthy(try props.get(vm, o, k.enumerable));
    if (try props.has(vm, o, k.configurable)) d.configurable = ops.truthy(try props.get(vm, o, k.configurable));
    if (try props.has(vm, o, k.value)) d.value = try props.get(vm, o, k.value);
    if (try props.has(vm, o, k.writable)) d.writable = ops.truthy(try props.get(vm, o, k.writable));
    if (try props.has(vm, o, k.get)) {
        const g = try props.get(vm, o, k.get);
        if (!g.isUndefined() and !g.isCallable()) return vm.throwError(.TypeError, "Getter must be a function");
        d.get = g;
    }
    if (try props.has(vm, o, k.set)) {
        const s = try props.get(vm, o, k.set);
        if (!s.isUndefined() and !s.isCallable()) return vm.throwError(.TypeError, "Setter must be a function");
        d.set = s;
    }
    if (d.isAccessor() and d.isData()) return vm.throwError(.TypeError, "Invalid property descriptor. Cannot both specify accessors and a value or writable attribute");
    return d;
}

pub fn fromPropertyDescriptor(vm: *Vm, own: define.Own) Error!Value {
    const o = try objmod.newPlain(vm);
    const k = &vm.k;
    if (own.flags.accessor) {
        try props.addProp(vm, o, k.get, own.get, PropFlags.all);
        try props.addProp(vm, o, k.set, own.set, PropFlags.all);
    } else {
        try props.addProp(vm, o, k.value, own.value, PropFlags.all);
        try props.addProp(vm, o, k.writable, Value.fromBool(own.flags.writable), PropFlags.all);
    }
    try props.addProp(vm, o, k.enumerable, Value.fromBool(own.flags.enumerable), PropFlags.all);
    try props.addProp(vm, o, k.configurable, Value.fromBool(own.flags.configurable), PropFlags.all);
    return o.value();
}

fn defineOrThrow(vm: *Vm, o: *Object, key: PropKey, d: Desc) Error!void {
    if (!try props.defineOwn(vm, o, key, d)) {
        var buf: [128]u8 = undefined;
        const t = str.keyText(vm, key, buf[0..64]);
        const m = std.fmt.bufPrint(buf[64..], "Cannot redefine property: {s}", .{t[0..@min(t.len, 30)]}) catch "Cannot redefine property";
        return vm.throwError(.TypeError, m);
    }
}

fn defineProperty(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const t = u.arg(args, 0);
    if (!t.isObject()) return vm.throwError(.TypeError, "Object.defineProperty called on non-object");
    const key = try conv.toPropKey(vm, u.arg(args, 1));
    const d = try toPropertyDescriptor(vm, u.arg(args, 2));
    try defineOrThrow(vm, t.asObject(), key, d);
    return t;
}

fn definePropertiesInto(vm: *Vm, o: *Object, pv: Value) Error!void {
    const po = try conv.toObject(vm, pv);
    const keys = try props.ownKeys(vm, po);
    defer vm.gpa.free(keys);
    for (keys) |k| {
        const own = try props.getOwn(vm, po, k) orelse continue;
        if (!own.flags.enumerable) continue;
        const d = try toPropertyDescriptor(vm, try props.get(vm, po, k));
        try defineOrThrow(vm, o, k, d);
    }
}

fn defineProperties(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const t = u.arg(args, 0);
    if (!t.isObject()) return vm.throwError(.TypeError, "Object.defineProperties called on non-object");
    try definePropertiesInto(vm, t.asObject(), u.arg(args, 1));
    return t;
}

fn create(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const p = u.arg(args, 0);
    if (!p.isObject() and !p.isNull()) return vm.throwError(.TypeError, "Object prototype may only be an Object or null");
    const o = try objmod.create(vm, if (p.isObject()) p.asObject() else null, .object);
    if (!u.arg(args, 1).isUndefined()) try definePropertiesInto(vm, o, u.arg(args, 1));
    return o.value();
}

fn getPrototypeOf(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, u.arg(args, 0));
    const p = try props.getProto(vm, o);
    return if (p) |x| x.value() else Value.null;
}

fn setPrototypeOf(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const t = u.arg(args, 0);
    const p = u.arg(args, 1);
    if (t.isNullish()) return vm.throwError(.TypeError, "Object.setPrototypeOf called on null or undefined");
    if (!p.isObject() and !p.isNull()) return vm.throwError(.TypeError, "Object prototype may only be an Object or null");
    if (!t.isObject()) return t;
    if (!try props.setProto(vm, t.asObject(), if (p.isObject()) p.asObject() else null)) {
        return vm.throwError(.TypeError, "Cyclic __proto__ value or non-extensible object");
    }
    return t;
}

fn getOwnPropertyDescriptor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, u.arg(args, 0));
    const key = try conv.toPropKey(vm, u.arg(args, 1));
    const own = try props.getOwn(vm, o, key) orelse return Value.undefined;
    return fromPropertyDescriptor(vm, own);
}

fn getOwnPropertyDescriptors(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, u.arg(args, 0));
    const keys = try props.ownKeys(vm, o);
    defer vm.gpa.free(keys);
    const out = try objmod.newPlain(vm);
    for (keys) |k| {
        const own = try props.getOwn(vm, o, k) orelse continue;
        try props.defineData(vm, out, k, try fromPropertyDescriptor(vm, own), PropFlags.all);
    }
    return out.value();
}

const KeyMode = enum { strings, symbols };

fn ownKeyList(vm: *Vm, v: Value, mode: KeyMode) Error!Value {
    const o = try conv.toObject(vm, v);
    const keys = try props.ownKeys(vm, o);
    defer vm.gpa.free(keys);
    const out = try objmod.newArray(vm, &.{});
    for (keys) |k| {
        if (k.isSymbol() != (mode == .symbols)) continue;
        try objmod.arrayPush(vm, out, try str.keyToValue(vm, k));
    }
    return out.value();
}

fn getOwnPropertyNames(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return ownKeyList(vm, u.arg(args, 0), .strings);
}

fn getOwnPropertySymbols(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return ownKeyList(vm, u.arg(args, 0), .symbols);
}

const EntryMode = enum { keys, values, entries };

fn enumerableOwn(vm: *Vm, v: Value, mode: EntryMode) Error!Value {
    const o = try conv.toObject(vm, v);
    const keys = try props.ownKeys(vm, o);
    defer vm.gpa.free(keys);
    const out = try objmod.newArray(vm, &.{});
    for (keys) |k| {
        if (k.isSymbol()) continue;
        const own = try props.getOwn(vm, o, k) orelse continue;
        if (!own.flags.enumerable) continue;
        const kv = if (mode != .values) try str.keyToValue(vm, k) else Value.undefined;
        switch (mode) {
            .keys => try objmod.arrayPush(vm, out, kv),
            .values => try objmod.arrayPush(vm, out, try props.get(vm, o, k)),
            .entries => {
                const pair = [_]Value{ kv, try props.get(vm, o, k) };
                try objmod.arrayPush(vm, out, (try objmod.newArray(vm, &pair)).value());
            },
        }
    }
    return out.value();
}

fn keysFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return enumerableOwn(vm, u.arg(args, 0), .keys);
}
fn valuesFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return enumerableOwn(vm, u.arg(args, 0), .values);
}
fn entriesFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return enumerableOwn(vm, u.arg(args, 0), .entries);
}

fn assign(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const t = try conv.toObject(vm, u.arg(args, 0));
    if (args.len > 1) {
        for (args[1..]) |src| {
            if (src.isNullish()) continue;
            const from = try conv.toObject(vm, src);
            const keys = try props.ownKeys(vm, from);
            defer vm.gpa.free(keys);
            for (keys) |k| {
                const own = try props.getOwn(vm, from, k) orelse continue;
                if (!own.flags.enumerable) continue;
                try props.put(vm, t, k, try props.get(vm, from, k));
            }
        }
    }
    return t.value();
}

fn setIntegrity(vm: *Vm, o: *Object, frozen: bool) Error!void {
    if (o.class != .proxy and !o.flags.exotic) return define.setIntegrityFast(vm, o, frozen);
    if (!try props.preventExtensions(vm, o)) return vm.throwError(.TypeError, "Cannot prevent extensions");
    const keys = try props.ownKeys(vm, o);
    defer vm.gpa.free(keys);
    for (keys) |k| {
        var d = Desc{ .configurable = false };
        if (frozen) {
            const own = try props.getOwn(vm, o, k) orelse continue;
            if (!own.flags.accessor) d.writable = false;
        }
        try defineOrThrow(vm, o, k, d);
    }
}

fn testIntegrity(vm: *Vm, o: *Object, frozen: bool) Error!bool {
    if (try props.isExtensible(vm, o)) return false;
    const keys = try props.ownKeys(vm, o);
    defer vm.gpa.free(keys);
    for (keys) |k| {
        const own = try props.getOwn(vm, o, k) orelse continue;
        if (own.flags.configurable) return false;
        if (frozen and !own.flags.accessor and own.flags.writable) return false;
    }
    return true;
}

fn freeze(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const v = u.arg(args, 0);
    if (!v.isObject()) return v;
    if (v.asObject().class == .typedarray and typed.length(v.asObject()) > 0) {
        return vm.throwError(.TypeError, "Cannot freeze array buffer views with elements");
    }
    try setIntegrity(vm, v.asObject(), true);
    return v;
}
fn seal(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const v = u.arg(args, 0);
    if (!v.isObject()) return v;
    try setIntegrity(vm, v.asObject(), false);
    return v;
}
fn preventExtensionsFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const v = u.arg(args, 0);
    if (!v.isObject()) return v;
    if (!try props.preventExtensions(vm, v.asObject())) return vm.throwError(.TypeError, "Cannot prevent extensions");
    return v;
}
fn isFrozen(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const v = u.arg(args, 0);
    if (!v.isObject()) return Value.true;
    return Value.fromBool(try testIntegrity(vm, v.asObject(), true));
}
fn isSealed(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const v = u.arg(args, 0);
    if (!v.isObject()) return Value.true;
    return Value.fromBool(try testIntegrity(vm, v.asObject(), false));
}
fn isExtensibleFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const v = u.arg(args, 0);
    if (!v.isObject()) return Value.false;
    return Value.fromBool(try props.isExtensible(vm, v.asObject()));
}
fn isFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(conv.sameValue(vm, u.arg(args, 0), u.arg(args, 1)));
}

fn fromEntries(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const out = try objmod.newPlain(vm);
    const Ctx = struct {
        vm: *Vm,
        out: *Object,
        fn add(c: @This(), item: Value) Error!void {
            if (!item.isObject()) return c.vm.throwError(.TypeError, "Iterator value is not an entry object");
            const k = try props.get(c.vm, item.asObject(), PropKey.fromIndex(0));
            const v = try props.get(c.vm, item.asObject(), PropKey.fromIndex(1));
            try props.defineData(c.vm, c.out, try conv.toPropKey(c.vm, k), v, PropFlags.all);
        }
    };
    try iter.forEach(vm, u.arg(args, 0), Ctx{ .vm = vm, .out = out }, Ctx.add);
    return out.value();
}

fn hasOwnStatic(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, u.arg(args, 0));
    const key = try conv.toPropKey(vm, u.arg(args, 1));
    return Value.fromBool(try props.hasOwn(vm, o, key));
}

fn groupBy(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const out = try objmod.create(vm, null, .object);
    const Ctx = struct {
        vm: *Vm,
        out: *Object,
        cb: Value,
        i: *u32,
        fn add(c: @This(), item: Value) Error!void {
            const kv = try calls.call(c.vm, c.cb, Value.undefined, &.{ item, Value.fromUsize(c.i.*) });
            c.i.* += 1;
            const k = try conv.toPropKey(c.vm, kv);
            const cur = try props.get(c.vm, c.out, k);
            if (cur.isObject()) {
                try objmod.arrayPush(c.vm, cur.asObject(), item);
            } else {
                try props.defineData(c.vm, c.out, k, (try objmod.newArray(c.vm, &.{item})).value(), PropFlags.all);
            }
        }
    };
    var i: u32 = 0;
    if (!u.arg(args, 1).isCallable()) return vm.throwError(.TypeError, "callback is not a function");
    try iter.forEach(vm, u.arg(args, 0), Ctx{ .vm = vm, .out = out, .cb = u.arg(args, 1), .i = &i }, Ctx.add);
    return out.value();
}

fn hasOwnProperty(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const key = try conv.toPropKey(vm, u.arg(args, 0));
    const o = try conv.toObject(vm, this);
    return Value.fromBool(try props.hasOwn(vm, o, key));
}

fn isPrototypeOf(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const v = u.arg(args, 0);
    if (!v.isObject()) return Value.false;
    const o = try conv.toObject(vm, this);
    var p = try props.getProto(vm, v.asObject());
    while (p) |x| : (p = try props.getProto(vm, x)) {
        if (x == o) return Value.true;
    }
    return Value.false;
}

fn propertyIsEnumerable(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const key = try conv.toPropKey(vm, u.arg(args, 0));
    const o = try conv.toObject(vm, this);
    const own = try props.getOwn(vm, o, key) orelse return Value.false;
    return Value.fromBool(own.flags.enumerable);
}

fn valueOf(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return (try conv.toObject(vm, this)).value();
}

fn toLocaleString(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const m = try props.getV(vm, this, vm.k.toString);
    return calls.call(vm, m, this, &.{});
}

fn builtinTag(vm: *Vm, o: *Object) Error![]const u8 {
    if (try @import("b_array.zig").isArrayValue(vm, o.value())) return "Array";
    return switch (o.class) {
        .array => "Array",
        .arguments => "Arguments",
        .closure, .native, .bound => "Function",
        .@"error" => "Error",
        .boolean => "Boolean",
        .number => "Number",
        .string => "String",
        .date => "Date",
        .regexp => "RegExp",
        .proxy => if (o.flags.callable) "Function" else "Object",
        else => "Object",
    };
}

pub fn toStringFn(vm: *Vm, this: Value, _: []const Value) Error!Value {
    if (this.isUndefined()) return api.newString(vm, "[object Undefined]");
    if (this.isNull()) return api.newString(vm, "[object Null]");
    const o = try conv.toObject(vm, this);
    const tag = try props.get(vm, o, PropKey.fromSymbol(vm.sym.toStringTag));
    var b = str.Builder.init(vm);
    defer b.deinit();
    try b.bytes("[object ");
    if (tag.isString()) {
        try b.str(tag.asString());
    } else {
        try b.bytes(try builtinTag(vm, o));
    }
    try b.byte(']');
    return Value.fromString(try b.finish());
}

fn protoGet(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const p = try props.getProto(vm, o);
    return if (p) |x| x.value() else Value.null;
}

fn protoSet(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const p = u.arg(args, 0);
    if (this.isNullish()) return vm.throwError(.TypeError, "Object.prototype.__proto__ called on null or undefined");
    if (!p.isObject() and !p.isNull()) return Value.undefined;
    if (!this.isObject()) return Value.undefined;
    if (!try props.setProto(vm, this.asObject(), if (p.isObject()) p.asObject() else null)) {
        return vm.throwError(.TypeError, "Cyclic __proto__ value");
    }
    return Value.undefined;
}

fn defineGetter(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    if (!u.arg(args, 1).isCallable()) return vm.throwError(.TypeError, "Getter must be a function");
    try defineOrThrow(vm, o, try conv.toPropKey(vm, u.arg(args, 0)), .{ .get = u.arg(args, 1), .enumerable = true, .configurable = true });
    return Value.undefined;
}
fn defineSetter(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    if (!u.arg(args, 1).isCallable()) return vm.throwError(.TypeError, "Setter must be a function");
    try defineOrThrow(vm, o, try conv.toPropKey(vm, u.arg(args, 0)), .{ .set = u.arg(args, 1), .enumerable = true, .configurable = true });
    return Value.undefined;
}
fn lookupAccessor(vm: *Vm, this: Value, kv: Value, want_get: bool) Error!Value {
    const key = try conv.toPropKey(vm, kv);
    var o: ?*Object = try conv.toObject(vm, this);
    while (o) |x| : (o = try props.getProto(vm, x)) {
        const own = try props.getOwn(vm, x, key) orelse continue;
        if (!own.flags.accessor) return Value.undefined;
        return if (want_get) own.get else own.set;
    }
    return Value.undefined;
}
fn lookupGetter(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return lookupAccessor(vm, this, u.arg(args, 0), true);
}
fn lookupSetter(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return lookupAccessor(vm, this, u.arg(args, 0), false);
}

pub fn init(vm: *Vm) Error!void {
    const proto = vm.protos.object;
    const c = try u.ctor(vm, "Object", 1, objectCtor, proto);
    try u.method(vm, c, "defineProperty", 3, defineProperty);
    try u.method(vm, c, "defineProperties", 2, defineProperties);
    try u.method(vm, c, "create", 2, create);
    try u.method(vm, c, "getPrototypeOf", 1, getPrototypeOf);
    try u.method(vm, c, "setPrototypeOf", 2, setPrototypeOf);
    try u.method(vm, c, "getOwnPropertyDescriptor", 2, getOwnPropertyDescriptor);
    try u.method(vm, c, "getOwnPropertyDescriptors", 1, getOwnPropertyDescriptors);
    try u.method(vm, c, "getOwnPropertyNames", 1, getOwnPropertyNames);
    try u.method(vm, c, "getOwnPropertySymbols", 1, getOwnPropertySymbols);
    try u.method(vm, c, "keys", 1, keysFn);
    try u.method(vm, c, "values", 1, valuesFn);
    try u.method(vm, c, "entries", 1, entriesFn);
    try u.method(vm, c, "assign", 2, assign);
    try u.method(vm, c, "freeze", 1, freeze);
    try u.method(vm, c, "seal", 1, seal);
    try u.method(vm, c, "preventExtensions", 1, preventExtensionsFn);
    try u.method(vm, c, "isFrozen", 1, isFrozen);
    try u.method(vm, c, "isSealed", 1, isSealed);
    try u.method(vm, c, "isExtensible", 1, isExtensibleFn);
    try u.method(vm, c, "is", 2, isFn);
    try u.method(vm, c, "fromEntries", 1, fromEntries);
    try u.method(vm, c, "hasOwn", 2, hasOwnStatic);
    try u.method(vm, c, "groupBy", 2, groupBy);
    try u.method(vm, proto, "hasOwnProperty", 1, hasOwnProperty);
    try u.method(vm, proto, "isPrototypeOf", 1, isPrototypeOf);
    try u.method(vm, proto, "propertyIsEnumerable", 1, propertyIsEnumerable);
    try u.method(vm, proto, "valueOf", 0, valueOf);
    try u.method(vm, proto, "toLocaleString", 0, toLocaleString);
    try u.method(vm, proto, "toString", 0, toStringFn);
    try u.method(vm, proto, "__defineGetter__", 2, defineGetter);
    try u.method(vm, proto, "__defineSetter__", 2, defineSetter);
    try u.method(vm, proto, "__lookupGetter__", 1, lookupGetter);
    try u.method(vm, proto, "__lookupSetter__", 1, lookupSetter);
    try api.defineAccessorOn(vm, proto, "__proto__", protoGet, protoSet);
}
