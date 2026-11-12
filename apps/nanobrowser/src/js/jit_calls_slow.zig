//! Less-frequent C-ABI helpers (`super`, method definitions, generic slow ops)
//! split from `jit_calls.zig` to keep every file well below 600 lines.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const value = @import("value.zig");
const Value = value.Value;
const Frame = @import("frame.zig").Frame;
const calls = @import("interp_call.zig");
const slow = @import("interp_slow.zig");
const props = @import("props.zig");
const objectops = @import("interp_object.zig");
const jit = @import("jit.zig");
const JitResult = jit.JitResult;
const jit_calls = @import("jit_calls.zig");

pub fn jitSuperCall(vm: *Vm, f: *Frame, sp: [*]Value, next_pc: [*]const u8, argc: u32) callconv(.c) JitResult {
    f.pc = next_pc;
    vm.sp = sp;
    const callee = (sp - argc - 1)[0];
    const ret_sp = sp - argc - 2;
    const new_target = ret_sp[0];
    if (callee.isObject() and callee.asObject().class == .closure and callee.asObject().flags.constructor) {
        const co = callee.asObject();
        const this = if (co.flags.derived_ctor) Value.hole else (calls.allocThis(vm, co, new_target) catch |e| return jit.errRes(vm, sp, e)).value();
        const child_f = calls.pushClosure(vm, co, sp - argc, argc, ret_sp, new_target, this, true) catch |e| return jit.errRes(vm, sp, e);
        return jit_calls.invokeChildFrame(vm, sp, child_f);
    }
    const r = calls.construct(vm, callee, (sp - argc)[0..argc], new_target) catch |e| return jit.errRes(vm, sp, e);
    ret_sp[0] = r;
    return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
}

pub fn jitSuperGet(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8) callconv(.c) JitResult {
    const home = (sp - 2)[0];
    const kv = (sp - 1)[0];
    const recv = (sp - 3)[0];
    if (home.isObject() and !home.asObject().flags.exotic and kv.isString() and kv.asString().key.bits != 0) {
        const pk = kv.asString().key;
        if (home.asObject().shape.proto) |p| {
            if (!p.flags.exotic) {
                const me = vm.megaSlot(p.shape, pk.bits);
                if (me.shape == p.shape and me.key_bits == pk.bits) {
                    if (me.holder) |mh| {
                        if (me.epoch == vm.proto_epoch and mh.shape == me.holder_shape and (me.slot & vm_mod.MegaICEntry.acc_flag) == 0) return .{ .bits = mh.slots[me.slot].bits, .err = 0 };
                    } else if (me.slot == @import("bytecode.zig").IC.missing_slot) {
                        if (me.epoch == vm.proto_epoch) return .{ .bits = Value.undefined.bits, .err = 0 };
                    } else {
                        return .{ .bits = p.slots[me.slot].bits, .err = 0 };
                    }
                }
                if (!p.flags.lazy_fn and !p.shape.is_dict and !(p.class == .array and pk.eql(vm.k.length))) {
                    if (p.shape.find(pk)) |slot| {
                        if (!p.shape.flagsAt(slot).accessor) {
                            me.* = .{ .shape = p.shape, .key_bits = pk.bits, .holder = null, .holder_shape = null, .slot = slot, .epoch = 0 };
                            return .{ .bits = p.slots[slot].bits, .err = 0 };
                        }
                    }
                }
            }
        } else return .{ .bits = Value.undefined.bits, .err = 0 };
    }
    f.pc = pc;
    vm.sp = sp;
    if (!home.isObject()) return jit.errRes(vm, sp, vm.throwError(.SyntaxError, "'super' keyword unexpected here"));
    const key = @import("conv.zig").toPropKey(vm, kv) catch |e| return jit.errRes(vm, sp, e);
    const proto = props.getProto(vm, home.asObject()) catch |e| return jit.errRes(vm, sp, e);
    const r = if (proto) |p| (props.getR(vm, p, key, recv) catch |e| return jit.errRes(vm, sp, e)) else Value.undefined;
    return .{ .bits = r.bits, .err = 0 };
}

pub fn jitDefineMethod(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, flags: u32) callconv(.c) JitResult {
    f.pc = pc;
    vm.sp = sp;
    const kv = (sp - 2)[0];
    const key = if (kv.isString() and kv.asString().key.bits != 0) kv.asString().key else (@import("conv.zig").toPropKey(vm, kv) catch |e| return jit.errRes(vm, sp, e));
    objectops.defineMethod(vm, (sp - 3)[0].asObject(), key, (sp - 1)[0], @intCast(flags)) catch |e| return jit.errRes(vm, sp, e);
    return .{ .bits = 0, .err = 0 };
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
