//! The slow paths of property access, which also fill the inline caches. A cache holds
//! a receiver shape plus, for a hit on the prototype, the holder and its shape; since
//! the prototype is part of a shape, those two checks prove the lookup still holds.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const value = @import("value.zig");
const Value = value.Value;
const PropKey = value.PropKey;
const bc = @import("bytecode.zig");
const objmod = @import("object.zig");
const Object = objmod.Object;
const props = @import("props.zig");
const conv = @import("conv.zig");
const str = @import("string.zig");
const shape_mod = @import("shape.zig");

pub fn getField(vm: *Vm, ic: *bc.IC, v: Value) Error!Value {
    if (!v.isObject()) return props.getV(vm, v, ic.key);
    const o = v.asObject();
    if (!o.flags.exotic and !ic.key.isIndex()) {
        if (o.flags.lazy_fn) try props.touchLazy(vm, o, ic.key);
        const sh = o.shape;
        if (sh.find(ic.key)) |slot| {
            if (!sh.flagsAt(slot).accessor) {
                if (!sh.is_dict) {
                    ic.shape = sh;
                    ic.holder = null;
                    ic.slot = slot;
                }
                return o.slots[slot];
            }
        } else if (sh.proto) |h| {
            // A lazy function's name and length aren't in its shape yet, so "not found here" can't be cached.
            const lazy_key = sh == vm.fn_root and (ic.key.eql(vm.k.name) or ic.key.eql(vm.k.length) or ic.key.eql(vm.k.prototype));
            if (!h.flags.exotic and !sh.is_dict and !lazy_key and !(o.class == .array and ic.key.eql(vm.k.length))) {
                if (h.flags.lazy_fn) try props.touchLazy(vm, h, ic.key);
                const hs = h.shape;
                if (hs.find(ic.key)) |slot| {
                    if (!hs.flagsAt(slot).accessor and !hs.is_dict) {
                        ic.shape = sh;
                        ic.holder = h;
                        ic.holder_shape = hs;
                        ic.slot = slot;
                        return h.slots[slot];
                    }
                }
            }
        }
    }
    return props.getR(vm, o, ic.key, v);
}

pub fn putField(vm: *Vm, ic: *bc.IC, t: Value, v: Value, strict: bool) Error!void {
    if (!t.isObject()) return putOnPrimitive(vm, t, ic.key, v, strict);
    const o = t.asObject();
    if (!o.flags.exotic and !ic.key.isIndex() and !o.flags.lazy_fn) {
        const sh = o.shape;
        if (sh.find(ic.key)) |slot| {
            const f = sh.flagsAt(slot);
            if (f.writable and !f.accessor) {
                if (!sh.is_dict) {
                    ic.shape = sh;
                    ic.holder = null;
                    ic.slot = slot;
                }
                o.slots[slot] = v;
                return;
            }
        }
    }
    if (!try props.setR(vm, o, ic.key, v, t)) {
        if (strict) return props.throwReadonly(vm, ic.key);
    }
}

fn putOnPrimitive(vm: *Vm, t: Value, key: PropKey, v: Value, strict: bool) Error!void {
    if (t.isNullish()) {
        var buf: [128]u8 = undefined;
        const name = str.keyText(vm, key, buf[0..64]);
        const m = std.fmt.bufPrint(buf[64..], "Cannot set properties of {s} ('{s}')", .{ if (t.isNull()) "null" else "undefined", name[0..@min(name.len, 24)] }) catch "Cannot set properties of nullish value";
        return vm.throwError(.TypeError, m);
    }
    const wrapper = try conv.toObject(vm, t);
    const ok = try props.setR(vm, wrapper, key, v, t);
    if (!ok and strict) {
        return vm.throwError(.TypeError, "Cannot create property on a primitive value");
    }
}

pub fn getElem(vm: *Vm, t: Value, k: Value) Error!Value {
    if (t.isString() and k.isInt()) {
        const s = t.asString();
        const i: u32 = @bitCast(k.asInt());
        if (i < s.len16) {
            return Value.fromString(try str.fromCodeUnit(vm, try s.unitAt(vm, i)));
        }
    }
    if (t.isNullish()) {
        var b: [128]u8 = undefined;
        var kb: [32]u8 = undefined;
        const ks = if (k.isString()) (k.asString().flat(vm) catch "?") else if (k.isInt()) std.fmt.bufPrint(&kb, "{d}", .{k.asInt()}) catch "?" else "?";
        const m = std.fmt.bufPrint(&b, "Cannot read properties of {s} (reading '{s}')", .{ if (t.isNull()) "null" else "undefined", ks[0..@min(ks.len, 32)] }) catch "Cannot read properties of nullish value";
        return vm.throwError(.TypeError, m);
    }
    const key = try conv.toPropKey(vm, k);
    return props.getV(vm, t, key);
}

pub fn putElem(vm: *Vm, t: Value, k: Value, v: Value, strict: bool) Error!void {
    if (t.isNullish()) {
        const key = try conv.toPropKey(vm, k);
        return putOnPrimitive(vm, t, key, v, strict);
    }
    const key = try conv.toPropKey(vm, k);
    if (!t.isObject()) return putOnPrimitive(vm, t, key, v, strict);
    if (!try props.setR(vm, t.asObject(), key, v, t)) {
        if (strict) return props.throwReadonly(vm, key);
    }
}

fn notDefined(vm: *Vm, key: PropKey) Error {
    var buf: [128]u8 = undefined;
    const name = str.keyText(vm, key, buf[0..64]);
    const m = std.fmt.bufPrint(buf[64..], "{s} is not defined", .{name[0..@min(name.len, 40)]}) catch "variable is not defined";
    return vm.throwError(.ReferenceError, m);
}

pub fn throwTdzKey(vm: *Vm, key: PropKey) Error {
    var buf: [128]u8 = undefined;
    const name = str.keyText(vm, key, buf[0..64]);
    const m = std.fmt.bufPrint(buf[64..], "Cannot access '{s}' before initialization", .{name[0..@min(name.len, 24)]}) catch "Cannot access variable before initialization";
    return vm.throwError(.ReferenceError, m);
}

fn fillGlobal(vm: *Vm, ic: *bc.IC, holder: *Object, slot: u32) void {
    if (holder.shape.is_dict) return;
    if (vm.global_lex.shape.is_dict or vm.global_obj.shape.is_dict) return;
    ic.shape = vm.global_lex.shape;
    ic.holder_shape = vm.global_obj.shape;
    ic.holder = holder;
    ic.slot = slot;
}

/// Reads a global. typeof uses getGlobalOrUndefined instead, which never throws for a missing name.
pub fn getGlobal(vm: *Vm, ic: *bc.IC) Error!Value {
    const lex = vm.global_lex;
    if (lex.shape.find(ic.key)) |slot| {
        const v = lex.slots[slot];
        if (v.isHole()) return throwTdzKey(vm, ic.key);
        fillGlobal(vm, ic, lex, slot);
        return v;
    }
    const g = vm.global_obj;
    if (g.shape.find(ic.key)) |slot| {
        if (!g.shape.flagsAt(slot).accessor) {
            fillGlobal(vm, ic, g, slot);
            return g.slots[slot];
        }
    }
    if (!try props.has(vm, g, ic.key)) return notDefined(vm, ic.key);
    return props.get(vm, g, ic.key);
}

pub fn getGlobalOrUndefined(vm: *Vm, ic: *bc.IC) Error!Value {
    const lex = vm.global_lex;
    if (lex.shape.find(ic.key)) |slot| {
        const v = lex.slots[slot];
        if (v.isHole()) return throwTdzKey(vm, ic.key);
        return v;
    }
    return props.get(vm, vm.global_obj, ic.key);
}

pub fn putGlobal(vm: *Vm, ic: *bc.IC, v: Value, strict: bool) Error!void {
    const lex = vm.global_lex;
    if (lex.shape.find(ic.key)) |slot| {
        if (lex.slots[slot].isHole()) return throwTdzKey(vm, ic.key);
        if (!lex.shape.flagsAt(slot).writable) return vm.throwError(.TypeError, "Assignment to constant variable.");
        lex.slots[slot] = v;
        fillGlobal(vm, ic, lex, slot);
        return;
    }
    const g = vm.global_obj;
    if (g.shape.find(ic.key)) |slot| {
        const f = g.shape.flagsAt(slot);
        if (f.writable and !f.accessor) {
            g.slots[slot] = v;
            fillGlobal(vm, ic, g, slot);
            return;
        }
    } else if (strict and !try props.has(vm, g, ic.key)) {
        return notDefined(vm, ic.key);
    }
    if (!try props.set(vm, g, ic.key, v) and strict) return props.throwReadonly(vm, ic.key);
}

/// let/const/class initialization at script level.
pub fn initGlobalLex(vm: *Vm, ic: *bc.IC, v: Value) Error!void {
    const lex = vm.global_lex;
    const slot = lex.shape.find(ic.key) orelse return notDefined(vm, ic.key);
    lex.slots[slot] = v;
}

pub fn declareGlobalLex(vm: *Vm, key: PropKey, is_const: bool) Error!void {
    const lex = vm.global_lex;
    if (lex.shape.find(key) != null) return redeclared(vm, key);
    if (vm.global_obj.shape.find(key)) |slot| {
        if (!vm.global_obj.shape.flagsAt(slot).configurable) return redeclared(vm, key);
    }
    try props.addProp(vm, lex, key, Value.hole, .{ .writable = !is_const });
}

pub fn declareGlobalVar(vm: *Vm, key: PropKey) Error!void {
    if (vm.global_lex.shape.find(key) != null) return redeclared(vm, key);
    const g = vm.global_obj;
    if (g.shape.find(key) != null) return;
    try props.addProp(vm, g, key, Value.undefined, .{ .configurable = false });
}

pub fn defineGlobalFn(vm: *Vm, key: PropKey, f: Value) Error!void {
    if (vm.global_lex.shape.find(key) != null) return redeclared(vm, key);
    try props.defineData(vm, vm.global_obj, key, f, .{ .configurable = false });
}

fn redeclared(vm: *Vm, key: PropKey) Error {
    var buf: [128]u8 = undefined;
    const name = str.keyText(vm, key, buf[0..64]);
    const m = std.fmt.bufPrint(buf[64..], "Identifier '{s}' has already been declared", .{name[0..@min(name.len, 24)]}) catch "Identifier has already been declared";
    return vm.throwError(.SyntaxError, m);
}
