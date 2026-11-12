//! Shared ARM64 Baseline JIT runtime trampolines:
//! 1. `getResumeStub`: resumes a JIT-compiled function directly at a `push_try` catch PC
//!    after exception unwinding (`handleChildErr`), avoiding interpreter deoptimization.
//! 2. `getFastGetterStub`: dispatches accessor getters (`ic.is_accessor`, `mega_ic`)
//!    inline in ARM64 (`undefined`, `.native` tail-call, or `.closure` via `fast_call_stub`).
//! 3. `getFastArgsApplyStub`: executes `fn.apply(thisArg, arguments)` (`Op.args_apply`)
//!    inline in ARM64 without materializing `arguments` or entering C.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const bc = @import("bytecode.zig");
const fr = @import("frame.zig");
const Frame = fr.Frame;
const heap = @import("heap.zig");
const objmod = @import("object.zig");
const Object = objmod.Object;
const Value = @import("value.zig").Value;
const b_fn = @import("b_function.zig");
const jit = @import("jit.zig");
const JitResult = jit.JitResult;
const jit_calls = @import("jit_calls.zig");
const enc = @import("jit_arm64_enc.zig");
const Emitter = enc.Emitter;

comptime {
    std.debug.assert(@offsetOf(heap.Accessor, "cell") == 0);
    std.debug.assert(@offsetOf(heap.Accessor, "get") % 8 == 0);
}

pub const ResumeStubFn = *const fn (
    vm: *Vm,
    f: *Frame,
    bp: [*]Value,
    sp: [*]Value,
    target: *const anyopaque,
) callconv(.c) JitResult;

var cached_resume_stub: ?ResumeStubFn = null;
var cached_getter_stub: ?*const anyopaque = null;
var cached_args_apply_stub: ?*const anyopaque = null;
const stub_mod = @import("jit_arm64_stub.zig");

fn allocSmallStub(words: []const u32) ?*const anyopaque {
    const jfn = jit.global_jit_pool.allocCode(std.heap.page_allocator, words) orelse return null;
    return @ptrCast(jfn);
}

pub fn getResumeStub() ?ResumeStubFn {
    if (comptime !jit.enabled) return null;
    if (cached_resume_stub) |s| return s;
    var e = Emitter{ .buf = &stub_mod.stub_words_buf };

    e.stpPre64(29, 30, 31, -12);
    e.addImm64(29, 31, 0);
    e.stpOffset64(19, 20, 31, 2);
    e.stpOffset64(21, 22, 31, 4);
    e.stpOffset64(23, 24, 31, 6);
    e.stpOffset64(25, 26, 31, 8);
    e.strImm64(27, 31, 10);
    e.mov64(19, 0);
    e.mov64(20, 1);
    e.mov64(21, 2);
    e.mov64(22, 3);
    e.mov64(9, 4);
    e.ldrImm64(8, 20, @intCast(@offsetOf(Frame, "fp") / 8));
    e.movz(25, 0xFFF9, 3);
    e.movz(26, 2, 0);
    e.movk(26, 0xFFFA, 3);
    e.movz(27, 0xFFFB, 3);
    const bl_idx = e.len;
    e.blImm(0);
    e.ldrImm64(27, 31, 10);
    e.ldpOffset64(25, 26, 31, 8);
    e.ldpOffset64(23, 24, 31, 6);
    e.ldpOffset64(21, 22, 31, 4);
    e.ldpOffset64(19, 20, 31, 2);
    e.ldpPost64(29, 30, 31, 12);
    e.ret();

    e.buf[bl_idx] |= @as(u32, @intCast(e.len - bl_idx)) & 0x03FF_FFFF;
    e.stpPre64(29, 30, 31, -4);
    e.addImm64(29, 31, 0);
    e.stpOffset64(23, 24, 31, 2);
    e.ldrImm64(23, 8, @intCast(@offsetOf(bc.FuncProto, "constants") / 8));
    e.ldrImm64(24, 8, @intCast(@offsetOf(bc.FuncProto, "ics") / 8));
    e.br(9);

    if (e.overflow) return null;
    const raw = allocSmallStub(stub_mod.stub_words_buf[0..e.len]) orelse return null;
    cached_resume_stub = @ptrCast(@alignCast(raw));
    return cached_resume_stub;
}

pub fn getFastGetterStub() ?*const anyopaque {
    if (comptime !jit.enabled) return null;
    if (cached_getter_stub) |s| return s;
    var e = Emitter{ .buf = &stub_mod.stub_words_buf };

    // Entry: x0 = slot_bits (T_INTERNAL | *Accessor), x3 = pc_addr, [x22, #-8] = recv.
    e.ubfm64(5, 0, 0, 47);
    e.ldrImm64(6, 5, @intCast(@offsetOf(heap.Accessor, "get") / 8));
    e.subImm64(7, 26, 2);
    e.cmpReg64(6, 7);
    const b_not_undef = e.len;
    e.bCond(.ne, 0);
    e.mov64(0, 7);
    e.movz(1, 0, 0);
    e.ret();

    e.buf[b_not_undef] |= (@as(u32, @intCast(e.len - b_not_undef)) & 0x7FFFF) << 5;
    e.eorReg64(7, 6, 27);
    e.lsrImm64(8, 7, 48);
    const b_slow = e.len;
    e.cbnz64(8, 0);
    e.ldrbImm(8, 7, @intCast(@offsetOf(Object, "class")));
    e.cmpImm64(8, @intFromEnum(objmod.Class.native));
    const b_not_native = e.len;
    e.bCond(.ne, 0);
    e.ldrhImm(8, 7, @intCast(@offsetOf(Object, "flags") / 2));
    const b_host_class = e.len;
    e.tbnz32(8, @bitOffsetOf(objmod.Flags, "host_class"), 0);
    e.mov64(4, 7);
    e.mov64(2, 22);
    e.mov64(1, 20);
    e.mov64(0, 19);
    e.movImm64(9, @intFromPtr(&jit_calls.jitCallNativeGetter));
    e.br(9);

    e.buf[b_not_native] |= (@as(u32, @intCast(e.len - b_not_native)) & 0x7FFFF) << 5;
    e.addImm64(9, 22, 16);
    e.ldrImm64(10, 19, @intCast(@offsetOf(Vm, "stack_end") / 8));
    e.cmpReg64(9, 10);
    const b_stack_ovf = e.len;
    e.bCond(.hi, 0);
    e.ldur64(8, 22, -8);
    e.stpOffset64(8, 6, 22, 0);
    e.stpPre64(29, 30, 31, -4);
    e.addImm64(29, 31, 0);
    e.strImm64(22, 31, 2);
    e.mov64(22, 9);
    e.addImm64(3, 3, 5);
    e.movz(4, 0, 0);
    e.ldrImm64(9, 19, @intCast(@offsetOf(Vm, "fast_call_stub") / 8));
    e.blr(9);
    e.ldrImm64(22, 31, 2);
    e.ldpPost64(29, 30, 31, 4);
    const b_err = e.len;
    e.cbnz64(1, 0);
    e.ldrImm64(0, 22, 0);
    e.ret();
    e.buf[b_err] |= (@as(u32, @intCast(e.len - b_err)) & 0x7FFFF) << 5;
    e.strImm64(22, 19, @intCast(@offsetOf(Vm, "sp") / 8));
    e.ret();

    const slow_idx = e.len;
    e.buf[b_slow] |= (@as(u32, @intCast(slow_idx - b_slow)) & 0x7FFFF) << 5;
    e.buf[b_host_class] |= (@as(u32, @intCast(slow_idx - b_host_class)) & 0x3FFF) << 5;
    e.buf[b_stack_ovf] |= (@as(u32, @intCast(slow_idx - b_stack_ovf)) & 0x7FFFF) << 5;
    e.mov64(4, 0);
    e.mov64(2, 22);
    e.mov64(1, 20);
    e.mov64(0, 19);
    e.movImm64(9, @intFromPtr(&jit.jitCallGetter));
    e.br(9);

    if (e.overflow) return null;
    cached_getter_stub = allocSmallStub(stub_mod.stub_words_buf[0..e.len]);
    return cached_getter_stub;
}

pub fn getFastArgsApplyStub() ?*const anyopaque {
    if (comptime !jit.enabled) return null;
    if (cached_args_apply_stub) |s| return s;
    var e = Emitter{ .buf = &stub_mod.stub_words_buf };

    // Entry: x3 = next_pc, x4 = slot, [x22 - 24..x22] = [recv, fn_val, this_arg].
    e.ldrRegScaled64(5, 21, 4);
    e.addImm64(6, 26, 2);
    e.cmpReg64(5, 6);
    const b_not_hole = e.len;
    e.bCond(.ne, 0);

    e.ldur64(6, 22, -16);
    e.eorReg64(6, 6, 27);
    e.lsrImm64(7, 6, 48);
    const b_fn_not_obj = e.len;
    e.cbnz64(7, 0);
    e.ldrbImm(7, 6, @intCast(@offsetOf(Object, "class")));
    e.cmpImm64(7, @intFromEnum(objmod.Class.native));
    const b_fn_not_nat = e.len;
    e.bCond(.ne, 0);
    e.ldrImm64(7, 6, @intCast(@offsetOf(Object, "payload") / 8));
    e.ldrImm64(7, 7, @intCast(@offsetOf(objmod.NativeData, "func") / 8));
    e.movImm64(8, @intFromPtr(&b_fn.fnApply));
    e.cmpReg64(7, 8);
    const b_not_apply = e.len;
    e.bCond(.ne, 0);

    e.ldur64(0, 22, -24);
    e.eorReg64(6, 0, 27);
    e.lsrImm64(7, 6, 48);
    const b_recv_not_obj = e.len;
    e.cbnz64(7, 0);
    e.ldrhImm(7, 6, @intCast(@offsetOf(Object, "flags") / 2));
    const b_recv_not_call = e.len;
    e.tbz32(7, @bitOffsetOf(objmod.Flags, "callable"), 0);

    e.ldrImm32(8, 20, @intCast(@offsetOf(Frame, "argc") / 4));
    e.cmpImm64(8, 32);
    const b_argc_big = e.len;
    e.bCond(.hi, 0);
    e.subImm64(9, 22, 8);
    e.addRegLsl64(10, 9, 8, 3);
    e.ldrImm64(11, 19, @intCast(@offsetOf(Vm, "stack_end") / 8));
    e.cmpReg64(10, 11);
    const b_stack_ovf = e.len;
    e.bCond(.hi, 0);

    e.ldur64(2, 22, -8);
    e.stur64(2, 22, -24);
    e.stur64(0, 22, -16);
    e.ldrImm64(6, 20, @intCast(@offsetOf(Frame, "args") / 8));
    e.movz(7, 0, 0);
    const copy_loop = e.len;
    e.cmpReg32(7, 8);
    const b_copy_done = e.len;
    e.bCond(.hs, 0);
    e.ldrRegScaled64(11, 6, 7);
    e.strRegScaled64(11, 9, 7);
    e.addImm64(7, 7, 1);
    e.bImm(@as(i32, @intCast(copy_loop)) - @as(i32, @intCast(e.len)));
    e.buf[b_copy_done] |= (@as(u32, @intCast(e.len - b_copy_done)) & 0x7FFFF) << 5;

    e.mov64(22, 10);
    e.mov64(4, 8);
    e.ldrImm64(9, 19, @intCast(@offsetOf(Vm, "fast_call_stub") / 8));
    e.br(9);

    const slow_idx = e.len;
    e.buf[b_not_hole] |= (@as(u32, @intCast(slow_idx - b_not_hole)) & 0x7FFFF) << 5;
    e.buf[b_fn_not_obj] |= (@as(u32, @intCast(slow_idx - b_fn_not_obj)) & 0x7FFFF) << 5;
    e.buf[b_fn_not_nat] |= (@as(u32, @intCast(slow_idx - b_fn_not_nat)) & 0x7FFFF) << 5;
    e.buf[b_not_apply] |= (@as(u32, @intCast(slow_idx - b_not_apply)) & 0x7FFFF) << 5;
    e.buf[b_recv_not_obj] |= (@as(u32, @intCast(slow_idx - b_recv_not_obj)) & 0x7FFFF) << 5;
    e.buf[b_recv_not_call] |= (@as(u32, @intCast(slow_idx - b_recv_not_call)) & 0x3FFF) << 5;
    e.buf[b_argc_big] |= (@as(u32, @intCast(slow_idx - b_argc_big)) & 0x7FFFF) << 5;
    e.buf[b_stack_ovf] |= (@as(u32, @intCast(slow_idx - b_stack_ovf)) & 0x7FFFF) << 5;
    e.mov64(2, 22);
    e.mov64(1, 20);
    e.mov64(0, 19);
    e.movImm64(9, @intFromPtr(&jit.jitArgsApply));
    e.br(9);

    if (e.overflow) return null;
    cached_args_apply_stub = allocSmallStub(stub_mod.stub_words_buf[0..e.len]);
    return cached_args_apply_stub;
}
