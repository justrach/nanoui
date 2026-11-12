//! Array methods with callbacks, the flat family, and the ES2023 copying methods.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const u = @import("b_util.zig");
const Value = u.Value;
const PropKey = u.PropKey;
const Object = u.Object;
const objmod = @import("object.zig");
const props = @import("props.zig");
const conv = @import("conv.zig");
const ops = @import("ops.zig");
const calls = @import("interp_call.zig");
const jit = @import("jit.zig");
const jit_calls = @import("jit_calls.zig");
const arr = @import("b_array.zig");
const key = arr.key;
const sorter = @import("b_array_sort.zig");

fn needCallback(vm: *Vm, v: Value) Error!void {
    if (!v.isCallable()) return vm.throwError(.TypeError, "callback is not a function");
}

const CbRunner = struct {
    vm: *Vm,
    cb: Value,
    closure: ?*Object,
    native_fn: ?*Object = null,
    fast_jfn: ?jit.JitFn = null,
    fast_frame: ?*@import("frame.zig").Frame = null,
    fast_fp: ?*@import("bytecode.zig").FuncProto = null,
    fast_frame_idx: u32 = 0,
    coerced_this: Value,
    eff_this: Value,
    o_val: Value,
    saved_sp: [*]Value,

    inline fn init(vm: *Vm, cb_in: Value, this_arg: Value, o: *Object) Error!CbRunner {
        var cb = cb_in;
        var eff_this = this_arg;
        if (cb.isObject()) {
            var cur_o = cb.asObject();
            var d: u32 = 0;
            while (cur_o.class == .bound and cur_o.payload.bound.args.len == 0 and d < 8) : (d += 1) {
                eff_this = cur_o.payload.bound.this;
                cur_o = cur_o.payload.bound.target;
                cb = cur_o.value();
            }
        }
        const cl: ?*Object = if (cb.isObject() and cb.asObject().class == .closure) cb.asObject() else null;
        const nat: ?*Object = if (cb.isObject() and cb.asObject().class == .native and !cb.asObject().flags.host_class) cb.asObject() else null;
        var fast_jfn: ?jit.JitFn = null;
        var fast_frame: ?*@import("frame.zig").Frame = null;
        var fast_fp: ?*@import("bytecode.zig").FuncProto = null;
        var fast_idx: u32 = 0;
        var coerced_this = eff_this;
        if (cl) |callee| {
            vm.enterFromHost();
            try vm.checkNativeStack();
            const fp = callee.payload.fp;
            const limit = @intFromPtr(vm.stack.ptr) + vm.stack.len * @sizeOf(Value);
            const need_words = @as(usize, 12) + fp.nlocals + fp.max_stack + 64;
            if (@intFromPtr(vm.sp) + need_words * @sizeOf(Value) > limit or vm.frame_top >= vm_mod.max_frames) {
                return vm.throwError(.RangeError, "Maximum call stack size exceeded");
            }
            vm.depth += 1;
            if (!fp.is_class_ctor and (!fp.coerce_this or eff_this.isObject() or eff_this.isNullish())) {
                if (fp.coerce_this and !eff_this.isObject()) coerced_this = vm.global_obj.value();
                fast_jfn = if (comptime jit.enabled) (if (fp.jit_fn) |p| @ptrCast(@alignCast(p)) else jit.getOrCompile(vm, fp)) else null;
                if (fast_jfn != null) {
                    fast_idx = vm.frame_top;
                    const f = &vm.frames[fast_idx];
                    f.* = .{
                        .fp = fp,
                        .pc = fp.code.ptr,
                        .bp = vm.sp + 2,
                        .ret_sp = vm.sp,
                        .env = callee.env,
                        .func = callee,
                        .this = coerced_this,
                        .new_target = Value.undefined,
                        .args = vm.sp + 2,
                        .argc = 3,
                        .is_entry = false,
                        .is_construct = false,
                        .co = null,
                    };
                    fast_frame = f;
                    fast_fp = fp;
                }
            }
        }
        return .{
            .vm = vm,
            .cb = cb,
            .closure = cl,
            .native_fn = nat,
            .fast_jfn = fast_jfn,
            .fast_frame = fast_frame,
            .fast_fp = fast_fp,
            .fast_frame_idx = fast_idx,
            .coerced_this = coerced_this,
            .eff_this = eff_this,
            .o_val = o.value(),
            .saved_sp = vm.sp,
        };
    }

    inline fn deinit(r: *CbRunner) void {
        if (r.closure != null) {
            r.vm.sp = r.saved_sp;
            r.vm.depth -= 1;
        }
    }

    inline fn call3(r: *CbRunner, v: Value, i: usize) Error!Value {
        if (r.fast_jfn) |jfn| {
            const fp = r.fast_fp.?;
            const f = r.fast_frame.?;
            const base = r.saved_sp;
            const args_p = base + 2;
            base[0] = r.coerced_this;
            base[1] = r.cb;
            args_p[0] = v;
            args_p[1] = Value.fromUsize(i);
            args_p[2] = r.o_val;
            const bp = if (fp.needs_args) base + 5 else args_p;
            const filled: u32 = @min(@as(u32, 3), fp.nparams);
            if (fp.needs_args and filled > 0) @memcpy(bp[0..filled], args_p[0..filled]);
            if (filled < fp.nlocals) @memset(bp[filled..fp.nlocals], Value.undefined);
            r.vm.budget -= 1;
            if (r.vm.budget <= 0) try calls.interrupt(r.vm);
            f.pc = fp.code.ptr;
            f.bp = bp;
            f.env = r.closure.?.env;
            f.argc = 3;
            const sp_in = bp + fp.nlocals;
            r.vm.frame_top = r.fast_frame_idx + 1;
            r.vm.sp = sp_in;
            const res = jfn(r.vm, f, bp, sp_in);
            if (res.err != 0) {
                const handled = jit_calls.handleChildErr(r.vm, base, f, res.err);
                r.vm.sp = base;
                if (handled.err != 0) return jit.decodeErr(handled.err);
                return base[0];
            }
            r.vm.frame_top = r.fast_frame_idx;
            r.vm.sp = base;
            return .{ .bits = res.bits };
        }
        if (r.native_fn) |nat| return calls.callNative(r.vm, nat, r.eff_this, &.{ v, Value.fromUsize(i), r.o_val });
        if (r.closure) |cl| {
            const base = r.saved_sp;
            base[0] = r.eff_this;
            base[1] = r.cb;
            base[2] = v;
            base[3] = Value.fromUsize(i);
            base[4] = r.o_val;
            r.vm.sp = base + 5;
            const child_f = try calls.pushClosure(r.vm, cl, base + 2, 3, base, Value.undefined, r.eff_this, false);
            const res = jit_calls.invokeChildFrame(r.vm, base, child_f);
            r.vm.sp = base;
            if (res.err != 0) return jit.decodeErr(res.err);
            return base[0];
        }
        return calls.call(r.vm, r.cb, r.eff_this, &.{ v, Value.fromUsize(i), r.o_val });
    }

    inline fn call4(r: *CbRunner, a: Value, v: Value, i: usize) Error!Value {
        if (r.fast_jfn) |jfn| {
            const fp = r.fast_fp.?;
            const f = r.fast_frame.?;
            const base = r.saved_sp;
            const args_p = base + 2;
            base[0] = r.coerced_this;
            base[1] = r.cb;
            args_p[0] = a;
            args_p[1] = v;
            args_p[2] = Value.fromUsize(i);
            args_p[3] = r.o_val;
            const bp = if (fp.needs_args) base + 6 else args_p;
            const filled: u32 = @min(@as(u32, 4), fp.nparams);
            if (fp.needs_args and filled > 0) @memcpy(bp[0..filled], args_p[0..filled]);
            if (filled < fp.nlocals) @memset(bp[filled..fp.nlocals], Value.undefined);
            r.vm.budget -= 1;
            if (r.vm.budget <= 0) try calls.interrupt(r.vm);
            f.pc = fp.code.ptr;
            f.bp = bp;
            f.env = r.closure.?.env;
            f.argc = 4;
            const sp_in = bp + fp.nlocals;
            r.vm.frame_top = r.fast_frame_idx + 1;
            r.vm.sp = sp_in;
            const res = jfn(r.vm, f, bp, sp_in);
            if (res.err != 0) {
                const handled = jit_calls.handleChildErr(r.vm, base, f, res.err);
                r.vm.sp = base;
                if (handled.err != 0) return jit.decodeErr(handled.err);
                return base[0];
            }
            r.vm.frame_top = r.fast_frame_idx;
            r.vm.sp = base;
            return .{ .bits = res.bits };
        }
        if (r.native_fn) |nat| return calls.callNative(r.vm, nat, r.eff_this, &.{ a, v, Value.fromUsize(i), r.o_val });
        if (r.closure) |cl| {
            const base = r.saved_sp;
            base[0] = r.eff_this;
            base[1] = r.cb;
            base[2] = a;
            base[3] = v;
            base[4] = Value.fromUsize(i);
            base[5] = r.o_val;
            r.vm.sp = base + 6;
            const child_f = try calls.pushClosure(r.vm, cl, base + 2, 4, base, Value.undefined, r.eff_this, false);
            const res = jit_calls.invokeChildFrame(r.vm, base, child_f);
            r.vm.sp = base;
            if (res.err != 0) return jit.decodeErr(res.err);
            return base[0];
        }
        return calls.call(r.vm, r.cb, r.eff_this, &.{ a, v, Value.fromUsize(i), r.o_val });
    }
};

/// The element at i, if present.
inline fn elemIf(vm: *Vm, o: *Object, i: usize) Error!?Value {
    if (i < o.elems_len and !o.flags.exotic) {
        const v = o.elems[i];
        if (!v.isHole()) return v;
        if (arr.isPlain(o) and o.shape == vm.array_root and !vm.protos.array.flags.proto_dirty and !vm.protos.object.flags.proto_dirty) return null;
    }
    if (try props.has(vm, o, try key(vm, i))) return try props.get(vm, o, try key(vm, i));
    return null;
}

inline fn invoke(vm: *Vm, cb: Value, this_arg: Value, v: Value, i: usize, o: *Object) Error!Value {
    return calls.call(vm, cb, this_arg, &.{ v, Value.fromUsize(i), o.value() });
}

fn forEach(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const cb = u.arg(args, 0);
    try needCallback(vm, cb);
    var run = try CbRunner.init(vm, cb, u.arg(args, 1), o);
    defer run.deinit();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (try elemIf(vm, o, i)) |v| _ = try run.call3(v, i);
    }
    return Value.undefined;
}

fn map(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const cb = u.arg(args, 0);
    try needCallback(vm, cb);
    const r = try arr.speciesCreate(vm, o, n);
    var run = try CbRunner.init(vm, cb, u.arg(args, 1), o);
    defer run.deinit();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (try elemIf(vm, o, i)) |v| {
            const mapped = try run.call3(v, i);
            if (arr.isPlain(r) and i < r.elems_len) {
                r.elems[i] = mapped;
            } else {
                try props.defineData(vm, r, try key(vm, i), mapped, u.PropFlags.all);
            }
        }
    }
    return r.value();
}

fn filter(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const cb = u.arg(args, 0);
    try needCallback(vm, cb);
    const r = try arr.speciesCreate(vm, o, 0);
    var run = try CbRunner.init(vm, cb, u.arg(args, 1), o);
    defer run.deinit();
    var at: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (try elemIf(vm, o, i)) |v| {
            if (ops.truthy(try run.call3(v, i))) {
                if (arr.isPlain(r) and at == r.elems_len) {
                    if (at >= r.elems_cap) try objmod.growElems(vm, r, at + 1);
                    r.elems[at] = v;
                    r.elems_len = @intCast(at + 1);
                    r.arr_len = r.elems_len;
                } else {
                    try props.defineData(vm, r, try key(vm, at), v, u.PropFlags.all);
                }
                at += 1;
            }
        }
    }
    return r.value();
}

fn every(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const cb = u.arg(args, 0);
    try needCallback(vm, cb);
    var run = try CbRunner.init(vm, cb, u.arg(args, 1), o);
    defer run.deinit();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (try elemIf(vm, o, i)) |v| {
            if (!ops.truthy(try run.call3(v, i))) return Value.false;
        }
    }
    return Value.true;
}

fn some(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const cb = u.arg(args, 0);
    try needCallback(vm, cb);
    var run = try CbRunner.init(vm, cb, u.arg(args, 1), o);
    defer run.deinit();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (try elemIf(vm, o, i)) |v| {
            if (ops.truthy(try run.call3(v, i))) return Value.true;
        }
    }
    return Value.false;
}

fn reduceImpl(vm: *Vm, this: Value, args: []const Value, right: bool) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const cb = u.arg(args, 0);
    try needCallback(vm, cb);
    var run = try CbRunner.init(vm, cb, Value.undefined, o);
    defer run.deinit();
    var step: usize = 0;
    var acc: ?Value = if (args.len > 1) args[1] else null;
    while (step < n) : (step += 1) {
        const i = if (right) n - 1 - step else step;
        const v = (try elemIf(vm, o, i)) orelse continue;
        if (acc) |a| {
            acc = try run.call4(a, v, i);
        } else acc = v;
    }
    return acc orelse vm.throwError(.TypeError, "Reduce of empty array with no initial value");
}
fn reduce(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return reduceImpl(vm, this, args, false);
}
fn reduceRight(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return reduceImpl(vm, this, args, true);
}

const FindMode = enum { value, index };

fn findImpl(vm: *Vm, this: Value, args: []const Value, backward: bool, mode: FindMode) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const cb = u.arg(args, 0);
    try needCallback(vm, cb);
    var run = try CbRunner.init(vm, cb, u.arg(args, 1), o);
    defer run.deinit();
    var step: usize = 0;
    while (step < n) : (step += 1) {
        const i = if (backward) n - 1 - step else step;
        const v = if (i < o.elems_len and !o.flags.exotic and !o.elems[i].isHole())
            o.elems[i]
        else
            try props.get(vm, o, try key(vm, i));
        if (ops.truthy(try run.call3(v, i))) {
            return if (mode == .value) v else Value.fromUsize(i);
        }
    }
    return if (mode == .value) Value.undefined else Value.fromInt(-1);
}
fn find(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return findImpl(vm, this, args, false, .value);
}
fn findIndex(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return findImpl(vm, this, args, false, .index);
}
fn findLast(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return findImpl(vm, this, args, true, .value);
}
fn findLastIndex(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return findImpl(vm, this, args, true, .index);
}

fn flatten(vm: *Vm, target: *Object, at: *usize, src: *Object, depth: f64, mapper: Value, this_arg: Value) Error!void {
    try vm.checkNativeStack();
    const n = try conv.lengthOf(vm, src);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var v = (try elemIf(vm, src, i)) orelse continue;
        if (!mapper.isUndefined()) v = try invoke(vm, mapper, this_arg, v, i, src);
        if (depth > 0 and try arr.isArrayValue(vm, v)) {
            try flatten(vm, target, at, v.asObject(), depth - 1, Value.undefined, Value.undefined);
        } else {
            try props.defineData(vm, target, try key(vm, at.*), v, u.PropFlags.all);
            at.* += 1;
        }
    }
}

fn flat(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const depth = if (u.arg(args, 0).isUndefined()) 1 else try conv.toIntegerOrInf(vm, args[0]);
    const r = try arr.speciesCreate(vm, o, 0);
    var at: usize = 0;
    try flatten(vm, r, &at, o, depth, Value.undefined, Value.undefined);
    return r.value();
}

fn flatMap(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    try needCallback(vm, u.arg(args, 0));
    const r = try arr.speciesCreate(vm, o, 0);
    var at: usize = 0;
    try flatten(vm, r, &at, o, 1, u.arg(args, 0), u.arg(args, 1));
    return r.value();
}

fn fill(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const start = try u.relativeIndex(vm, u.arg(args, 1), n, 0);
    const end = try u.relativeIndex(vm, u.arg(args, 2), n, n);
    var i = start;
    while (i < end) : (i += 1) try props.put(vm, o, try key(vm, i), u.arg(args, 0));
    return o.value();
}

fn copyWithin(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    var to = try u.relativeIndex(vm, u.arg(args, 0), n, 0);
    var from = try u.relativeIndex(vm, u.arg(args, 1), n, 0);
    const end = try u.relativeIndex(vm, u.arg(args, 2), n, n);
    var count = @min(if (end > from) end - from else 0, n - to);
    const backward = from < to and to < from + count;
    if (backward) {
        from += count;
        to += count;
    }
    while (count > 0) : (count -= 1) {
        const f = if (backward) from - 1 else from;
        const t = if (backward) to - 1 else to;
        if (try props.has(vm, o, try key(vm, f))) {
            try props.put(vm, o, try key(vm, t), try props.get(vm, o, try key(vm, f)));
        } else if (!try props.delete(vm, o, try key(vm, t))) return vm.throwError(.TypeError, "Cannot delete property");
        if (backward) {
            from -= 1;
            to -= 1;
        } else {
            from += 1;
            to += 1;
        }
    }
    return o.value();
}

fn atFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n: f64 = @floatFromInt(try conv.lengthOf(vm, o));
    var i = try conv.toIntegerOrInf(vm, u.arg(args, 0));
    if (i < 0) i += n;
    if (i < 0 or i >= n) return Value.undefined;
    return props.get(vm, o, try key(vm, @intFromFloat(i)));
}

/// Copies an array-like with holes read through as undefined, for the copying methods.
fn copied(vm: *Vm, o: *Object) Error!*Object {
    const n = try conv.lengthOf(vm, o);
    const r = try objmod.newArray(vm, &.{});
    try objmod.growElems(vm, r, n);
    var i: usize = 0;
    while (i < n) : (i += 1) try objmod.arrayPush(vm, r, try props.get(vm, o, try key(vm, i)));
    return r;
}

fn toReversed(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const r = try copied(vm, try conv.toObject(vm, this));
    std.mem.reverse(Value, r.elems[0..r.elems_len]);
    return r.value();
}

fn toSorted(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const cmp = u.arg(args, 0);
    if (!cmp.isUndefined() and !cmp.isCallable()) return vm.throwError(.TypeError, "The comparison function must be either a function or undefined");
    const r = try copied(vm, try conv.toObject(vm, this));
    try sorter.sortValues(vm, r.elems[0..r.elems_len], cmp, false);
    return r.value();
}

fn toSpliced(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    const start = try u.relativeIndex(vm, u.arg(args, 0), n, 0);
    var skip: usize = 0;
    if (args.len == 1) {
        skip = n - start;
    } else if (args.len > 1) {
        const d = try conv.toIntegerOrInf(vm, args[1]);
        skip = @intFromFloat(@min(@max(d, 0), @as(f64, @floatFromInt(n - start))));
    }
    const r = try objmod.newArray(vm, &.{});
    var i: usize = 0;
    while (i < start) : (i += 1) try objmod.arrayPush(vm, r, try props.get(vm, o, try key(vm, i)));
    if (args.len > 2) {
        for (args[2..]) |v| try objmod.arrayPush(vm, r, v);
    }
    i = start + skip;
    while (i < n) : (i += 1) try objmod.arrayPush(vm, r, try props.get(vm, o, try key(vm, i)));
    return r.value();
}

fn withFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const n: f64 = @floatFromInt(try conv.lengthOf(vm, o));
    var i = try conv.toIntegerOrInf(vm, u.arg(args, 0));
    if (i < 0) i += n;
    if (i < 0 or i >= n) return vm.throwError(.RangeError, "Invalid index");
    const r = try copied(vm, o);
    r.elems[@intFromFloat(i)] = u.arg(args, 1);
    return r.value();
}

pub fn init(vm: *Vm, p: *Object) Error!void {
    try u.method(vm, p, "forEach", 1, forEach);
    try u.method(vm, p, "map", 1, map);
    try u.method(vm, p, "filter", 1, filter);
    try u.method(vm, p, "every", 1, every);
    try u.method(vm, p, "some", 1, some);
    try u.method(vm, p, "reduce", 1, reduce);
    try u.method(vm, p, "reduceRight", 1, reduceRight);
    try u.method(vm, p, "find", 1, find);
    try u.method(vm, p, "findIndex", 1, findIndex);
    try u.method(vm, p, "findLast", 1, findLast);
    try u.method(vm, p, "findLastIndex", 1, findLastIndex);
    try u.method(vm, p, "flat", 0, flat);
    try u.method(vm, p, "flatMap", 1, flatMap);
    try u.method(vm, p, "fill", 1, fill);
    try u.method(vm, p, "copyWithin", 2, copyWithin);
    try u.method(vm, p, "at", 1, atFn);
    try u.method(vm, p, "toReversed", 0, toReversed);
    try u.method(vm, p, "toSorted", 1, toSorted);
    try u.method(vm, p, "toSpliced", 2, toSpliced);
    try u.method(vm, p, "with", 2, withFn);
    try u.method(vm, p, "sort", 1, sorter.sort);
}
