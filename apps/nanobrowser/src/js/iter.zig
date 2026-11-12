//! Iteration: the iterator-protocol opcodes with a fast path for plain arrays, for-in
//! key collection, and the helpers built-ins use to walk any iterable.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const value = @import("value.zig");
const Value = value.Value;
const PropKey = value.PropKey;
const bc = @import("bytecode.zig");
const Op = bc.Op;
const fr = @import("frame.zig");
const Frame = fr.Frame;
const objmod = @import("object.zig");
const Object = objmod.Object;
const props = @import("props.zig");
const conv = @import("conv.zig");
const ops = @import("ops.zig");
const str = @import("string.zig");
const calls = @import("interp_call.zig");
const objectops = @import("interp_object.zig");
const coroutine = @import("coroutine.zig");

inline fn u16At(p: [*]const u8) u32 {
    return std.mem.readInt(u16, p[0..2], .little);
}
inline fn relAt(p: [*]const u8) isize {
    return std.mem.readInt(i32, p[0..4], .little);
}
inline fn jumpTo(pc: [*]const u8, rel: isize) [*]const u8 {
    return if (rel >= 0) pc + @as(usize, @intCast(rel)) else pc - @as(usize, @intCast(-rel));
}

/// Whether iterating this value is exactly walking its elements, nothing observable.
pub fn isFastArray(vm: *Vm, v: Value) Error!bool {
    if (!v.isObject()) return false;
    const a = v.asObject();
    if (a.class != .array or a.flags.has_sparse) return false;
    if (a.shape.proto != vm.protos.array) return false;
    if (!vm.protos.array.flags.proto_dirty and !vm.protos.array_iter.flags.proto_dirty and a.shape.count == 0) return true;
    const key = PropKey.fromSymbol(vm.sym.iterator);
    if (a.shape.count != 0 and a.shape.find(key) != null) return false;
    if (!vm.protos.array.flags.proto_dirty and !vm.protos.array_iter.flags.proto_dirty) return true;
    const m = try props.get(vm, vm.protos.array, key);
    if (!m.isObject() or m.asObject() != vm.protos.array_values) return false;
    const nx = try props.get(vm, vm.protos.array_iter, vm.k.next);
    return nx.isObject() and nx.asObject() == vm.protos.array_iter_next;
}

pub const Iter = struct { iter: Value, next: Value };

pub fn getIterator(vm: *Vm, v: Value) Error!Iter {
    const m = if (v.isNullish()) Value.undefined else try props.getV(vm, v, PropKey.fromSymbol(vm.sym.iterator));
    if (!m.isCallable()) return notIterable(vm, v);
    const it = try calls.call(vm, m, v, &.{});
    if (!it.isObject()) return vm.throwError(.TypeError, "Result of the Symbol.iterator method is not an object");
    return .{ .iter = it, .next = try props.get(vm, it.asObject(), vm.k.next) };
}

fn notIterable(vm: *Vm, v: Value) Error {
    var b: [96]u8 = undefined;
    const t = if (v.isUndefined()) "undefined" else if (v.isNull()) "null" else if (v.isObject()) "object" else conv.typeName(v);
    const m = std.fmt.bufPrint(&b, "{s} is not iterable", .{t}) catch "value is not iterable";
    return vm.throwError(.TypeError, m);
}

/// One protocol step: the value, or null when done.
pub fn step(vm: *Vm, it: Iter) Error!?Value {
    const r = try calls.call(vm, it.next, it.iter, &.{});
    if (!r.isObject()) return vm.throwError(.TypeError, "Iterator result is not an object");
    if (ops.truthy(try props.get(vm, r.asObject(), vm.k.done))) return null;
    return try props.get(vm, r.asObject(), vm.k.value);
}

/// Calls iterator.return, ignoring what it does; for abandoning on an exception.
pub fn closeQuiet(vm: *Vm, it: Value) Error!void {
    if (!it.isObject()) return;
    const saved = vm.exception;
    defer vm.exception = saved;
    const m = props.getV(vm, it, vm.k.@"return") catch |e| {
        if (e == error.Terminated) return e;
        return;
    };
    if (!m.isCallable()) return;
    _ = calls.call(vm, m, it, &.{}) catch |e| {
        if (e == error.Terminated) return e;
    };
}

/// IteratorClose on normal completion: a non-object result is an error.
pub fn close(vm: *Vm, it: Value) Error!void {
    if (!it.isObject()) return;
    const m = try props.getV(vm, it, vm.k.@"return");
    if (m.isNullish()) return;
    const r = try calls.call(vm, m, it, &.{});
    if (!r.isObject()) return vm.throwError(.TypeError, "Iterator result is not an object");
}

/// Calls cb for each value of any iterable, closing the iterator if cb fails.
pub fn forEach(vm: *Vm, iterable: Value, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Value) Error!void) Error!void {
    if (try isFastArray(vm, iterable)) {
        const a = iterable.asObject();
        var i: u32 = 0;
        while (i < a.arr_len) : (i += 1) {
            const v = if (i < a.elems_len and !a.elems[i].isHole()) a.elems[i] else try props.get(vm, a, PropKey.fromIndex(i));
            try cb(ctx, v);
        }
        return;
    }
    const it = try getIterator(vm, iterable);
    while (try step(vm, it)) |v| {
        cb(ctx, v) catch |e| {
            if (e == error.Thrown) try closeQuiet(vm, it.iter);
            return e;
        };
    }
}

/// Appends every value of an iterable to an engine-made array.
pub fn appendAll(vm: *Vm, arr: *Object, iterable: Value) Error!void {
    const Ctx = struct {
        vm: *Vm,
        arr: *Object,
        fn add(c: @This(), v: Value) Error!void {
            try objmod.arrayPush(c.vm, c.arr, v);
        }
    };
    try forEach(vm, iterable, Ctx{ .vm = vm, .arr = arr }, Ctx.add);
}

fn markDone(sp: [*]Value) void {
    (sp - 3)[0] = Value.undefined;
    (sp - 1)[0] = fr.dead_marker;
}

/// Advances [iter next marker]; null at the end (then marked done).
fn advance(vm: *Vm, sp: [*]Value) Error!?Value {
    const it = (sp - 3)[0];
    const nx = (sp - 2)[0];
    // Already finished: a pattern with more names than the array has values.
    if (it.isUndefined()) return null;
    if (nx.isInt()) {
        const a = it.asObject();
        const i: u32 = @intCast(nx.asInt());
        if (i >= a.arr_len) {
            markDone(sp);
            return null;
        }
        (sp - 2)[0] = Value.fromInt(@intCast(i + 1));
        if (i < a.elems_len and !a.elems[i].isHole()) return a.elems[i];
        return try props.get(vm, a, PropKey.fromIndex(i));
    }
    const v = step(vm, .{ .iter = it, .next = nx }) catch |e| {
        // A failing next() means the iterator is broken: it must not be closed.
        markDone(sp);
        return e;
    };
    if (v == null) markDone(sp);
    return v;
}

pub fn execIter(vm: *Vm, f: *Frame, op: Op) Error!void {
    const sp = vm.sp;
    const pc = f.pc;
    switch (op) {
        .iter_init => {
            const v = (sp - 1)[0];
            if (try isFastArray(vm, v)) {
                sp[0] = Value.fromInt(0);
            } else {
                const it = try getIterator(vm, v);
                (sp - 1)[0] = it.iter;
                sp[0] = it.next;
            }
            sp[1] = fr.iter_marker;
            vm.sp = sp + 2;
            f.pc = pc + 1;
        },
        .iter_next => {
            if (try advance(vm, sp)) |v| {
                sp[0] = v;
                vm.sp = sp + 1;
                f.pc = pc + 5;
            } else {
                f.pc = jumpTo(pc + 5, relAt(pc + 1));
            }
        },
        .iter_step => {
            sp[0] = (try advance(vm, sp)) orelse Value.undefined;
            vm.sp = sp + 1;
            f.pc = pc + 1;
        },
        .iter_rest => {
            const arr = try objmod.newArray(vm, &.{});
            while (try advance(vm, sp)) |v| try objmod.arrayPush(vm, arr, v);
            sp[0] = arr.value();
            vm.sp = sp + 1;
            f.pc = pc + 1;
        },
        .iter_close => {
            const alive = (sp - 1)[0].same(fr.iter_marker);
            const it = (sp - 3)[0];
            const fast = (sp - 2)[0].isInt();
            (sp - 1)[0] = fr.dead_marker;
            if (alive and !fast) try close(vm, it);
            vm.sp = sp - 3;
            f.pc = pc + 1;
        },
        .iter_drop => {
            vm.sp = sp - 3;
            f.pc = pc + 1;
        },
        .async_iter_init => {
            const v = (sp - 1)[0];
            const it = try getAsyncIterator(vm, v);
            (sp - 1)[0] = it.iter;
            sp[0] = it.next;
            sp[1] = fr.async_iter_marker;
            vm.sp = sp + 2;
            f.pc = pc + 1;
        },
        .async_iter_call => {
            sp[0] = try calls.call(vm, (sp - 2)[0], (sp - 3)[0], &.{});
            vm.sp = sp + 1;
            f.pc = pc + 1;
        },
        .iter_result => {
            const r = (sp - 1)[0];
            if (!r.isObject()) return vm.throwError(.TypeError, "Iterator result is not an object");
            if (ops.truthy(try props.get(vm, r.asObject(), vm.k.done))) {
                (sp - 2)[0] = fr.dead_marker;
                vm.sp = sp - 1;
                f.pc = jumpTo(pc + 5, relAt(pc + 1));
            } else {
                (sp - 1)[0] = try props.get(vm, r.asObject(), vm.k.value);
                f.pc = pc + 5;
            }
        },
        .async_iter_close => {
            const it = (sp - 3)[0];
            const alive = (sp - 1)[0].same(fr.async_iter_marker);
            (sp - 1)[0] = fr.dead_marker;
            var r = Value.undefined;
            if (alive) {
                const m = try props.getV(vm, it, vm.k.@"return");
                if (!m.isNullish()) r = try calls.call(vm, m, it, &.{});
            }
            (sp - 3)[0] = r;
            vm.sp = sp - 2;
            f.pc = pc + 1;
        },
        .for_in_start => {
            const v = (sp - 1)[0];
            if (v.isNullish()) {
                (sp - 1)[0] = Value.undefined;
                sp[0] = Value.undefined;
            } else if (v.isObject()) {
                const o = v.asObject();
                if (o.shape.all_plain_str and !o.flags.exotic and !o.flags.lazy_fn and o.elems_len == 0 and o.class == .object and
                    (o.shape.proto == null or (o.shape.proto == vm.protos.object and !vm.protos.object.flags.proto_dirty)))
                {
                    sp[0] = Value.fromCell(&o.shape.cell);
                } else {
                    (sp - 1)[0] = try forInKeys(vm, v);
                    sp[0] = Value.undefined;
                }
            } else {
                (sp - 1)[0] = try forInKeys(vm, v);
                sp[0] = Value.undefined;
            }
            vm.sp = sp + 1;
            f.pc = pc + 1;
        },
        .for_in_next => {
            const keys_slot = u16At(pc + 1);
            const kv = f.bp[keys_slot];
            if (kv.isUndefined()) {
                f.pc = jumpTo(pc + 9, relAt(pc + 5));
                return;
            }
            const sh_val = f.bp[keys_slot + 1];
            const slot = u16At(pc + 3);
            var i: u32 = @intCast(f.bp[slot].asInt());
            if (sh_val.isInternal()) {
                const sh: *@import("shape.zig").Shape = @fieldParentPtr("cell", sh_val.asCell());
                const o = kv.asObject();
                if (o.shape == sh and o.elems_len == 0) {
                    if (i >= sh.count) {
                        f.pc = jumpTo(pc + 9, relAt(pc + 5));
                        return;
                    }
                    f.bp[slot] = Value.fromInt(@intCast(i + 1));
                    sp[0] = Value.fromString(sh.table.entries.items[i].key.atom());
                    vm.sp = sp + 1;
                    f.pc = pc + 9;
                    return;
                }
                const entries = sh.entries();
                while (i < entries.len) {
                    const pk = entries[i].key;
                    i += 1;
                    if (try stillThere(vm, o, pk)) {
                        f.bp[slot] = Value.fromInt(@intCast(i));
                        sp[0] = Value.fromString(pk.atom());
                        vm.sp = sp + 1;
                        f.pc = pc + 9;
                        return;
                    }
                }
                f.pc = jumpTo(pc + 9, relAt(pc + 5));
                return;
            }
            const keys = kv.asObject();
            const obj = keys.elems[0];
            const o = obj.asObject();
            const fast_keep = !o.flags.exotic and !o.shape.is_dict and o.elems_len == 0 and
                (o.shape.proto == null or (o.shape.proto == vm.protos.object and !vm.protos.object.flags.proto_dirty));
            while (true) {
                i += 1;
                if (i >= keys.elems_len) {
                    f.pc = jumpTo(pc + 9, relAt(pc + 5));
                    return;
                }
                const k = keys.elems[i];
                // A key deleted during the loop is skipped.
                if (fast_keep or try stillThere(vm, o, try str.toKey(vm, k.asString()))) {
                    f.bp[slot] = Value.fromInt(@intCast(i));
                    sp[0] = k;
                    vm.sp = sp + 1;
                    f.pc = pc + 9;
                    return;
                }
            }
        },
        .delegate_get_iter => {
            const v = (sp - 1)[0];
            const it = if (pc[1] != 0) try getAsyncIterator(vm, v) else try getIterator(vm, v);
            (sp - 1)[0] = it.iter;
            sp[0] = it.next;
            vm.sp = sp + 1;
            f.pc = pc + 2;
        },
        .delegate_call => {
            const mode = f.bp[u16At(pc + 1)].asInt();
            const it = (sp - 3)[0];
            const nx = (sp - 2)[0];
            const recv = (sp - 1)[0];
            const args = [1]Value{recv};
            f.pc = pc + 7;
            switch (mode) {
                0 => (sp - 1)[0] = try calls.call(vm, nx, it, &args),
                1 => {
                    const m = try props.getV(vm, it, vm.k.throw);
                    if (m.isNullish()) {
                        try closeQuiet(vm, it);
                        return vm.throwError(.TypeError, "The iterator does not provide a 'throw' method");
                    }
                    (sp - 1)[0] = try calls.call(vm, m, it, &args);
                },
                else => {
                    const m = try props.getV(vm, it, vm.k.@"return");
                    if (m.isNullish()) {
                        f.pc = jumpTo(pc + 7, relAt(pc + 3));
                        return;
                    }
                    (sp - 1)[0] = try calls.call(vm, m, it, &args);
                },
            }
        },
        .delegate_done => {
            const r = (sp - 1)[0];
            if (!r.isObject()) return vm.throwError(.TypeError, "Iterator result is not an object");
            if (ops.truthy(try props.get(vm, r.asObject(), vm.k.done))) {
                (sp - 1)[0] = try props.get(vm, r.asObject(), vm.k.value);
                f.pc = jumpTo(pc + 5, relAt(pc + 1));
            } else {
                f.pc = pc + 5;
            }
        },
        .resume_next => {
            const mode = (sp - 1)[0].asInt();
            vm.sp = sp - 1;
            switch (mode) {
                0 => f.pc = jumpTo(pc + 5, relAt(pc + 1)),
                1 => {
                    vm.exception = (sp - 2)[0];
                    vm.sp = sp - 2;
                    return error.Thrown;
                },
                else => f.pc = pc + 5,
            }
        },
        .resume_throw => {
            const mode = (sp - 1)[0].asInt();
            vm.sp = sp - 1;
            if (mode == 1) {
                vm.exception = (sp - 2)[0];
                vm.sp = sp - 2;
                return error.Thrown;
            }
            f.pc = pc + 1;
        },
        .async_start => {
            try coroutine.asyncStart(vm, f);
            f.pc = pc + 1;
        },
        else => return objectops.exec(vm, f, op),
    }
}

pub fn getAsyncIterator(vm: *Vm, v: Value) Error!Iter {
    const m = if (v.isNullish()) Value.undefined else try props.getV(vm, v, PropKey.fromSymbol(vm.sym.asyncIterator));
    if (m.isNullish()) {
        const sync = try getIterator(vm, v);
        return coroutine.asyncFromSync(vm, sync);
    }
    if (!m.isCallable()) return notIterable(vm, v);
    const it = try calls.call(vm, m, v, &.{});
    if (!it.isObject()) return vm.throwError(.TypeError, "Result of the Symbol.asyncIterator method is not an object");
    return .{ .iter = it, .next = try props.get(vm, it.asObject(), vm.k.next) };
}

fn stillThere(vm: *Vm, obj: *Object, key: PropKey) Error!bool {
    var o: ?*Object = obj;
    while (o) |cur| : (o = try props.getProto(vm, cur)) {
        if (try props.getOwn(vm, cur, key) != null) return true;
    }
    return false;
}

/// The keys for-in visits: an array whose first element is the object itself.
fn forInKeys(vm: *Vm, v: Value) Error!Value {
    const out = try objmod.newArray(vm, &.{});
    if (v.isNullish()) {
        try objmod.arrayPush(vm, out, try emptyHolder(vm));
        return out.value();
    }
    if (v.isObject()) {
        const obj = v.asObject();
        if (!obj.flags.exotic and !obj.flags.lazy_fn and !obj.shape.is_dict and obj.elems_len == 0 and obj.class == .object and
            (obj.shape.proto == null or (obj.shape.proto == vm.protos.object and !vm.protos.object.flags.proto_dirty)))
        {
            const entries = obj.shape.entries();
            try objmod.growElems(vm, out, entries.len + 1);
            out.elems[0] = obj.value();
            out.elems_len = 1;
            out.arr_len = 1;
            for (entries) |e| {
                if (e.key.isSymbol() or !e.flags.enumerable) continue;
                const kv = try str.keyToValue(vm, e.key);
                out.elems[out.elems_len] = kv;
                out.elems_len += 1;
                out.arr_len += 1;
            }
            return out.value();
        }
    }
    const obj = try conv.toObject(vm, v);
    try objmod.arrayPush(vm, out, obj.value());
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(vm.gpa);
    var o: ?*Object = obj;
    while (o) |cur| : (o = try props.getProto(vm, cur)) {
        const keys = try props.ownKeys(vm, cur);
        defer vm.gpa.free(keys);
        const is_first = cur == obj;
        for (keys) |k| {
            if (k.isSymbol()) continue;
            if (!is_first or cur.shape.proto != null) {
                const gop = try seen.getOrPut(vm.gpa, k.bits);
                if (gop.found_existing) continue;
            }
            const own = try props.getOwn(vm, cur, k) orelse continue;
            if (!own.flags.enumerable) continue;
            try objmod.arrayPush(vm, out, try str.keyToValue(vm, k));
        }
    }
    return out.value();
}

fn emptyHolder(vm: *Vm) Error!Value {
    return (try objmod.newPlain(vm)).value();
}
