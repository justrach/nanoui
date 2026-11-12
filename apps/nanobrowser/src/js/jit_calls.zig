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
const props = @import("props.zig");
const objectops = @import("interp_object.zig");
const jit = @import("jit.zig");
const arm64_resume = @import("jit_arm64_resume.zig");
const JitFn = jit.JitFn;
const JitResult = jit.JitResult;

pub noinline fn handleChildErr(vm: *Vm, caller_sp: [*]Value, child_f: *Frame, err_code_in: u64) callconv(.c) JitResult {
    @branchHint(.cold);
    var cur_code = err_code_in;
    resume_loop: while (true) {
        var err = jit.decodeErr(cur_code);
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
                    const catch_pc = fr.catchOffset(v);
                    child_f.env = if (saved.isUndefined()) null else @fieldParentPtr("cell", saved.asCell());
                    child_f.pc = child_f.fp.code.ptr + catch_pc;
                    (s - 1)[0] = vm.exception;
                    vm.exception = Value.undefined;
                    vm.sp = s;
                    if (comptime jit.enabled) {
                        if (child_f.fp.jit_fn) |jfn| if (child_f.fp.findCatchWord(catch_pc)) |word_off| if (arm64_resume.getResumeStub()) |rstub| {
                            vm.checkNativeStack() catch |e| {
                                vm.frame_top -= 1;
                                return jit.errRes(vm, caller_sp, e);
                            };
                            const target: *const anyopaque = @ptrFromInt(@intFromPtr(jfn) + @as(usize, word_off) * @sizeOf(u32));
                            const res = rstub(vm, child_f, child_f.bp, s, target);
                            if (res.err != 0) {
                                cur_code = res.err;
                                continue :resume_loop;
                            }
                            var r = Value{ .bits = res.bits };
                            if (child_f.is_construct and !r.isObject()) r = child_f.this;
                            const ret_sp = child_f.ret_sp;
                            vm.frame_top -= 1;
                            ret_sp[0] = r;
                            return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
                        };
                    }
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

pub fn jitCallNativeGetter(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, go: *Object) callconv(.c) JitResult {
    f.pc = pc;
    vm.sp = sp;
    const r = calls.callNative(vm, go, (sp - 1)[0], &.{}) catch |e| return jit.errRes(vm, sp, e);
    return .{ .bits = r.bits, .err = 0 };
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

pub fn jitCallSetter(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, slot_bits: u64) callconv(.c) JitResult {
    const slot_val = Value{ .bits = slot_bits };
    const a: *heap.Accessor = @fieldParentPtr("cell", slot_val.asCell());
    if (a.set.isUndefined()) {
        if (f.fp.strict) {
            f.pc = pc;
            vm.sp = sp;
            const ic = &f.fp.ics[std.mem.readInt(u32, (pc + 1)[0..4], .little)];
            return jit.errRes(vm, sp, props.throwReadonly(vm, ic.key));
        }
        return .{ .bits = 0, .err = 0 };
    }
    const recv = (sp - 2)[0];
    const v = (sp - 1)[0];
    if (a.set.isObject()) {
        const so = a.set.asObject();
        if (so.class == .closure) {
            f.pc = pc + 5;
            sp[0] = v;
            vm.sp = sp + 1;
            const child_f = calls.pushClosure(vm, so, sp, 1, sp, Value.undefined, recv, false) catch |e| return jit.errRes(vm, sp, e);
            const res = invokeChildFrame(vm, sp, child_f);
            if (res.err != 0) return res;
            vm.sp = sp;
            return .{ .bits = 0, .err = 0 };
        }
        if (so.class == .native and !so.flags.host_class) {
            f.pc = pc;
            vm.sp = sp;
            _ = calls.callNative(vm, so, recv, &.{v}) catch |e| return jit.errRes(vm, sp, e);
            return .{ .bits = 0, .err = 0 };
        }
    }
    f.pc = pc;
    vm.sp = sp;
    _ = calls.call(vm, a.set, recv, &.{v}) catch |e| return jit.errRes(vm, sp, e);
    return .{ .bits = 0, .err = 0 };
}

noinline fn jitCallNonClosure(vm: *Vm, sp: [*]Value, argc_in: u32, ret_sp: [*]Value, callee_in: Value) JitResult {
    var cur_callee = callee_in;
    var cur_this = ret_sp[0];
    var cur_args: [*]Value = sp - argc_in;
    var cur_argc: u32 = argc_in;
    var scratch: [*]Value = sp;
    var depth: u32 = 0;
    while (cur_callee.isObject() and depth < 16) : (depth += 1) {
        const co = cur_callee.asObject();
        if (co.class == .closure) {
            vm.sp = scratch;
            const child_f = calls.pushClosure(vm, co, cur_args, cur_argc, ret_sp, Value.undefined, cur_this, false) catch |e| return jit.errRes(vm, sp, e);
            return invokeChildFrame(vm, sp, child_f);
        }
        if (co.class == .bound) {
            const b = co.payload.bound;
            const blen: u32 = @intCast(b.args.len);
            if (blen > 0) {
                const total: usize = @as(usize, blen) + @as(usize, cur_argc);
                if (total > 256 or @intFromPtr(scratch) + total * @sizeOf(Value) > vm.stack_end) break;
                @memcpy(scratch[0..blen], b.args);
                if (cur_argc > 0) @memcpy((scratch + blen)[0..cur_argc], cur_args[0..cur_argc]);
                cur_args = scratch;
                cur_argc = blen + cur_argc;
                scratch += total;
            }
            cur_this = b.this;
            cur_callee = b.target.value();
            continue;
        }
        if (co.class == .native) {
            const nf = co.payload.native.func;
            if (nf == &b_fn.fnCall) {
                cur_callee = cur_this;
                if (cur_argc > 0) {
                    cur_this = cur_args[0];
                    cur_args += 1;
                    cur_argc -= 1;
                } else {
                    cur_this = Value.undefined;
                }
                continue;
            }
            if (nf == &b_fn.fnApply) {
                const target = cur_this;
                if (!target.isObject() or !target.asObject().flags.callable) break;
                const sub_this = if (cur_argc > 0) cur_args[0] else Value.undefined;
                const arr_val = if (cur_argc > 1) cur_args[1] else Value.undefined;
                if (arr_val.isNullish()) {
                    cur_callee = target;
                    cur_this = sub_this;
                    cur_args = scratch;
                    cur_argc = 0;
                    continue;
                }
                if (arr_val.isObject()) {
                    const ao = arr_val.asObject();
                    const n = ao.elems_len;
                    const is_fast_args = ao.class == .arguments and (ao.shape == vm.args_strict_shape or ao.shape == vm.args_sloppy_shape) and ao.slots[0].bits == Value.fromUsize(n).bits;
                    if (!ao.flags.exotic and !ao.flags.has_sparse and ((ao.class == .array and n == ao.arr_len) or is_fast_args) and n <= 256) {
                        var has_hole = false;
                        for (ao.elems[0..n]) |el| if (el.isHole()) { has_hole = true; break; };
                        if (!has_hole and @intFromPtr(scratch) + @as(usize, n) * @sizeOf(Value) <= vm.stack_end) {
                            if (n > 0) @memcpy(scratch[0..n], ao.elems[0..n]);
                            cur_callee = target;
                            cur_this = sub_this;
                            cur_args = scratch;
                            cur_argc = n;
                            scratch += n;
                            continue;
                        }
                    }
                }
                break;
            }
            if (!co.flags.host_class) {
                vm.sp = scratch;
                const r = calls.callNative(vm, co, cur_this, cur_args[0..cur_argc]) catch |e| return jit.errRes(vm, sp, e);
                ret_sp[0] = r;
                return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
            }
        }
        break;
    }
    vm.sp = scratch;
    const r = calls.call(vm, cur_callee, cur_this, cur_args[0..cur_argc]) catch |e| return jit.errRes(vm, sp, e);
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

pub fn jitArgsGet(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, slot: u32) callconv(.c) JitResult {
    if (f.bp[slot].isHole()) {
        f.pc = pc;
        vm.sp = sp;
        const a = objectops.argumentsObject(vm, f) catch |e| return jit.errRes(vm, sp, e);
        f.bp[slot] = a.value();
    }
    return .{ .bits = f.bp[slot].bits, .err = 0 };
}

pub fn jitArgsLen(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, slot: u32) callconv(.c) JitResult {
    const cur = f.bp[slot];
    if (cur.isHole()) return .{ .bits = Value.fromUsize(f.argc).bits, .err = 0 };
    f.pc = pc;
    vm.sp = sp;
    const r = props.getV(vm, cur, vm.k.length) catch |e| return jit.errRes(vm, sp, e);
    return .{ .bits = r.bits, .err = 0 };
}

pub fn jitArgsElem(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, slot: u32) callconv(.c) JitResult {
    const idx = (sp - 1)[0];
    if (f.bp[slot].isHole()) {
        if (idx.isInt() and idx.asInt() >= 0) {
            const i: u32 = @intCast(idx.asInt());
            if (i < f.argc) return .{ .bits = f.args[i].bits, .err = 0 };
            if (!vm.protos.object.flags.proto_dirty) return .{ .bits = Value.undefined.bits, .err = 0 };
        }
        f.pc = pc;
        vm.sp = sp;
        const a = objectops.argumentsObject(vm, f) catch |e| return jit.errRes(vm, sp, e);
        f.bp[slot] = a.value();
    }
    f.pc = pc;
    vm.sp = sp;
    const r = @import("interp_ic.zig").getElem(vm, f.bp[slot], idx) catch |e| return jit.errRes(vm, sp, e);
    return .{ .bits = r.bits, .err = 0 };
}

pub fn jitArgsApply(vm: *Vm, f: *Frame, sp: [*]Value, next_pc: [*]const u8, slot: u32) callconv(.c) JitResult {
    const ret_sp = sp - 3;
    const recv = ret_sp[0];
    const fn_val = ret_sp[1];
    const this_arg = ret_sp[2];
    f.pc = next_pc;
    vm.sp = sp;
    if (f.bp[slot].isHole() and fn_val.isObject() and fn_val.asObject().class == .native and fn_val.asObject().payload.native.func == &b_fn.fnApply) {
        if (recv.isObject()) {
            const to = recv.asObject();
            if (to.class == .closure or (to.class == .bound and to.payload.bound.args.len == 0 and to.payload.bound.target.class == .closure)) {
                const target = if (to.class == .closure) to else to.payload.bound.target;
                const call_this = if (to.class == .closure) this_arg else to.payload.bound.this;
                if (@intFromPtr(sp) + @as(usize, f.argc) * @sizeOf(Value) > vm.stack_end) {
                    return jit.errRes(vm, sp, vm.throwError(.RangeError, "Maximum call stack size exceeded"));
                }
                if (f.argc != 0) @memcpy(sp[0..f.argc], f.args[0..f.argc]);
                return pushAndInvokeClosure(vm, sp, target, sp, f.argc, ret_sp, call_this);
            }
            if (to.class == .native and !to.flags.host_class) {
                const r = calls.callNative(vm, to, this_arg, f.args[0..f.argc]) catch |e| return jit.errRes(vm, sp, e);
                ret_sp[0] = r;
                return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
            }
        }
        const r = calls.call(vm, recv, this_arg, f.args[0..f.argc]) catch |e| return jit.errRes(vm, sp, e);
        ret_sp[0] = r;
        return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
    }
    if (f.bp[slot].isHole()) {
        const a = objectops.argumentsObject(vm, f) catch |e| return jit.errRes(vm, sp, e);
        f.bp[slot] = a.value();
    }
    sp[0] = f.bp[slot];
    const res = jitCall(vm, f, sp + 1, next_pc, 2);
    if (res.err != 0) vm.sp = sp;
    return res;
}

pub fn jitRest(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, first: u32) callconv(.c) JitResult {
    const items = if (f.argc > first) f.args[first..f.argc] else f.args[0..0];
    const arr = objmod.newArray(vm, items) catch |e| {
        f.pc = pc;
        return jit.errRes(vm, sp, e);
    };
    return .{ .bits = arr.value().bits, .err = 0 };
}

pub fn jitNewRegExp(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8) callconv(.c) JitResult {
    f.pc = pc;
    vm.sp = sp;
    const p_idx = std.mem.readInt(u32, (pc + 1)[0..4], .little);
    const f_idx = std.mem.readInt(u32, (pc + 5)[0..4], .little);
    const r = @import("b_regexp.zig").create(vm, f.fp.constants[p_idx].asString(), f.fp.constants[f_idx].asString(), vm.protos.regexp) catch |e| return jit.errRes(vm, sp, e);
    return .{ .bits = r.bits, .err = 0 };
}

pub fn jitIn(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8) callconv(.c) JitResult {
    const r = (sp - 1)[0];
    if (!r.isObject()) {
        f.pc = pc;
        return jit.errRes(vm, sp, vm.throwError(.TypeError, "Cannot use 'in' operator on a non-object"));
    }
    const k = (sp - 2)[0];
    const ro = r.asObject();
    if (k.isString()) {
        f.pc = pc;
        vm.sp = sp;
        if (@import("string.zig").findExistingKey(vm, k.asString()) catch |e| return jit.errRes(vm, sp, e)) |ek| {
            const b = props.has(vm, ro, ek) catch |e| return jit.errRes(vm, sp, e);
            return .{ .bits = Value.fromBool(b).bits, .err = 0 };
        }
        if (@import("interp_ic.zig").noExoticOnChain(ro)) return .{ .bits = Value.false.bits, .err = 0 };
    }
    f.pc = pc;
    vm.sp = sp;
    const pk = @import("conv.zig").toPropKey(vm, k) catch |e| return jit.errRes(vm, sp, e);
    const b = props.has(vm, ro, pk) catch |e| return jit.errRes(vm, sp, e);
    return .{ .bits = Value.fromBool(b).bits, .err = 0 };
}

pub fn jitInstanceOf(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8) callconv(.c) JitResult {
    f.pc = pc;
    vm.sp = sp;
    const b = @import("ops.zig").instanceOf(vm, (sp - 2)[0], (sp - 1)[0]) catch |e| return jit.errRes(vm, sp, e);
    return .{ .bits = Value.fromBool(b).bits, .err = 0 };
}

pub fn jitCallNativeStub(
    vm: *Vm,
    caller_sp: [*]Value,
    ret_sp: [*]Value,
    co: *Object,
    this_bits: u64,
    args_ptr: [*]const Value,
    argc: usize,
) callconv(.c) JitResult {
    vm.sp = if (@intFromPtr(args_ptr + argc) > @intFromPtr(caller_sp)) @constCast(args_ptr + argc) else caller_sp;
    const saved_nt = vm.new_target;
    const saved_callee = vm.callee;
    vm.new_target = Value.undefined;
    vm.callee = co;
    vm.depth += 1;
    defer {
        vm.new_target = saved_nt;
        vm.callee = saved_callee;
        vm.depth -= 1;
    }
    if ((vm.depth & 7) == 0) {
        vm.checkNativeStack() catch |e| return jit.errRes(vm, caller_sp, e);
    }
    @import("../perf_rules.zig").prof_nat_calls += 1;
    const r = co.payload.native.func(vm, .{ .bits = this_bits }, args_ptr[0..argc]) catch |e| return jit.errRes(vm, caller_sp, e);
    ret_sp[0] = r;
    return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
}

const slow_calls = @import("jit_calls_slow.zig");
pub const jitSuperCall = slow_calls.jitSuperCall;
pub const jitSuperGet = slow_calls.jitSuperGet;
pub const jitDefineMethod = slow_calls.jitDefineMethod;
pub const jitSlowOp = slow_calls.jitSlowOp;
pub const jitBranchSlowOp = slow_calls.jitBranchSlowOp;
