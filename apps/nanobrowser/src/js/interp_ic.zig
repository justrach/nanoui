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
const heap = @import("heap.zig");
const interp_call = @import("interp_call.zig");
const typed = @import("b_typed.zig");

pub inline fn callGetterSlot(vm: *Vm, slot_val: Value, receiver: Value) Error!Value {
    return props.callGetter(vm, slot_val, receiver);
}

pub fn callSetterSlot(vm: *Vm, ic: *bc.IC, slot_val: Value, receiver: Value, v: Value, strict: bool) Error!void {
    const a: *heap.Accessor = @fieldParentPtr("cell", slot_val.asCell());
    if (a.set.isUndefined()) {
        if (strict) return props.throwReadonly(vm, ic.key);
        return;
    }
    _ = try interp_call.call(vm, a.set, receiver, &.{v});
}

pub fn getField(vm: *Vm, ic: *bc.IC, v: Value) Error!Value {
    if (!v.isObject()) return props.getV(vm, v, ic.key);
    const o = v.asObject();
    if (o.shape == ic.shape) {
        if (ic.fast_own_data) return o.slots[ic.slot];
        if (ic.fast_proto_data and ic.epoch == vm.proto_epoch and ic.holder.?.shape == ic.holder_shape) return ic.holder.?.slots[ic.slot];
        if (ic.slot == bc.IC.missing_slot) {
            if (ic.epoch == vm.proto_epoch) return Value.undefined;
        } else if (if (ic.holder) |h| (h.shape == ic.holder_shape and ic.epoch == vm.proto_epoch) else true) {
            const sv = (ic.holder orelse o).slots[ic.slot];
            return if (ic.is_accessor) props.callGetter(vm, sv, v) else sv;
        }
    }
    if (!o.flags.exotic and !ic.key.isIndex()) {
        if (o.flags.lazy_fn) try props.touchLazy(vm, o, ic.key);
        const sh = o.shape;
        if (sh.find(ic.key)) |slot| {
            const acc = sh.flagsAt(slot).accessor;
            if (!sh.is_dict) {
                ic.shape = sh;
                ic.holder = null;
                ic.holder_shape = null;
                ic.slot = slot;
                ic.epoch = 0;
                ic.is_accessor = acc;
                ic.is_transition = false;
                ic.fast_own_data = !acc;
                ic.fast_proto_data = false;
            }
            if (acc) return props.callGetter(vm, o.slots[slot], v);
            return o.slots[slot];
        }
        // A lazy function's name and length aren't in its shape yet, so "not found here" can't be cached.
        const is_lazy_key = ic.key.eql(vm.k.name) or ic.key.eql(vm.k.length) or ic.key.eql(vm.k.prototype);
        const recv_may_be_lazy = is_lazy_key and (o.class == .closure or o.class == .native or sh == vm.fn_root);
        if (!sh.is_dict and !recv_may_be_lazy and !(o.class == .array and ic.key.eql(vm.k.length))) {
            var cur = sh.proto;
            while (cur) |h| : (cur = h.shape.proto) {
                if (h.flags.exotic or h.shape.is_dict) break;
                if (h.flags.lazy_fn) try props.touchLazy(vm, h, ic.key);
                if (h.class == .array and ic.key.eql(vm.k.length)) break;
                const hs = h.shape;
                if ((hs == vm.fn_root or h.class == .closure or h.class == .native) and is_lazy_key) break;
                if (hs.find(ic.key)) |slot| {
                    const acc = hs.flagsAt(slot).accessor;
                    if (!hs.is_dict) {
                        ic.shape = sh;
                        ic.holder = h;
                        ic.holder_shape = hs;
                        ic.slot = slot;
                        ic.epoch = vm.proto_epoch;
                        ic.is_accessor = acc;
                        ic.is_transition = false;
                        ic.fast_own_data = false;
                        ic.fast_proto_data = !acc;
                    }
                    if (acc) return props.callGetter(vm, h.slots[slot], v);
                    return h.slots[slot];
                }
            } else {
                ic.shape = sh;
                ic.holder = null;
                ic.holder_shape = null;
                ic.slot = bc.IC.missing_slot;
                ic.epoch = vm.proto_epoch;
                ic.is_accessor = false;
                ic.is_transition = false;
                ic.fast_own_data = false;
                ic.fast_proto_data = false;
                return Value.undefined;
            }
        }
    }
    return props.getR(vm, o, ic.key, v);
}

pub fn putField(vm: *Vm, ic: *bc.IC, t: Value, v: Value, strict: bool) Error!void {
    if (!t.isObject()) return putOnPrimitive(vm, t, ic.key, v, strict);
    const o = t.asObject();
    if (o.shape == ic.shape) {
        if (ic.fast_own_data) {
            o.slots[ic.slot] = v;
            return;
        }
        if (ic.is_transition and ic.epoch == vm.proto_epoch and o.flags.extensible and !o.flags.is_proto) {
            if (ic.slot >= o.slot_cap) try objmod.growSlots(vm, o, ic.slot + 1);
            o.shape = ic.holder_shape.?;
            o.slots[ic.slot] = v;
            return;
        }
        if (ic.is_accessor and (if (ic.holder) |h| (h.shape == ic.holder_shape and ic.epoch == vm.proto_epoch) else true)) {
            return callSetterSlot(vm, ic, (ic.holder orelse o).slots[ic.slot], t, v, strict);
        }
    }
    if (!o.flags.exotic and !ic.key.isIndex() and !o.flags.lazy_fn) {
        const sh = o.shape;
        if (sh.find(ic.key)) |slot| {
            const f = sh.flagsAt(slot);
            if (f.accessor) {
                if (!sh.is_dict) {
                    ic.shape = sh;
                    ic.holder = null;
                    ic.holder_shape = null;
                    ic.slot = slot;
                    ic.epoch = 0;
                    ic.is_accessor = true;
                    ic.is_transition = false;
                    ic.fast_own_data = false;
                }
                return callSetterSlot(vm, ic, o.slots[slot], t, v, strict);
            }
            if (f.writable) {
                if (!sh.is_dict) {
                    ic.shape = sh;
                    ic.holder = null;
                    ic.holder_shape = null;
                    ic.slot = slot;
                    ic.epoch = 0;
                    ic.is_accessor = false;
                    ic.is_transition = false;
                    ic.fast_own_data = true;
                }
                o.slots[slot] = v;
                return;
            }
        } else if (!sh.is_dict and !(o.class == .array and ic.key.eql(vm.k.length))) {
            var cur = sh.proto;
            while (cur) |h| : (cur = h.shape.proto) {
                if (h.flags.exotic or h.shape.is_dict or h.flags.lazy_fn) break;
                if (h.class == .array and ic.key.eql(vm.k.length)) break;
                const hs = h.shape;
                if (hs.find(ic.key)) |slot| {
                    if (hs.flagsAt(slot).accessor and !hs.is_dict) {
                        ic.shape = sh;
                        ic.holder = h;
                        ic.holder_shape = hs;
                        ic.slot = slot;
                        ic.epoch = vm.proto_epoch;
                        ic.is_accessor = true;
                        ic.is_transition = false;
                        ic.fast_own_data = false;
                        return callSetterSlot(vm, ic, h.slots[slot], t, v, strict);
                    }
                    break;
                }
            } else if (o.flags.extensible and !o.flags.is_proto and sh.count < 512) {
                const slot = sh.count;
                if (slot >= o.slot_cap) try objmod.growSlots(vm, o, slot + 1);
                const new_sh = try shape_mod.transition(vm, sh, ic.key, shape_mod.PropFlags.all);
                o.shape = new_sh;
                o.slots[slot] = v;
                ic.shape = sh;
                ic.holder = null;
                ic.holder_shape = new_sh;
                ic.slot = slot;
                ic.epoch = vm.proto_epoch;
                ic.is_accessor = false;
                ic.is_transition = true;
                ic.fast_own_data = false;
                return;
            }
        }
    }
    if (!try props.setR(vm, o, ic.key, v, t)) {
        if (strict) return props.throwReadonly(vm, ic.key);
    }
}

pub fn defineField(vm: *Vm, ic: *bc.IC, o: *Object, v: Value) Error!void {
    if (o.shape == ic.shape and ic.is_transition and !o.flags.is_proto) {
        if (ic.slot >= o.slot_cap) try objmod.growSlots(vm, o, ic.slot + 1);
        o.shape = ic.holder_shape.?;
        o.slots[ic.slot] = v;
        return;
    }
    const sh = o.shape;
    if (!o.flags.exotic and !o.flags.lazy_fn and !o.flags.is_proto and !ic.key.isIndex() and !sh.is_dict and sh.count < 512 and !(o.class == .array and ic.key.eql(vm.k.length))) {
        if (sh.find(ic.key) == null) {
            const slot = sh.count;
            if (slot >= o.slot_cap) try objmod.growSlots(vm, o, slot + 1);
            const new_sh = try shape_mod.transition(vm, sh, ic.key, shape_mod.PropFlags.all);
            o.shape = new_sh;
            o.slots[slot] = v;
            ic.shape = sh;
            ic.holder = null;
            ic.holder_shape = new_sh;
            ic.slot = slot;
            ic.epoch = 0;
            ic.is_accessor = false;
            ic.is_transition = true;
            ic.fast_own_data = false;
            return;
        }
    }
    return props.defineData(vm, o, ic.key, v, shape_mod.PropFlags.all);
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
    if (t.isObject()) {
        const o = t.asObject();
        if (k.isInt() and k.asInt() >= 0) {
            const i: u32 = @intCast(k.asInt());
            if (i < o.elems_len and !o.flags.exotic) {
                const r = o.elems[i];
                if (!r.isHole()) return r;
            }
            if (o.class == .typedarray) return typed.getIndex(vm, o, i);
            if (!o.flags.exotic and !o.flags.has_sparse) {
                if ((o.shape.proto == vm.protos.array and !vm.protos.array.flags.proto_dirty and !vm.protos.object.flags.proto_dirty) or
                    (o.shape.proto == vm.protos.object and !vm.protos.object.flags.proto_dirty) or
                    o.shape.proto == null)
                {
                    return Value.undefined;
                }
            }
            return props.getR(vm, o, PropKey.fromIndex(i), t);
        }
        if (k.isString()) {
            const s = k.asString();
            const key = if (s.key.bits != 0) s.key else try str.toKey(vm, s);
            if (!o.flags.exotic and !o.flags.lazy_fn and !key.isIndex()) {
                if (o.shape.find(key)) |slot| {
                    if (!o.shape.flagsAt(slot).accessor) return o.slots[slot];
                }
            }
            return props.getR(vm, o, key, t);
        }
    }
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
    if (t.isObject()) {
        const o = t.asObject();
        if (k.isInt() and k.asInt() >= 0) {
            const i: u32 = @intCast(k.asInt());
            if (i < o.elems_len and !o.flags.exotic and !o.flags.elems_frozen and !o.elems[i].isHole()) {
                o.elems[i] = v;
                return;
            }
            if (o.class == .typedarray) return typed.setIndex(vm, o, i, v);
            if (i == o.elems_len and o.class == .array and o.shape.proto == vm.protos.array and !vm.protos.array.flags.proto_dirty and !vm.protos.object.flags.proto_dirty and o.flags.extensible and !o.flags.elems_frozen and !o.flags.elems_sealed and !o.flags.length_readonly and !o.flags.is_proto) {
                if (i >= o.elems_cap) try objmod.growElems(vm, o, @as(usize, i) + 1);
                o.elems[i] = v;
                o.elems_len = i + 1;
                if (i >= o.arr_len) o.arr_len = i + 1;
                return;
            }
            if (!try props.setR(vm, o, PropKey.fromIndex(i), v, t)) {
                if (strict) return props.throwReadonly(vm, PropKey.fromIndex(i));
            }
            return;
        }
        if (k.isString()) {
            const s = k.asString();
            const key = if (s.key.bits != 0) s.key else try str.toKey(vm, s);
            if (!o.flags.exotic and !o.flags.lazy_fn and !key.isIndex()) {
                if (o.shape.find(key)) |slot| {
                    const fl = o.shape.flagsAt(slot);
                    if (fl.writable and !fl.accessor) {
                        if (o.flags.is_proto) {
                            o.flags.proto_dirty = true;
                            vm.bumpProtoEpoch();
                        }
                        o.slots[slot] = v;
                        return;
                    }
                }
            }
            if (!try props.setR(vm, o, key, v, t)) {
                if (strict) return props.throwReadonly(vm, key);
            }
            return;
        }
    }
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
