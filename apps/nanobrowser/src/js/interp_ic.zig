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

pub inline fn callGetterSlot(vm: *Vm, slot_val: Value, receiver: Value) Error!Value {
    return props.callGetter(vm, slot_val, receiver);
}

pub inline fn noExoticOnChain(o: *const Object) bool {
    var cur: ?*const Object = o;
    while (cur) |c| : (cur = c.shape.proto) {
        if (c.flags.exotic) return false;
    }
    return true;
}

inline fn pushOwnPoly(ic: *bc.IC, cur_sh: *shape_mod.Shape) void {
    if (ic.fast_own_data and ic.shape != null and ic.shape != cur_sh) {
        if (!addOwnPolySlot(ic, ic.shape.?, ic.slot)) {
            const idx = ic.own_idx & (bc.IC.own_poly_cap - 1);
            ic.own_shapes[idx] = ic.shape;
            ic.own_slots[idx] = ic.slot;
            ic.own_idx +%= 1;
        }
    }
}

inline fn addOwnPolySlot(ic: *bc.IC, sh: *shape_mod.Shape, slot: u32) bool {
    inline for (0..bc.IC.own_poly_cap) |k| {
        if (ic.own_shapes[k] == sh) return true;
        if (ic.own_shapes[k] == null) {
            ic.own_shapes[k] = sh;
            ic.own_slots[k] = slot;
            return true;
        }
    }
    return false;
}

inline fn isStaleProtoIC(ic: *const bc.IC, proto_epoch: u32) bool {
    if (ic.fast_own_data) return false;
    if (ic.epoch != proto_epoch) return true;
    if (ic.holder) |h| if (h.shape != ic.holder_shape) return true;
    return false;
}

inline fn fillFromMega(ic: *bc.IC, sh: *shape_mod.Shape, me: *const vm_mod.MegaICEntry, proto_epoch: u32) void {
    if (me.holder) |mh| {
        const acc = (me.slot & vm_mod.MegaICEntry.acc_flag) != 0;
        const idx = me.slot & ~vm_mod.MegaICEntry.acc_flag;
        if (!ic.fast_own_data and ic.holder == mh and ic.holder_shape == me.holder_shape and ic.slot == idx and ic.is_accessor == acc and ic.epoch == proto_epoch) {
            if (ic.shape == null) ic.shape = sh else if (ic.shape != sh) insertProtoPoly(ic, sh);
        } else if (ic.shape == null or isStaleProtoIC(ic, proto_epoch)) {
            ic.proto_shapes = @splat(null);
            ic.proto_idx = 0;
            ic.shape = sh;
            ic.holder = mh;
            ic.holder_shape = me.holder_shape;
            ic.slot = idx;
            ic.epoch = proto_epoch;
            ic.is_accessor = acc;
            ic.is_transition = false;
            ic.fast_own_data = false;
            ic.fast_proto_data = !acc;
        }
    } else if (me.slot == bc.IC.missing_slot) {
        if (!ic.fast_own_data and ic.holder == null and ic.slot == bc.IC.missing_slot and ic.epoch == proto_epoch) {
            if (ic.shape == null) ic.shape = sh else if (ic.shape != sh) insertProtoPoly(ic, sh);
        } else if (ic.shape == null or isStaleProtoIC(ic, proto_epoch)) {
            ic.proto_shapes = @splat(null);
            ic.proto_idx = 0;
            ic.shape = sh;
            ic.holder = null;
            ic.holder_shape = null;
            ic.slot = bc.IC.missing_slot;
            ic.epoch = proto_epoch;
            ic.is_accessor = false;
            ic.is_transition = false;
            ic.fast_own_data = false;
            ic.fast_proto_data = false;
        }
    } else {
        if (ic.shape == null or isStaleProtoIC(ic, proto_epoch)) {
            ic.proto_shapes = @splat(null);
            ic.proto_idx = 0;
            ic.shape = sh;
            ic.holder = null;
            ic.holder_shape = null;
            ic.slot = me.slot;
            ic.epoch = 0;
            ic.is_accessor = false;
            ic.is_transition = false;
            ic.fast_own_data = true;
            ic.fast_proto_data = false;
        } else if (ic.shape != sh) {
            _ = addOwnPolySlot(ic, sh, me.slot);
        }
    }
}

inline fn hasProtoPoly(ic: *const bc.IC, sh: *const shape_mod.Shape) bool {
    const base = bc.IC.protoHashBase(sh);
    return ic.proto_shapes[base] == sh or ic.proto_shapes[base + 1] == sh;
}

inline fn insertProtoPoly(ic: *bc.IC, sh: *shape_mod.Shape) void {
    const base = bc.IC.protoHashBase(sh);
    if (ic.proto_shapes[base] == sh or ic.proto_shapes[base + 1] == sh) return;
    if (ic.proto_shapes[base] == null) {
        ic.proto_shapes[base] = sh;
    } else if (ic.proto_shapes[base + 1] == null) {
        ic.proto_shapes[base + 1] = sh;
    } else {
        ic.proto_shapes[base + (ic.proto_idx & 1)] = sh;
        ic.proto_idx +%= 1;
    }
}

pub fn callSetterSlot(vm: *Vm, ic: *bc.IC, slot_val: Value, receiver: Value, v: Value, strict: bool) Error!void {
    const a: *heap.Accessor = @fieldParentPtr("cell", slot_val.asCell());
    if (a.set.isUndefined()) {
        if (strict) return props.throwReadonly(vm, ic.key);
        return;
    }
    if (a.set.isObject()) {
        const so = a.set.asObject();
        if (so.class == .native and !so.flags.host_class) {
            _ = try interp_call.callNative(vm, so, receiver, &.{v});
            return;
        }
    }
    _ = try interp_call.call(vm, a.set, receiver, &.{v});
}

pub fn getField(vm: *Vm, ic: *bc.IC, v: Value) Error!Value {
    if (!v.isObject()) {
        if (!ic.key.isIndex()) {
            if (v.isString() and ic.key.eql(vm.k.length)) {
                ic.is_str_len = true;
                return Value.fromUsize(v.asString().len16);
            }
            const pp: ?*Object = if (v.isString()) vm.protos.string else if (v.isNumber()) vm.protos.number else if (v.isBool()) vm.protos.boolean else null;
            if (pp) |p| {
                const psh = p.shape;
                const me = vm.megaSlot(psh, ic.key.bits);
                if (me.shape == psh and me.key_bits == ic.key.bits) {
                    if (me.holder) |mh| {
                        if (me.epoch == vm.proto_epoch and mh.shape == me.holder_shape) {
                            const sv = mh.slots[me.slot & ~vm_mod.MegaICEntry.acc_flag];
                            return if ((me.slot & vm_mod.MegaICEntry.acc_flag) != 0) props.callGetter(vm, sv, v) else sv;
                        }
                    } else if (me.slot == bc.IC.missing_slot) {
                        if (me.epoch == vm.proto_epoch) return Value.undefined;
                    } else {
                        return p.slots[me.slot];
                    }
                }
                if (!psh.is_dict and !p.flags.lazy_fn) {
                    if (psh.find(ic.key)) |slot| {
                        const acc = psh.flagsAt(slot).accessor;
                        me.* = if (acc)
                            .{ .shape = psh, .key_bits = ic.key.bits, .holder = p, .holder_shape = psh, .slot = slot | vm_mod.MegaICEntry.acc_flag, .epoch = vm.proto_epoch }
                        else
                            .{ .shape = psh, .key_bits = ic.key.bits, .holder = null, .holder_shape = null, .slot = slot, .epoch = 0 };
                        const sv = p.slots[slot];
                        return if (acc) props.callGetter(vm, sv, v) else sv;
                    }
                    const is_lazy_key = ic.key.eql(vm.k.name) or ic.key.eql(vm.k.length) or ic.key.eql(vm.k.prototype);
                    var cur = psh.proto;
                    while (cur) |h| : (cur = h.shape.proto) {
                        if (h.flags.exotic or h.flags.lazy_fn) break;
                        if (h.class == .array and ic.key.eql(vm.k.length)) break;
                        const hs = h.shape;
                        if ((hs == vm.fn_root or h.class == .closure or h.class == .native) and is_lazy_key) break;
                        if (hs.find(ic.key)) |hslot| {
                            const acc = hs.flagsAt(hslot).accessor;
                            if (!hs.is_dict) me.* = .{ .shape = psh, .key_bits = ic.key.bits, .holder = h, .holder_shape = hs, .slot = hslot | (if (acc) vm_mod.MegaICEntry.acc_flag else 0), .epoch = vm.proto_epoch };
                            const sv = h.slots[hslot];
                            return if (acc) props.callGetter(vm, sv, v) else sv;
                        }
                    } else {
                        me.* = .{ .shape = psh, .key_bits = ic.key.bits, .holder = null, .holder_shape = null, .slot = bc.IC.missing_slot, .epoch = vm.proto_epoch };
                        return Value.undefined;
                    }
                }
            }
        }
        return props.getV(vm, v, ic.key);
    }
    const o = v.asObject();
    const sh = o.shape;
    if (sh == ic.shape) {
        if (ic.fast_own_data) return o.slots[ic.slot];
        if (ic.fast_proto_data and ic.epoch == vm.proto_epoch and ic.holder.?.shape == ic.holder_shape) return ic.holder.?.slots[ic.slot];
        if (ic.slot == bc.IC.missing_slot) {
            if (ic.epoch == vm.proto_epoch) return Value.undefined;
        } else if (if (ic.holder) |h| (h.shape == ic.holder_shape and ic.epoch == vm.proto_epoch) else true) {
            const sv = (ic.holder orelse o).slots[ic.slot];
            return if (ic.is_accessor) props.callGetter(vm, sv, v) else sv;
        }
    }
    inline for (0..bc.IC.own_poly_cap) |k| if (ic.own_shapes[k] == sh) {
        return o.slots[ic.own_slots[k]];
    };
    if (ic.holder) |h| {
        if (ic.epoch == vm.proto_epoch and h.shape == ic.holder_shape and ic.slot != bc.IC.missing_slot and hasProtoPoly(ic, sh)) {
            const sv = h.slots[ic.slot];
            return if (ic.is_accessor) props.callGetter(vm, sv, v) else sv;
        }
    } else if (ic.slot == bc.IC.missing_slot and ic.epoch == vm.proto_epoch and hasProtoPoly(ic, sh)) {
        return Value.undefined;
    }
    var exotic_ok = !o.flags.exotic or o.class == .typedarray or (o.class == .host_exotic and o.payload.hooks.get_named == null and !ic.key.eql(vm.k.length));
    if (!exotic_ok and o.class == .host_exotic and o.payload.hooks.named_null_deterministic and !ic.key.isIndex() and !ic.key.eql(vm.k.length)) {
        if (ic.key.isAtom()) {
            if (try o.payload.hooks.get_named.?(vm, o, try ic.key.atom().flat(vm))) |val| return val;
        }
        exotic_ok = true;
    }
    if (exotic_ok and !ic.key.isIndex()) {
        const me = vm.megaSlot(sh, ic.key.bits);
        if (me.shape == sh and me.key_bits == ic.key.bits) {
            if (me.holder) |mh| {
                if (me.epoch == vm.proto_epoch and mh.shape == me.holder_shape) {
                    fillFromMega(ic, sh, me, vm.proto_epoch);
                    const sv = mh.slots[me.slot & ~vm_mod.MegaICEntry.acc_flag];
                    return if ((me.slot & vm_mod.MegaICEntry.acc_flag) != 0) props.callGetter(vm, sv, v) else sv;
                }
            } else if (me.slot == bc.IC.missing_slot) {
                if (me.epoch == vm.proto_epoch) {
                    fillFromMega(ic, sh, me, vm.proto_epoch);
                    return Value.undefined;
                }
            } else {
                fillFromMega(ic, sh, me, vm.proto_epoch);
                return o.slots[me.slot];
            }
        }
        if (o.flags.lazy_fn) try props.touchLazy(vm, o, ic.key);
        const cur_sh = o.shape;
        const me_cur = if (cur_sh == sh) me else vm.megaSlot(cur_sh, ic.key.bits);
        const is_lazy_key = ic.key.eql(vm.k.name) or ic.key.eql(vm.k.length) or ic.key.eql(vm.k.prototype);
        const can_mega = exotic_ok and !(o.class == .array and ic.key.eql(vm.k.length)) and !(o.flags.lazy_fn and cur_sh == vm.fn_root and is_lazy_key);
        if (cur_sh.find(ic.key)) |slot| {
            const acc = cur_sh.flagsAt(slot).accessor;
            if (!cur_sh.is_dict) {
                if (!acc and can_mega) me_cur.* = .{ .shape = cur_sh, .key_bits = ic.key.bits, .holder = null, .holder_shape = null, .slot = slot, .epoch = 0 };
                if (!acc and ic.shape != null and !isStaleProtoIC(ic, vm.proto_epoch)) {
                    if (addOwnPolySlot(ic, cur_sh, slot) or ic.fast_own_data or can_mega) return o.slots[slot];
                }
                if (!ic.fast_own_data) {
                    ic.proto_shapes = @splat(null);
                    ic.proto_idx = 0;
                }
                ic.shape = cur_sh;
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
        const recv_may_be_lazy = is_lazy_key and (o.class == .closure or o.class == .native or cur_sh == vm.fn_root);
        if (!cur_sh.is_dict and !recv_may_be_lazy and !(o.class == .array and ic.key.eql(vm.k.length))) {
            var cur = cur_sh.proto;
            while (cur) |h| : (cur = h.shape.proto) {
                if (h.flags.exotic) break;
                if (h.flags.lazy_fn) try props.touchLazy(vm, h, ic.key);
                if (h.class == .array and ic.key.eql(vm.k.length)) break;
                const hs = h.shape;
                if ((hs == vm.fn_root or h.class == .closure or h.class == .native) and is_lazy_key) break;
                if (hs.find(ic.key)) |slot| {
                    const acc = hs.flagsAt(slot).accessor;
                    if (!hs.is_dict and can_mega) me_cur.* = .{ .shape = cur_sh, .key_bits = ic.key.bits, .holder = h, .holder_shape = hs, .slot = slot | (if (acc) vm_mod.MegaICEntry.acc_flag else 0), .epoch = vm.proto_epoch };
                    if (ic.fast_own_data and ic.shape != null and !acc) return h.slots[slot];
                    pushOwnPoly(ic, cur_sh);
                    if (ic.holder == h and ic.holder_shape == hs and ic.slot == slot and ic.epoch == vm.proto_epoch and ic.shape != null and ic.shape != cur_sh and !ic.fast_own_data) {
                        insertProtoPoly(ic, ic.shape.?);
                    } else if (ic.holder != h or ic.holder_shape != hs or ic.slot != slot or ic.epoch != vm.proto_epoch or ic.fast_own_data) {
                        ic.proto_shapes = @splat(null);
                        ic.proto_idx = 0;
                    }
                    ic.shape = cur_sh;
                    ic.holder = h;
                    ic.holder_shape = hs;
                    ic.slot = slot;
                    ic.epoch = vm.proto_epoch;
                    ic.is_accessor = acc;
                    ic.is_transition = false;
                    ic.fast_own_data = false;
                    ic.fast_proto_data = !acc;
                    if (acc) return props.callGetter(vm, h.slots[slot], v);
                    return h.slots[slot];
                }
            } else {
                if (can_mega) me_cur.* = .{ .shape = cur_sh, .key_bits = ic.key.bits, .holder = null, .holder_shape = null, .slot = bc.IC.missing_slot, .epoch = vm.proto_epoch };
                if (ic.fast_own_data and ic.shape != null) return Value.undefined;
                pushOwnPoly(ic, cur_sh);
                if (ic.slot == bc.IC.missing_slot and ic.holder == null and ic.epoch == vm.proto_epoch and ic.shape != null and ic.shape != cur_sh and !ic.fast_own_data) {
                    insertProtoPoly(ic, ic.shape.?);
                } else if (ic.slot != bc.IC.missing_slot or ic.holder != null or ic.epoch != vm.proto_epoch or ic.fast_own_data) {
                    ic.proto_shapes = @splat(null);
                    ic.proto_idx = 0;
                }
                ic.shape = cur_sh;
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
    inline for (0..bc.IC.own_poly_cap) |k| if (ic.own_shapes[k] == o.shape) {
        o.slots[ic.own_slots[k]] = v;
        return;
    };
    if (ic.is_accessor) if (ic.holder) |h| {
        if (ic.epoch == vm.proto_epoch and h.shape == ic.holder_shape and hasProtoPoly(ic, o.shape)) {
            return callSetterSlot(vm, ic, h.slots[ic.slot], t, v, strict);
        }
    };
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
                if (!sh.is_dict and !o.flags.is_proto) {
                    pushOwnPoly(ic, sh);
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
                if (h.flags.exotic or h.flags.lazy_fn) break;
                if (h.class == .array and ic.key.eql(vm.k.length)) break;
                const hs = h.shape;
                if (hs.find(ic.key)) |slot| {
                    if (hs.flagsAt(slot).accessor) {
                        if (ic.holder == h and ic.holder_shape == hs and ic.slot == slot and ic.epoch == vm.proto_epoch and ic.shape != null and ic.shape != sh and !ic.fast_own_data and !ic.is_transition) {
                            insertProtoPoly(ic, ic.shape.?);
                        } else if (ic.holder != h or ic.holder_shape != hs or ic.slot != slot or ic.epoch != vm.proto_epoch or ic.fast_own_data or ic.is_transition) {
                            ic.proto_shapes = @splat(null);
                            ic.proto_idx = 0;
                        }
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

pub fn putOnPrimitive(vm: *Vm, t: Value, key: PropKey, v: Value, strict: bool) Error!void {
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

const eic = @import("interp_elem.zig");
pub const getElem = eic.getElem;
pub const putElem = eic.putElem;

const gic = @import("interp_global.zig");
pub const throwTdzKey = gic.throwTdzKey;
pub const getGlobal = gic.getGlobal;
pub const getGlobalOrUndefined = gic.getGlobalOrUndefined;
pub const putGlobal = gic.putGlobal;
pub const initGlobalLex = gic.initGlobalLex;
pub const declareGlobalLex = gic.declareGlobalLex;
pub const declareGlobalVar = gic.declareGlobalVar;
pub const defineGlobalFn = gic.defineGlobalFn;
