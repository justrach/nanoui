//! Call, constructor, accessor, closure/environment allocation, and slow-op
//! C-ABI helpers invoked by Baseline JIT ARM64 code.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const value = @import("value.zig");
const Value = value.Value;
const fr = @import("frame.zig");
const Frame = fr.Frame;
const heap = @import("heap.zig");
const objmod = @import("object.zig");
const Object = objmod.Object;
const calls = @import("interp_call.zig");
const slow = @import("interp_slow.zig");
const interp = @import("interp.zig");
const iter = @import("iter.zig");
const api = @import("vm_api.zig");
const b_fn = @import("b_function.zig");
const objectops = @import("interp_object.zig");
const jit = @import("jit.zig");
const JitFn = jit.JitFn;
const JitResult = jit.JitResult;

noinline fn handleChildErr(vm: *Vm, caller_sp: [*]Value, child_f: *Frame, err_code: u64) JitResult {
    @branchHint(.cold);
    var err = jit.decodeErr(err_code);
    if (err == error.OutOfMemory) {
        api.throwOutOfMemory(vm);
        err = error.Thrown;
    }
    if (err == error.Thrown) {
        const base = child_f.bp + child_f.fp.nlocals;
        var s = vm.sp;
        while (@intFromPtr(s) > @intFromPtr(base)) {
            s -= 1;
            const v = s[0];
            if (!v.isInternal()) continue;
            if (fr.isCatchMarker(v)) {
                const saved = (s - 1)[0];
                child_f.env = if (saved.isUndefined()) null else @fieldParentPtr("cell", saved.asCell());
                child_f.pc = child_f.fp.code.ptr + fr.catchOffset(v);
                (s - 1)[0] = vm.exception;
                vm.exception = Value.undefined;
                vm.sp = s;
                child_f.is_entry = true;
                const r = interp.run(vm) catch |e| return jit.errRes(vm, caller_sp, e);
                const ret_sp = vm.sp;
                ret_sp[0] = r;
                return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
            }
            if (v.same(fr.iter_marker) or v.same(fr.async_iter_marker)) {
                vm.sp = s + 1;
                iter.closeQuiet(vm, (s - 2)[0]) catch |e| {
                    if (e == error.Terminated) err = e;
                };
                if (err != error.Thrown) break;
            }
        }
    }
    vm.frame_top -= 1;
    return jit.errRes(vm, caller_sp, err);
}

pub inline fn invokeChildFrame(vm: *Vm, caller_sp: [*]Value, child_f: *Frame) JitResult {
    if ((vm.frame_top & 15) == 0) {
        vm.checkNativeStack() catch |e| {
            vm.frame_top -= 1;
            return jit.errRes(vm, caller_sp, e);
        };
    }
    const jfn_opt: ?JitFn = if (comptime jit.enabled) (if (child_f.fp.jit_fn) |p| @ptrCast(@alignCast(p)) else jit.getOrCompile(vm, child_f.fp)) else null;
    if (jfn_opt) |jfn| {
        const res = jfn(vm, child_f, child_f.bp, vm.sp);
        if (res.err != 0) return handleChildErr(vm, caller_sp, child_f, res.err);
        var r = Value{ .bits = res.bits };
        if (child_f.is_construct and !r.isObject()) r = child_f.this;
        const ret_sp = child_f.ret_sp;
        vm.frame_top -= 1;
        ret_sp[0] = r;
        return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
    }
    child_f.is_entry = true;
    const r = interp.run(vm) catch |e| return jit.errRes(vm, caller_sp, e);
    const ret_sp = vm.sp;
    ret_sp[0] = r;
    return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
}

inline fn pushAndInvokeClosure(vm: *Vm, caller_sp: [*]Value, callee: *Object, args: [*]Value, argc: u32, ret_sp: [*]Value, this: Value) JitResult {
    const child_f = calls.pushClosure(vm, callee, args, argc, ret_sp, Value.undefined, this, false) catch |e| return jit.errRes(vm, caller_sp, e);
    return invokeChildFrame(vm, caller_sp, child_f);
}

/// Theorem 37 (`NanoUI.Speedometer3Perf.single_tier_up_check_per_call`):
/// Executes an entry frame directly via JIT when compiled, falling back to `interp.run`.
pub fn runEntry(vm: *Vm) Error!Value {
    const f = &vm.frames[vm.frame_top - 1];
    if (comptime jit.enabled) {
        vm.checkNativeStack() catch |e| {
            vm.frame_top -= 1;
            return e;
        };
        const res = invokeChildFrame(vm, f.ret_sp, f);
        if (res.err != 0) return jit.decodeErr(res.err);
        vm.sp = f.ret_sp;
        return f.ret_sp[0];
    }
    return interp.run(vm);
}

pub fn jitCallGetter(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, slot_bits: u64) callconv(.c) JitResult {
    const slot_val = Value{ .bits = slot_bits };
    const a: *heap.Accessor = @fieldParentPtr("cell", slot_val.asCell());
    if (a.get.isUndefined()) return .{ .bits = Value.undefined.bits, .err = 0 };
    const recv = (sp - 1)[0];
    if (a.get.isObject()) {
        const go = a.get.asObject();
        if (go.class == .closure) {
            f.pc = pc + 5;
            vm.sp = sp;
            const child_f = calls.pushClosure(vm, go, sp, 0, sp, Value.undefined, recv, false) catch |e| return jit.errRes(vm, sp, e);
            const res = invokeChildFrame(vm, sp, child_f);
            if (res.err != 0) return res;
            vm.sp = sp;
            return .{ .bits = sp[0].bits, .err = 0 };
        }
        if (go.class == .native and !go.flags.host_class) {
            f.pc = pc;
            vm.sp = sp;
            const r = calls.callNative(vm, go, recv, &.{}) catch |e| return jit.errRes(vm, sp, e);
            return .{ .bits = r.bits, .err = 0 };
        }
    }
    f.pc = pc;
    vm.sp = sp;
    const r = calls.call(vm, a.get, recv, &.{}) catch |e| return jit.errRes(vm, sp, e);
    return .{ .bits = r.bits, .err = 0 };
}

noinline fn jitCallNonClosure(vm: *Vm, sp: [*]Value, argc: u32, ret_sp: [*]Value, callee: Value) JitResult {
    if (callee.isObject()) {
        const co = callee.asObject();
        if (co.class == .bound) {
            const b = co.payload.bound;
            if (b.target.class == .closure) {
                if (b.args.len == 0) {
                    return pushAndInvokeClosure(vm, sp, b.target, sp - argc, argc, ret_sp, b.this);
                }
                if (b.args.len + argc <= 64) {
                    const base = sp - argc;
                    const blen: u32 = @intCast(b.args.len);
                    std.mem.copyBackwards(Value, (base + blen)[0..argc], base[0..argc]);
                    @memcpy(base[0..blen], b.args);
                    return pushAndInvokeClosure(vm, sp, b.target, base, blen + argc, ret_sp, b.this);
                }
            }
        } else if (co.class == .native) {
            const nf = co.payload.native.func;
            if (nf == &b_fn.fnCall) {
                const target = ret_sp[0];
                if (target.isObject()) {
                    const to = target.asObject();
                    const sub_this = if (argc > 0) (sp - argc)[0] else Value.undefined;
                    const sub_args = if (argc > 0) sp - argc + 1 else sp;
                    const sub_argc = if (argc > 0) argc - 1 else 0;
                    if (to.class == .closure) {
                        return pushAndInvokeClosure(vm, sp, to, sub_args, sub_argc, ret_sp, sub_this);
                    }
                    if (to.class == .bound and to.payload.bound.args.len == 0 and to.payload.bound.target.class == .closure) {
                        return pushAndInvokeClosure(vm, sp, to.payload.bound.target, sub_args, sub_argc, ret_sp, to.payload.bound.this);
                    }
                }
            } else if (nf == &b_fn.fnApply) {
                const target = ret_sp[0];
                if (target.isObject()) {
                    const to = target.asObject();
                    var closure_target: ?*Object = null;
                    var sub_this = if (argc > 0) (sp - argc)[0] else Value.undefined;
                    if (to.class == .closure) {
                        closure_target = to;
                    } else if (to.class == .bound and to.payload.bound.args.len == 0 and to.payload.bound.target.class == .closure) {
                        closure_target = to.payload.bound.target;
                        sub_this = to.payload.bound.this;
                    }
                    if (closure_target) |ct| {
                        const arr_val = if (argc > 1) (sp - argc + 1)[0] else Value.undefined;
                        if (arr_val.isNullish()) {
                            return pushAndInvokeClosure(vm, sp, ct, sp, 0, ret_sp, sub_this);
                        }
                        if (arr_val.isObject()) {
                            const ao = arr_val.asObject();
                            const n = ao.elems_len;
                            const is_fast_args = ao.class == .arguments and (ao.shape == vm.args_strict_shape or ao.shape == vm.args_sloppy_shape) and ao.slots[0].bits == Value.fromUsize(n).bits;
                            if (!ao.flags.exotic and !ao.flags.has_sparse and ((ao.class == .array and n == ao.arr_len) or is_fast_args) and n <= 64) {
                                var has_hole = false;
                                for (ao.elems[0..n]) |el| if (el.isHole()) {
                                    has_hole = true;
                                    break;
                                };
                                if (!has_hole) {
                                    const sub_args = sp - argc;
                                    @memcpy(sub_args[0..n], ao.elems[0..n]);
                                    return pushAndInvokeClosure(vm, sp, ct, sub_args, n, ret_sp, sub_this);
                                }
                            }
                        }
                    }
                }
            }
            if (!co.flags.host_class) {
                const r = calls.callNative(vm, co, ret_sp[0], (sp - argc)[0..argc]) catch |e| return jit.errRes(vm, sp, e);
                ret_sp[0] = r;
                return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
            }
        }
    }
    const r = calls.callNonClosure(vm, callee, ret_sp[0], (sp - argc)[0..argc]) catch |e| return jit.errRes(vm, sp, e);
    ret_sp[0] = r;
    return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
}

pub fn jitCall(vm: *Vm, f: *Frame, sp: [*]Value, next_pc: [*]const u8, argc: u32) callconv(.c) JitResult {
    @import("../perf_rules.zig").prof_jit_calls += 1;
    f.pc = next_pc;
    vm.sp = sp;
    const callee = (sp - argc - 1)[0];
    const ret_sp = sp - argc - 2;
    if (callee.isObject() and callee.asObject().class == .closure) {
        return pushAndInvokeClosure(vm, sp, callee.asObject(), sp - argc, argc, ret_sp, ret_sp[0]);
    }
    return jitCallNonClosure(vm, sp, argc, ret_sp, callee);
}

pub fn jitNew(vm: *Vm, f: *Frame, sp: [*]Value, next_pc: [*]const u8, argc: u32) callconv(.c) JitResult {
    f.pc = next_pc;
    vm.sp = sp;
    const callee = (sp - argc - 1)[0];
    const ret_sp = sp - argc - 2;
    if (callee.isObject() and callee.asObject().class == .closure and callee.asObject().flags.constructor) {
        const co = callee.asObject();
        const this = if (co.flags.derived_ctor) Value.hole else (calls.allocThis(vm, co, callee) catch |e| return jit.errRes(vm, sp, e)).value();
        const child_f = calls.pushClosure(vm, co, sp - argc, argc, ret_sp, callee, this, true) catch |e| return jit.errRes(vm, sp, e);
        return invokeChildFrame(vm, sp, child_f);
    }
    const r = calls.construct(vm, callee, (sp - argc)[0..argc], callee) catch |e| return jit.errRes(vm, sp, e);
    ret_sp[0] = r;
    return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
}

pub fn jitApply(vm: *Vm, f: *Frame, sp_in: [*]Value, next_pc: [*]const u8, is_new: u32) callconv(.c) JitResult {
    var sp = sp_in;
    f.pc = next_pc - 1;
    vm.sp = sp;
    const argc = calls.expandArgs(vm, &sp) catch |e| return jit.errRes(vm, sp_in, e);
    const res = if (is_new != 0) jitNew(vm, f, sp, next_pc, argc) else jitCall(vm, f, sp, next_pc, argc);
    if (res.err != 0) vm.sp = sp_in;
    return res;
}

pub fn jitClosure(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, proto_idx: u32) callconv(.c) JitResult {
    const fp = f.fp.protos[proto_idx];
    if (!fp.is_generator and !fp.is_async and !fp.needs_home) {
        const o = objmod.alloc(vm, vm.fn_root, .closure) catch |e| {
            f.pc = pc;
            return jit.errRes(vm, sp, e);
        };
        o.payload = .{ .fp = fp };
        o.env = f.env;
        o.flags = .{ .callable = true, .lazy_fn = true, .constructor = fp.has_prototype };
        return .{ .bits = o.value().bits, .err = 0 };
    }
    f.pc = pc;
    vm.sp = sp;
    const o = objectops.makeClosure(vm, fp, f.env) catch |e| return jit.errRes(vm, sp, e);
    return .{ .bits = o.value().bits, .err = 0 };
}

pub fn jitPushEnv(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, n: u32) callconv(.c) JitResult {
    const e = vm.heap.newEnv(f.env, n) catch |err| {
        f.pc = pc;
        return jit.errRes(vm, sp, err);
    };
    @memset(e.slots()[0..n], Value.hole);
    f.env = e;
    return .{ .bits = 0, .err = 0 };
}

pub fn jitArrayFrom(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, n: u32) callconv(.c) JitResult {
    const base = sp - n;
    const arr = objmod.newArray(vm, base[0..n]) catch |e| {
        f.pc = pc;
        return jit.errRes(vm, sp, e);
    };
    base[0] = arr.value();
    return .{ .bits = @intFromPtr(base + 1), .err = 0 };
}

pub fn jitArguments(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8) callconv(.c) JitResult {
    f.pc = pc;
    vm.sp = sp;
    const a = objectops.argumentsObject(vm, f) catch |e| return jit.errRes(vm, sp, e);
    return .{ .bits = a.value().bits, .err = 0 };
}

pub fn jitSlowOp(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, op_raw: u32) callconv(.c) JitResult {
    const pr = @import("../perf_rules.zig");
    pr.prof_slow_ops += 1;
    pr.prof_slow_hist[op_raw & 255] += 1;
    f.pc = pc;
    vm.sp = sp;
    slow.exec(vm, f, @enumFromInt(@as(u8, @intCast(op_raw)))) catch |e| return jit.errRes(vm, sp, e);
    return .{ .bits = @intFromPtr(vm.sp), .err = 0 };
}

/// Executes a branching slow opcode (`opt_chain`, `ctor_ret_check`, `iter_next`, `for_in_next`).
/// Returns `(new_sp | (jumped << 63), err)` so the JIT knows both the updated `sp` and whether the branch was taken.
pub fn jitBranchSlowOp(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, op_raw: u32, fallthrough_pc: [*]const u8) callconv(.c) JitResult {
    f.pc = pc;
    vm.sp = sp;
    slow.exec(vm, f, @enumFromInt(@as(u8, @intCast(op_raw)))) catch |e| return jit.errRes(vm, sp, e);
    const jumped: u64 = @intFromBool(f.pc != fallthrough_pc);
    return .{ .bits = @intFromPtr(vm.sp) | (jumped << 63), .err = 0 };
}
