//! Helpers shared by the built-ins: argument access and installing methods.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const value = @import("value.zig");
pub const Value = value.Value;
pub const PropKey = value.PropKey;
const objmod = @import("object.zig");
pub const Object = objmod.Object;
const NativeFn = objmod.NativeFn;
const props = @import("props.zig");
const shape = @import("shape.zig");
pub const PropFlags = shape.PropFlags;
const str = @import("string.zig");
const api = @import("vm_api.zig");

pub inline fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else Value.undefined;
}

pub fn method(vm: *Vm, o: *Object, name: []const u8, arity: u32, f: NativeFn) Error!void {
    return api.defineMethodOn(vm, o, name, arity, f);
}

pub fn symMethod(vm: *Vm, o: *Object, sym: *str.Symbol, name: []const u8, arity: u32, f: NativeFn) Error!void {
    const fnv = try api.newNative(vm, name, arity, f);
    try props.defineData(vm, o, PropKey.fromSymbol(sym), fnv.value(), PropFlags.hidden);
}

pub fn getter(vm: *Vm, o: *Object, name: []const u8, f: NativeFn) Error!void {
    return api.defineAccessorOn(vm, o, name, f, null);
}

pub fn symGetter(vm: *Vm, o: *Object, sym: *str.Symbol, name: []const u8, f: NativeFn) Error!void {
    const g = try api.newNative(vm, name, 0, f);
    try props.defineAccessor(vm, o, PropKey.fromSymbol(sym), g.value(), Value.undefined, false);
}

/// A non-writable, non-enumerable, non-configurable value, as the Math constants are.
pub fn constant(vm: *Vm, o: *Object, name: []const u8, v: Value) Error!void {
    try props.defineData(vm, o, try str.keyFromBytes(vm, name), v, PropFlags.readonly);
}

pub fn data(vm: *Vm, o: *Object, name: []const u8, v: Value) Error!void {
    try props.defineData(vm, o, try str.keyFromBytes(vm, name), v, PropFlags.hidden);
}

pub fn toStringTag(vm: *Vm, o: *Object, name: []const u8) Error!void {
    const s = try str.intern(vm, name);
    try props.defineData(vm, o, PropKey.fromSymbol(vm.sym.toStringTag), Value.fromString(s), PropFlags.config_only);
}

/// A built-in constructor bound to `proto`, installed as a global.
pub fn ctor(vm: *Vm, name: []const u8, arity: u32, f: NativeFn, proto: *Object) Error!*Object {
    const c = try api.newNative(vm, name, arity, f);
    c.flags.constructor = true;
    try props.materialize(vm, c);
    try props.addProp(vm, c, vm.k.prototype, proto.value(), PropFlags.readonly);
    try props.defineData(vm, proto, vm.k.constructor, c.value(), PropFlags.hidden);
    try data(vm, vm.global_obj, name, c.value());
    return c;
}

pub fn newProto(vm: *Vm, parent: ?*Object) Error!*Object {
    return objmod.create(vm, parent, .object);
}

/// Species lookup: the constructor to make a derived object with.
pub fn speciesConstructor(vm: *Vm, o: *Object, default: *Object) Error!Value {
    const c = try props.get(vm, o, vm.k.constructor);
    if (c.isUndefined()) return default.value();
    if (!c.isObject()) return vm.throwError(.TypeError, "object.constructor is not an object");
    const s = try props.get(vm, c.asObject(), PropKey.fromSymbol(vm.sym.species));
    if (s.isNullish()) return default.value();
    if (s.isConstructor()) return s;
    return vm.throwError(.TypeError, "Symbol.species is not a constructor");
}

/// Clamps a relative index argument the way slice and friends do.
pub fn relativeIndex(vm: *Vm, v: Value, len: usize, default: usize) Error!usize {
    if (v.isUndefined()) return default;
    const conv = @import("conv.zig");
    const n = try conv.toIntegerOrInf(vm, v);
    const flen: f64 = @floatFromInt(len);
    if (n < 0) {
        return if (n + flen < 0) 0 else @intFromFloat(n + flen);
    }
    return if (n > flen) len else @intFromFloat(n);
}

pub fn returnThis(_: *Vm, this: Value, _: []const Value) Error!Value {
    return this;
}
