//! [[GetOwnProperty]], [[DefineOwnProperty]] (ValidateAndApplyPropertyDescriptor),
//! [[OwnPropertyKeys]], array length, and the integrity levels' fast path.

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
const exotic = @import("props_exotic.zig");
const props = @import("props.zig");
const conv = @import("conv.zig");

/// A partial property descriptor; a null field is absent.
pub const Desc = struct {
    value: ?Value = null,
    get: ?Value = null,
    set: ?Value = null,
    writable: ?bool = null,
    enumerable: ?bool = null,
    configurable: ?bool = null,

    pub fn isAccessor(d: Desc) bool {
        return d.get != null or d.set != null;
    }
    pub fn isData(d: Desc) bool {
        return d.value != null or d.writable != null;
    }
};

/// A complete own property. For an accessor, get/set hold the functions or undefined.
pub const Own = struct {
    value: Value = Value.undefined,
    get: Value = Value.undefined,
    set: Value = Value.undefined,
    flags: PropFlags,
};

pub fn getOwn(vm: *Vm, o: *Object, key: PropKey) Error!?Own {
    if (o.flags.exotic) {
        if (try exotic.getOwn(vm, o, key)) |r| return r;
    }
    return ordinaryGetOwn(vm, o, key);
}

pub fn ordinaryGetOwn(vm: *Vm, o: *Object, key: PropKey) Error!?Own {
    if (key.isIndex()) {
        const i = key.index();
        if (i < o.elems_len and !o.elems[i].isHole()) {
            return .{ .value = o.elems[i], .flags = .{
                .writable = !o.flags.elems_frozen,
                .configurable = !(o.flags.elems_frozen or o.flags.elems_sealed),
            } };
        }
        if (!o.flags.has_sparse) return null;
    } else {
        if (o.flags.lazy_fn) try props.touchLazy(vm, o, key);
        if (o.class == .array and key.eql(vm.k.length)) {
            return .{ .value = Value.fromUsize(o.arr_len), .flags = .{
                .writable = !o.flags.length_readonly,
                .enumerable = false,
                .configurable = false,
            } };
        }
    }
    const s = o.shape.find(key) orelse return null;
    const f = o.shape.flagsAt(s);
    if (f.accessor) {
        const a: *heap.Accessor = @fieldParentPtr("cell", o.slots[s].asCell());
        return .{ .get = a.get, .set = a.set, .flags = f };
    }
    return .{ .value = o.slots[s], .flags = f };
}

/// Moves dense elements into the shape so each can carry its own attributes.
fn sparsify(vm: *Vm, o: *Object) Error!void {
    if (o.elems_len == 0) return;
    const n = o.elems_len;
    const flags = PropFlags{
        .writable = !o.flags.elems_frozen,
        .configurable = !(o.flags.elems_frozen or o.flags.elems_sealed),
    };
    o.elems_len = 0;
    o.flags.has_sparse = true;
    if (!o.shape.is_dict) o.shape = try shape_mod.toDict(vm, o.shape, o.shape.proto);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const v = o.elems[i];
        if (v.isHole()) continue;
        const slot = o.shape.count;
        if (slot >= o.slot_cap) try objmod.growSlots(vm, o, slot + 1);
        try shape_mod.dictAdd(vm, o.shape, PropKey.fromIndex(i), flags);
        o.slots[slot] = v;
    }
}

pub fn defineOwn(vm: *Vm, o: *Object, key: PropKey, d: Desc) Error!bool {
    if (o.flags.exotic) {
        if (try exotic.defineOwn(vm, o, key, d)) |r| return r;
    }
    if (o.flags.lazy_fn) try props.materialize(vm, o);
    if (o.class == .array) {
        if (key.eql(vm.k.length)) return arrayDefineLength(vm, o, d);
        if (key.isIndex() and key.index() >= o.arr_len and o.flags.length_readonly) return false;
    }
    return ordinaryDefine(vm, o, key, d);
}

pub fn ordinaryDefine(vm: *Vm, o: *Object, key: PropKey, d: Desc) Error!bool {
    const cur = try ordinaryGetOwn(vm, o, key) orelse {
        if (!o.flags.extensible) return false;
        if (d.isAccessor()) {
            const a = try vm.heap.newAccessor(d.get orelse Value.undefined, d.set orelse Value.undefined);
            try props.addProp(vm, o, key, Value.fromCell(&a.cell), .{
                .writable = false,
                .enumerable = d.enumerable orelse false,
                .configurable = d.configurable orelse false,
                .accessor = true,
            });
        } else {
            try props.addProp(vm, o, key, d.value orelse Value.undefined, .{
                .writable = d.writable orelse false,
                .enumerable = d.enumerable orelse false,
                .configurable = d.configurable orelse false,
            });
        }
        return true;
    };
    const cf = cur.flags;
    if (!cf.configurable) {
        if (d.configurable == true) return false;
        if (d.enumerable) |e| if (e != cf.enumerable) return false;
        if (d.isAccessor() and !cf.accessor) return false;
        if (d.isData() and cf.accessor) return false;
        if (cf.accessor) {
            if (d.get) |g| if (!g.same(cur.get)) return false;
            if (d.set) |s| if (!s.same(cur.set)) return false;
        } else if (!cf.writable) {
            if (d.writable == true) return false;
            if (d.value) |v| if (!conv.sameValue(vm, v, cur.value)) return false;
        }
    }
    var nf = cf;
    if (d.enumerable) |e| nf.enumerable = e;
    if (d.configurable) |c| nf.configurable = c;
    const to_accessor = d.isAccessor();
    const to_data = d.isData();
    if (to_accessor) {
        nf.accessor = true;
        nf.writable = false;
    } else if (to_data) {
        if (cf.accessor) nf.writable = false;
        nf.accessor = false;
        if (d.writable) |w| nf.writable = w;
    }

    // Dense element: stays dense only while its attributes stay the default ones.
    if (key.isIndex() and key.index() < o.elems_len and !o.elems[key.index()].isHole()) {
        if (@as(u8, @bitCast(nf)) == @as(u8, @bitCast(cf))) {
            if (d.value) |v| o.elems[key.index()] = v;
            return true;
        }
        try sparsify(vm, o);
    }
    const s = o.shape.find(key).?;
    if (@as(u8, @bitCast(nf)) != @as(u8, @bitCast(cf))) {
        if (!o.shape.is_dict) o.shape = try shape_mod.toDict(vm, o.shape, o.shape.proto);
        shape_mod.dictSetFlags(o.shape, s, nf);
    }
    if (nf.accessor) {
        const g = d.get orelse (if (cf.accessor) cur.get else Value.undefined);
        const st = d.set orelse (if (cf.accessor) cur.set else Value.undefined);
        const a = try vm.heap.newAccessor(g, st);
        o.slots[s] = Value.fromCell(&a.cell);
    } else if (d.value) |v| {
        o.slots[s] = v;
    } else if (cf.accessor) {
        o.slots[s] = Value.undefined;
    }
    return true;
}

fn arrayDefineLength(vm: *Vm, o: *Object, d: Desc) Error!bool {
    if (d.isAccessor() or d.configurable == true or d.enumerable == true) return false;
    var ok = true;
    if (d.value) |v| {
        const n = try conv.toNumber(vm, v);
        const len = try conv.toUint32(vm, v);
        if (@as(f64, @floatFromInt(len)) != n) return vm.throwError(.RangeError, "Invalid array length");
        if (len != o.arr_len) {
            if (o.flags.length_readonly) return false;
            ok = try setArrayLength(vm, o, len);
        }
    }
    if (d.writable) |w| {
        if (w and o.flags.length_readonly) return false;
        if (!w) o.flags.length_readonly = true;
    }
    return ok;
}

/// `arr.length = v` with the RangeError check.
pub fn setArrayLengthValue(vm: *Vm, o: *Object, val: Value) Error!bool {
    const n = try conv.toNumber(vm, val);
    const len = try conv.toUint32(vm, val);
    if (@as(f64, @floatFromInt(len)) != n) return vm.throwError(.RangeError, "Invalid array length");
    if (o.flags.length_readonly) return len == o.arr_len;
    return setArrayLength(vm, o, len);
}

/// Truncates or extends an array. False if a non-configurable element stopped it.
pub fn setArrayLength(vm: *Vm, o: *Object, len: u32) Error!bool {
    if (len >= o.arr_len) {
        o.arr_len = len;
        return true;
    }
    if (o.elems_len > len) {
        if (o.flags.elems_frozen or o.flags.elems_sealed) return false;
        o.elems_len = len;
    }
    var result = true;
    var final_len = len;
    if (o.flags.has_sparse) {
        // Highest first, so a non-configurable element keeps everything below it.
        var doomed: std.ArrayList(u32) = .empty;
        defer doomed.deinit(vm.gpa);
        for (o.shape.entries()) |e| {
            if (e.key.isIndex() and e.key.index() >= len) try doomed.append(vm.gpa, e.key.index());
        }
        std.mem.sort(u32, doomed.items, {}, std.sort.desc(u32));
        for (doomed.items) |i| {
            if (!try props.delete(vm, o, PropKey.fromIndex(i))) {
                final_len = i + 1;
                result = false;
                break;
            }
        }
    }
    o.arr_len = final_len;
    return result;
}

/// All own keys: indices ascending, then strings, then symbols, in insertion order.
/// Private names are never included. The caller frees the slice with vm.gpa.
pub fn ownKeys(vm: *Vm, o: *Object) Error![]PropKey {
    if (o.class == .proxy) return exotic.proxyOwnKeys(vm, o);
    if (o.flags.lazy_fn) try props.materialize(vm, o);
    var out: std.ArrayList(PropKey) = .empty;
    errdefer out.deinit(vm.gpa);
    if (o.flags.exotic) try exotic.ownKeysPrefix(vm, o, &out);
    var i: u32 = 0;
    while (i < o.elems_len) : (i += 1) {
        if (!o.elems[i].isHole()) try out.append(vm.gpa, PropKey.fromIndex(i));
    }
    const entries = o.shape.entries();
    if (o.flags.has_sparse) {
        for (entries) |e| {
            if (e.key.isIndex()) try out.append(vm.gpa, e.key);
        }
        std.mem.sort(PropKey, out.items, {}, struct {
            fn lt(_: void, a: PropKey, b: PropKey) bool {
                if (a.isIndex() and b.isIndex()) return a.index() < b.index();
                return a.isIndex() and !b.isIndex();
            }
        }.lt);
    }
    if (o.class == .array) try out.append(vm.gpa, vm.k.length);
    for (entries) |e| {
        if (e.key.isAtom()) try out.append(vm.gpa, e.key);
    }
    for (entries) |e| {
        if (e.key.isSymbol() and !e.key.symbol().is_private) try out.append(vm.gpa, e.key);
    }
    return out.toOwnedSlice(vm.gpa);
}

/// Object.seal/freeze for ordinary objects, without sparsifying elements.
pub fn setIntegrityFast(vm: *Vm, o: *Object, frozen: bool) Error!void {
    if (o.flags.lazy_fn) try props.materialize(vm, o);
    o.flags.extensible = false;
    if (o.elems_len != 0) {
        o.flags.elems_sealed = true;
        if (frozen) o.flags.elems_frozen = true;
    }
    if (o.class == .array and frozen) o.flags.length_readonly = true;
    const count = o.shape.count;
    if (count == 0) return;
    if (!o.shape.is_dict) o.shape = try shape_mod.toDict(vm, o.shape, o.shape.proto);
    var s: u32 = 0;
    while (s < count) : (s += 1) {
        const e = o.shape.table.entries.items[s];
        if (e.key.bits == 0 or e.key.isPrivate()) continue;
        var f = e.flags;
        f.configurable = false;
        if (frozen and !f.accessor) f.writable = false;
        shape_mod.dictSetFlags(o.shape, s, f);
    }
}
