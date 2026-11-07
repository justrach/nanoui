//! Proxy (every trap, with the invariants that protect non-configurable properties)
//! and Reflect.

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
const Own = define.Own;
const conv = @import("conv.zig");
const ops = @import("ops.zig");
const str = @import("string.zig");
const calls = @import("interp_call.zig");
const api = @import("vm_api.zig");
const b_object = @import("b_object.zig");
const b_function = @import("b_function.zig");

const Parts = struct { target: *Object, handler: *Object };

fn parts(vm: *Vm, o: *Object) Error!Parts {
    const d = o.payload.proxy;
    if (d.handler == null) return vm.throwError(.TypeError, "Cannot perform operation on a proxy that has been revoked");
    return .{ .target = d.target.?, .handler = d.handler.? };
}

fn trap(vm: *Vm, h: *Object, name: []const u8) Error!?Value {
    const t = try props.get(vm, h, try str.keyFromBytes(vm, name));
    if (t.isNullish()) return null;
    if (!t.isCallable()) return vm.throwError(.TypeError, "Proxy trap is not a function");
    return t;
}

pub fn get(vm: *Vm, o: *Object, key: PropKey, receiver: Value) Error!Value {
    try vm.checkNativeStack();
    const p = try parts(vm, o);
    const t = try trap(vm, p.handler, "get") orelse return props.getR(vm, p.target, key, receiver);
    const r = try calls.call(vm, t, p.handler.value(), &.{ p.target.value(), try str.keyToValue(vm, key), receiver });
    if (try props.getOwn(vm, p.target, key)) |own| {
        if (!own.flags.configurable) {
            if (!own.flags.accessor and !own.flags.writable and !conv.sameValue(vm, r, own.value)) {
                return vm.throwError(.TypeError, "'get' on proxy: value differs from the non-writable, non-configurable target property");
            }
            if (own.flags.accessor and own.get.isUndefined() and !r.isUndefined()) {
                return vm.throwError(.TypeError, "'get' on proxy: non-configurable accessor without a getter must report undefined");
            }
        }
    }
    return r;
}

pub fn set(vm: *Vm, o: *Object, key: PropKey, val: Value, receiver: Value) Error!bool {
    try vm.checkNativeStack();
    const p = try parts(vm, o);
    const t = try trap(vm, p.handler, "set") orelse return props.setR(vm, p.target, key, val, receiver);
    const r = try calls.call(vm, t, p.handler.value(), &.{ p.target.value(), try str.keyToValue(vm, key), val, receiver });
    if (!ops.truthy(r)) return false;
    if (try props.getOwn(vm, p.target, key)) |own| {
        if (!own.flags.configurable) {
            if (!own.flags.accessor and !own.flags.writable and !conv.sameValue(vm, val, own.value)) {
                return vm.throwError(.TypeError, "'set' on proxy: cannot change a non-writable, non-configurable property");
            }
            if (own.flags.accessor and own.set.isUndefined()) {
                return vm.throwError(.TypeError, "'set' on proxy: non-configurable accessor has no setter");
            }
        }
    }
    return true;
}

pub fn has(vm: *Vm, o: *Object, key: PropKey) Error!bool {
    try vm.checkNativeStack();
    const p = try parts(vm, o);
    const t = try trap(vm, p.handler, "has") orelse return props.has(vm, p.target, key);
    const r = ops.truthy(try calls.call(vm, t, p.handler.value(), &.{ p.target.value(), try str.keyToValue(vm, key) }));
    if (!r) {
        if (try props.getOwn(vm, p.target, key)) |own| {
            if (!own.flags.configurable or !try props.isExtensible(vm, p.target)) {
                return vm.throwError(.TypeError, "'has' on proxy: cannot hide this property");
            }
        }
    }
    return r;
}

pub fn delete(vm: *Vm, o: *Object, key: PropKey) Error!bool {
    const p = try parts(vm, o);
    const t = try trap(vm, p.handler, "deleteProperty") orelse return props.delete(vm, p.target, key);
    const r = ops.truthy(try calls.call(vm, t, p.handler.value(), &.{ p.target.value(), try str.keyToValue(vm, key) }));
    if (r) {
        if (try props.getOwn(vm, p.target, key)) |own| {
            if (!own.flags.configurable or !try props.isExtensible(vm, p.target)) {
                return vm.throwError(.TypeError, "'deleteProperty' on proxy: cannot delete this property");
            }
        }
    }
    return r;
}

/// A descriptor completed with the defaults, as [[GetOwnProperty]] reports one.
fn complete(d: Desc) Own {
    var own = Own{ .flags = .{
        .enumerable = d.enumerable orelse false,
        .configurable = d.configurable orelse false,
        .writable = d.writable orelse false,
    } };
    if (d.isAccessor()) {
        own.flags.accessor = true;
        own.flags.writable = false;
        own.get = d.get orelse Value.undefined;
        own.set = d.set orelse Value.undefined;
    } else {
        own.value = d.value orelse Value.undefined;
    }
    return own;
}

pub fn getOwn(vm: *Vm, o: *Object, key: PropKey) Error!?Own {
    const p = try parts(vm, o);
    const t = try trap(vm, p.handler, "getOwnPropertyDescriptor") orelse return props.getOwn(vm, p.target, key);
    const r = try calls.call(vm, t, p.handler.value(), &.{ p.target.value(), try str.keyToValue(vm, key) });
    const target_own = try props.getOwn(vm, p.target, key);
    if (r.isUndefined()) {
        if (target_own) |own| {
            if (!own.flags.configurable or !try props.isExtensible(vm, p.target)) {
                return vm.throwError(.TypeError, "'getOwnPropertyDescriptor' on proxy: cannot hide this property");
            }
        }
        return null;
    }
    if (!r.isObject()) return vm.throwError(.TypeError, "'getOwnPropertyDescriptor' on proxy: trap returned neither object nor undefined");
    const c = complete(try b_object.toPropertyDescriptor(vm, r));
    if (!c.flags.configurable and (target_own == null or target_own.?.flags.configurable)) {
        return vm.throwError(.TypeError, "'getOwnPropertyDescriptor' on proxy: cannot report a non-configurable property that isn't one on the target");
    }
    if (target_own == null and !try props.isExtensible(vm, p.target)) {
        return vm.throwError(.TypeError, "'getOwnPropertyDescriptor' on proxy: cannot report a new property on a non-extensible target");
    }
    return c;
}

pub fn defineOwn(vm: *Vm, o: *Object, key: PropKey, d: Desc) Error!bool {
    const p = try parts(vm, o);
    const t = try trap(vm, p.handler, "defineProperty") orelse return props.defineOwn(vm, p.target, key, d);
    const dobj = try objmod.newPlain(vm);
    const k = &vm.k;
    if (d.value) |v| try props.addProp(vm, dobj, k.value, v, PropFlags.all);
    if (d.writable) |v| try props.addProp(vm, dobj, k.writable, Value.fromBool(v), PropFlags.all);
    if (d.get) |v| try props.addProp(vm, dobj, k.get, v, PropFlags.all);
    if (d.set) |v| try props.addProp(vm, dobj, k.set, v, PropFlags.all);
    if (d.enumerable) |v| try props.addProp(vm, dobj, k.enumerable, Value.fromBool(v), PropFlags.all);
    if (d.configurable) |v| try props.addProp(vm, dobj, k.configurable, Value.fromBool(v), PropFlags.all);
    const r = try calls.call(vm, t, p.handler.value(), &.{ p.target.value(), try str.keyToValue(vm, key), dobj.value() });
    if (!ops.truthy(r)) return false;
    const target_own = try props.getOwn(vm, p.target, key);
    if (target_own == null) {
        if (!try props.isExtensible(vm, p.target)) return vm.throwError(.TypeError, "'defineProperty' on proxy: cannot add a property to a non-extensible target");
        if (d.configurable == false) return vm.throwError(.TypeError, "'defineProperty' on proxy: cannot define a non-configurable property that isn't one on the target");
    } else if (d.configurable == false and target_own.?.flags.configurable) {
        return vm.throwError(.TypeError, "'defineProperty' on proxy: cannot define a non-configurable property that isn't one on the target");
    }
    return true;
}

/// The caller frees the slice with vm.gpa.
pub fn ownKeys(vm: *Vm, o: *Object) Error![]PropKey {
    const p = try parts(vm, o);
    const t = try trap(vm, p.handler, "ownKeys") orelse return props.ownKeys(vm, p.target);
    const r = try calls.call(vm, t, p.handler.value(), &.{p.target.value()});
    if (!r.isObject()) return vm.throwError(.TypeError, "CreateListFromArrayLike called on non-object");
    const list = try b_function.listFromArrayLike(vm, r);
    defer vm.gpa.free(list);
    const out = try vm.gpa.alloc(PropKey, list.len);
    errdefer vm.gpa.free(out);
    for (list, out, 0..) |v, *k, i| {
        if (!v.isString() and !v.isSymbol()) return vm.throwError(.TypeError, "ownKeys trap result must hold strings and symbols");
        k.* = try conv.toPropKey(vm, v);
        for (out[0..i]) |prev| {
            if (prev.eql(k.*)) return vm.throwError(.TypeError, "ownKeys trap result must not contain duplicates");
        }
    }
    // Non-configurable target keys must be reported; a non-extensible target's keys exactly.
    const target_keys = try props.ownKeys(vm, p.target);
    defer vm.gpa.free(target_keys);
    const extensible = try props.isExtensible(vm, p.target);
    for (target_keys) |tk| {
        const own = try props.getOwn(vm, p.target, tk) orelse continue;
        if (own.flags.configurable and extensible) continue;
        var found = false;
        for (out) |k| {
            if (k.eql(tk)) found = true;
        }
        if (!found) return vm.throwError(.TypeError, "ownKeys trap result must include the non-configurable target keys");
    }
    return out;
}

pub fn getProto(vm: *Vm, o: *Object) Error!?*Object {
    const p = try parts(vm, o);
    const t = try trap(vm, p.handler, "getPrototypeOf") orelse return props.getProto(vm, p.target);
    const r = try calls.call(vm, t, p.handler.value(), &.{p.target.value()});
    if (!r.isObject() and !r.isNull()) return vm.throwError(.TypeError, "'getPrototypeOf' on proxy: trap returned neither object nor null");
    const res: ?*Object = if (r.isObject()) r.asObject() else null;
    if (!try props.isExtensible(vm, p.target)) {
        if (res != try props.getProto(vm, p.target)) return vm.throwError(.TypeError, "'getPrototypeOf' on proxy: must report the prototype of a non-extensible target");
    }
    return res;
}

pub fn setProto(vm: *Vm, o: *Object, proto: ?*Object) Error!bool {
    const p = try parts(vm, o);
    const t = try trap(vm, p.handler, "setPrototypeOf") orelse return props.setProto(vm, p.target, proto);
    const pv = if (proto) |x| x.value() else Value.null;
    const r = ops.truthy(try calls.call(vm, t, p.handler.value(), &.{ p.target.value(), pv }));
    if (r and !try props.isExtensible(vm, p.target) and proto != try props.getProto(vm, p.target)) {
        return vm.throwError(.TypeError, "'setPrototypeOf' on proxy: cannot change a non-extensible target's prototype");
    }
    return r;
}

pub fn isExtensible(vm: *Vm, o: *Object) Error!bool {
    const p = try parts(vm, o);
    const t = try trap(vm, p.handler, "isExtensible") orelse return props.isExtensible(vm, p.target);
    const r = ops.truthy(try calls.call(vm, t, p.handler.value(), &.{p.target.value()}));
    if (r != try props.isExtensible(vm, p.target)) return vm.throwError(.TypeError, "'isExtensible' on proxy: trap result must match the target");
    return r;
}

pub fn preventExtensions(vm: *Vm, o: *Object) Error!bool {
    const p = try parts(vm, o);
    const t = try trap(vm, p.handler, "preventExtensions") orelse return props.preventExtensions(vm, p.target);
    const r = ops.truthy(try calls.call(vm, t, p.handler.value(), &.{p.target.value()}));
    if (r and try props.isExtensible(vm, p.target)) return vm.throwError(.TypeError, "'preventExtensions' on proxy: target is still extensible");
    return r;
}

pub fn callTrap(vm: *Vm, o: *Object, this: Value, args: []const Value) Error!Value {
    const p = try parts(vm, o);
    const t = try trap(vm, p.handler, "apply") orelse return calls.call(vm, p.target.value(), this, args);
    const arr = try objmod.newArray(vm, args);
    return calls.call(vm, t, p.handler.value(), &.{ p.target.value(), this, arr.value() });
}

pub fn constructTrap(vm: *Vm, o: *Object, args: []const Value, new_target: Value) Error!Value {
    const p = try parts(vm, o);
    const t = try trap(vm, p.handler, "construct") orelse {
        const nt = if (new_target.isObject() and new_target.asObject() == o) p.target.value() else new_target;
        return calls.construct(vm, p.target.value(), args, nt);
    };
    const arr = try objmod.newArray(vm, args);
    const r = try calls.call(vm, t, p.handler.value(), &.{ p.target.value(), arr.value(), new_target });
    if (!r.isObject()) return vm.throwError(.TypeError, "'construct' on proxy: trap returned non-object");
    return r;
}

fn makeProxy(vm: *Vm, tv: Value, hv: Value) Error!*Object {
    if (!tv.isObject() or !hv.isObject()) return vm.throwError(.TypeError, "Cannot create proxy with a non-object as target or handler");
    const data = try vm.gpa.create(objmod.ProxyData);
    data.* = .{ .target = tv.asObject(), .handler = hv.asObject() };
    const o = objmod.createExotic(vm, null, .proxy) catch |e| {
        vm.gpa.destroy(data);
        return e;
    };
    o.payload = .{ .proxy = data };
    o.flags.callable = tv.asObject().flags.callable;
    o.flags.constructor = tv.asObject().flags.constructor;
    return o;
}

fn proxyCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    if (vm.new_target.isUndefined()) return vm.throwError(.TypeError, "Constructor Proxy requires 'new'");
    return (try makeProxy(vm, u.arg(args, 0), u.arg(args, 1))).value();
}

fn revokeFn(vm: *Vm, _: Value, _: []const Value) Error!Value {
    const c = vm.capture(0);
    if (c.isObject()) {
        const d = c.asObject().payload.proxy;
        d.target = null;
        d.handler = null;
        vm.callee.?.payload.native.captures[0] = Value.null;
    }
    return Value.undefined;
}

fn revocable(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const p = try makeProxy(vm, u.arg(args, 0), u.arg(args, 1));
    const out = try objmod.newPlain(vm);
    try props.addProp(vm, out, vm.k.proxy, p.value(), PropFlags.all);
    const r = try api.newNativeClosure(vm, "", 0, revokeFn, &.{p.value()});
    try props.addProp(vm, out, vm.k.revoke, r, PropFlags.all);
    return out.value();
}

fn target(vm: *Vm, args: []const Value) Error!*Object {
    const t = u.arg(args, 0);
    if (!t.isObject()) return vm.throwError(.TypeError, "Reflect method called on non-object");
    return t.asObject();
}

fn rGet(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const t = try target(vm, args);
    const key = try conv.toPropKey(vm, u.arg(args, 1));
    return props.getR(vm, t, key, if (args.len > 2) args[2] else t.value());
}
fn rSet(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const t = try target(vm, args);
    const key = try conv.toPropKey(vm, u.arg(args, 1));
    return Value.fromBool(try props.setR(vm, t, key, u.arg(args, 2), if (args.len > 3) args[3] else t.value()));
}
fn rHas(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(try props.has(vm, try target(vm, args), try conv.toPropKey(vm, u.arg(args, 1))));
}
fn rDelete(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(try props.delete(vm, try target(vm, args), try conv.toPropKey(vm, u.arg(args, 1))));
}
fn rOwnKeys(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const keys = try props.ownKeys(vm, try target(vm, args));
    defer vm.gpa.free(keys);
    const out = try objmod.newArray(vm, &.{});
    for (keys) |k| try objmod.arrayPush(vm, out, try str.keyToValue(vm, k));
    return out.value();
}
fn rDefine(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const t = try target(vm, args);
    const key = try conv.toPropKey(vm, u.arg(args, 1));
    return Value.fromBool(try props.defineOwn(vm, t, key, try b_object.toPropertyDescriptor(vm, u.arg(args, 2))));
}
fn rGetOwn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const own = try props.getOwn(vm, try target(vm, args), try conv.toPropKey(vm, u.arg(args, 1))) orelse return Value.undefined;
    return b_object.fromPropertyDescriptor(vm, own);
}
fn rGetProto(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const p = try props.getProto(vm, try target(vm, args));
    return if (p) |x| x.value() else Value.null;
}
fn rSetProto(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const p = u.arg(args, 1);
    if (!p.isObject() and !p.isNull()) return vm.throwError(.TypeError, "Object prototype may only be an Object or null");
    return Value.fromBool(try props.setProto(vm, try target(vm, args), if (p.isObject()) p.asObject() else null));
}
fn rIsExtensible(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(try props.isExtensible(vm, try target(vm, args)));
}
fn rPreventExtensions(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(try props.preventExtensions(vm, try target(vm, args)));
}
fn rApply(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const list = try b_function.listFromArrayLike(vm, u.arg(args, 2));
    defer vm.gpa.free(list);
    return calls.call(vm, u.arg(args, 0), u.arg(args, 1), list);
}
fn rConstruct(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const nt = if (args.len > 2) args[2] else u.arg(args, 0);
    if (!nt.isConstructor()) return vm.throwError(.TypeError, "newTarget is not a constructor");
    const list = try b_function.listFromArrayLike(vm, u.arg(args, 1));
    defer vm.gpa.free(list);
    return calls.construct(vm, u.arg(args, 0), list, nt);
}

pub fn init(vm: *Vm) Error!void {
    const c = try api.newNative(vm, "Proxy", 2, proxyCtor);
    c.flags.constructor = true;
    try u.data(vm, vm.global_obj, "Proxy", c.value());
    try u.method(vm, c, "revocable", 2, revocable);
    const r = try objmod.newPlain(vm);
    try u.data(vm, vm.global_obj, "Reflect", r.value());
    try u.toStringTag(vm, r, "Reflect");
    try u.method(vm, r, "get", 2, rGet);
    try u.method(vm, r, "set", 3, rSet);
    try u.method(vm, r, "has", 2, rHas);
    try u.method(vm, r, "deleteProperty", 2, rDelete);
    try u.method(vm, r, "ownKeys", 1, rOwnKeys);
    try u.method(vm, r, "defineProperty", 3, rDefine);
    try u.method(vm, r, "getOwnPropertyDescriptor", 2, rGetOwn);
    try u.method(vm, r, "getPrototypeOf", 1, rGetProto);
    try u.method(vm, r, "setPrototypeOf", 2, rSetProto);
    try u.method(vm, r, "isExtensible", 1, rIsExtensible);
    try u.method(vm, r, "preventExtensions", 1, rPreventExtensions);
    try u.method(vm, r, "apply", 3, rApply);
    try u.method(vm, r, "construct", 2, rConstruct);
}
