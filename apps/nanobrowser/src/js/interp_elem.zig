//! Slow paths of computed element access (`obj[key]`, `obj[key] = val`), sharing
//! `vm.mega_ic` with named property inline caches for non-index string/symbol keys.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const value = @import("value.zig");
const Value = value.Value;
const PropKey = value.PropKey;
const bc = @import("bytecode.zig");
const objmod = @import("object.zig");
const props = @import("props.zig");
const conv = @import("conv.zig");
const str = @import("string.zig");
const typed = @import("b_typed.zig");
const ic_mod = @import("interp_ic.zig");

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
            if (o.class == .host_exotic) {
                if (o.payload.hooks.get_index) |gi| {
                    if (try gi(vm, o, i)) |v| return v;
                    if (!o.flags.has_sparse and o.shape.count == 0 and !vm.protos.object.flags.proto_dirty and (o.shape.proto == null or !o.shape.proto.?.flags.proto_dirty)) return Value.undefined;
                }
            }
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
        if (k.isString() or k.isSymbol()) {
            const key = if (k.isString()) blk: {
                const s = k.asString();
                if (s.key.bits != 0) break :blk s.key;
                if (try str.findExistingKey(vm, s)) |ek| break :blk ek;
                if (s.byte_len <= 64) break :blk try str.toKey(vm, s);
                if (ic_mod.noExoticOnChain(o)) return Value.undefined;
                break :blk try str.toKey(vm, s);
            } else PropKey.fromSymbol(k.asSymbol());
            if (!o.flags.exotic and !o.flags.lazy_fn and !key.isIndex()) {
                const me = vm.megaSlot(o.shape, key.bits);
                if (me.shape == o.shape and me.key_bits == key.bits) {
                    if (me.holder) |mh| {
                        if (me.epoch == vm.proto_epoch and mh.shape == me.holder_shape) {
                            const sv = mh.slots[me.slot & ~vm_mod.MegaICEntry.acc_flag];
                            return if ((me.slot & vm_mod.MegaICEntry.acc_flag) != 0) props.callGetter(vm, sv, t) else sv;
                        }
                    } else if (me.slot == bc.IC.missing_slot) {
                        if (me.epoch == vm.proto_epoch) return Value.undefined;
                    } else {
                        return o.slots[me.slot];
                    }
                }
                if (o.shape.find(key)) |slot| {
                    if (!o.shape.flagsAt(slot).accessor) {
                        if (!o.shape.is_dict) me.* = .{ .shape = o.shape, .key_bits = key.bits, .holder = null, .holder_shape = null, .slot = slot, .epoch = 0 };
                        return o.slots[slot];
                    }
                    return props.callGetter(vm, o.slots[slot], t);
                }
                if (o.class == .array and key.eql(vm.k.length)) return Value.fromUsize(o.arr_len);
                const p = o.shape.proto orelse {
                    if (!o.shape.is_dict) me.* = .{ .shape = o.shape, .key_bits = key.bits, .holder = null, .holder_shape = null, .slot = bc.IC.missing_slot, .epoch = vm.proto_epoch };
                    return Value.undefined;
                };
                const is_lazy_key = key.eql(vm.k.name) or key.eql(vm.k.length) or key.eql(vm.k.prototype);
                const recv_lazy = is_lazy_key and (o.class == .closure or o.class == .native or o.shape == vm.fn_root);
                if (!o.shape.is_dict and !recv_lazy) {
                    var cur: ?*objmod.Object = p;
                    while (cur) |h| : (cur = h.shape.proto) {
                        if (h.flags.exotic or h.flags.lazy_fn) break;
                        if (h.class == .array and key.eql(vm.k.length)) break;
                        if (is_lazy_key and (h.class == .closure or h.class == .native or h.shape == vm.fn_root)) break;
                        if (h.shape.find(key)) |pslot| {
                            if (!h.shape.is_dict) {
                                const acc: u32 = if (h.shape.flagsAt(pslot).accessor) vm_mod.MegaICEntry.acc_flag else 0;
                                me.* = .{ .shape = o.shape, .key_bits = key.bits, .holder = h, .holder_shape = h.shape, .slot = pslot | acc, .epoch = vm.proto_epoch };
                            }
                            return if (h.shape.flagsAt(pslot).accessor) props.callGetter(vm, h.slots[pslot], t) else h.slots[pslot];
                        }
                    } else {
                        me.* = .{ .shape = o.shape, .key_bits = key.bits, .holder = null, .holder_shape = null, .slot = bc.IC.missing_slot, .epoch = vm.proto_epoch };
                        return Value.undefined;
                    }
                }
                return props.getR(vm, p, key, t);
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
        if (k.isString() or k.isSymbol()) {
            const key = if (k.isString()) (if (k.asString().key.bits != 0) k.asString().key else try str.toKey(vm, k.asString())) else PropKey.fromSymbol(k.asSymbol());
            if (!o.flags.exotic and !o.flags.lazy_fn and !key.isIndex()) {
                if (o.shape.find(key)) |slot| {
                    const fl = o.shape.flagsAt(slot);
                    if (fl.writable and !fl.accessor) {
                        o.slots[slot] = v;
                        return;
                    }
                } else if (o.flags.extensible and !o.flags.is_proto and o.class == .object and
                    (o.shape.proto == null or (o.shape.proto == vm.protos.object and !vm.protos.object.flags.proto_dirty and vm.protos.object.shape.find(key) == null)))
                {
                    return props.addProp(vm, o, key, v, .all);
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
        return ic_mod.putOnPrimitive(vm, t, key, v, strict);
    }
    const key = try conv.toPropKey(vm, k);
    if (!t.isObject()) return ic_mod.putOnPrimitive(vm, t, key, v, strict);
    if (!try props.setR(vm, t.asObject(), key, v, t)) {
        if (strict) return props.throwReadonly(vm, key);
    }
}
