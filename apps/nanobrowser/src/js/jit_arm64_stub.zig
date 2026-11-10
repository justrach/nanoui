//! Shared ARM64 JIT-to-JIT direct call trampoline (`jitFastCallStub`).
//! Bypasses C-ABI `jitCall` -> `pushClosure` -> `invokeChildFrame` -> 12-word prologue
//! when invoking a compiled JS closure (`fp.jit_fast_fn != null`).

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const bc = @import("bytecode.zig");
const fr = @import("frame.zig");
const Frame = fr.Frame;
const objmod = @import("object.zig");
const Object = objmod.Object;
const jit = @import("jit.zig");
const jit_calls = @import("jit_calls.zig");
const enc = @import("jit_arm64_enc.zig");
const Emitter = enc.Emitter;

comptime {
    std.debug.assert(@offsetOf(Frame, "fp") % 8 == 0);
    std.debug.assert(@offsetOf(Frame, "pc") % 8 == 0);
    std.debug.assert(@offsetOf(Frame, "bp") % 8 == 0);
    std.debug.assert(@offsetOf(Frame, "ret_sp") % 8 == 0);
    std.debug.assert(@offsetOf(Frame, "env") % 8 == 0);
    std.debug.assert(@offsetOf(Frame, "func") % 8 == 0);
    std.debug.assert(@offsetOf(Frame, "this") % 8 == 0);
    std.debug.assert(@offsetOf(Frame, "new_target") % 8 == 0);
    std.debug.assert(@offsetOf(Frame, "args") % 8 == 0);
    std.debug.assert(@offsetOf(Frame, "argc") % 4 == 0);
    std.debug.assert(@offsetOf(Frame, "co") % 8 == 0);
}

var cached_stub: ?*const anyopaque = null;
var stub_words_buf: [enc.max_inst_words]u32 = undefined;

/// Builds (once per process) and returns the executable `jitFastCallStub` address.
/// Entry contract from caller JIT code:
///   `x19 = vm`, `x20 = caller_f`, `x21 = caller_bp`, `x22 = caller_sp`,
///   `x25..x27 = NaN-box tag constants`, `x3 = next_pc`, `x4 = argc`.
/// Returns `(x0 = new_sp, x1 = err)` with `x19, x20, x21, x23..x27` preserved.
pub fn getOrBuildStub() ?*const anyopaque {
    if (comptime !jit.enabled) return null;
    if (cached_stub) |s| return s;
    var e = Emitter{ .buf = &stub_words_buf };

    // x5 = args_ptr = caller_sp - argc * 8; x6 = callee; x10 = ret_sp = args_ptr - 16
    e.subRegLsl64(5, 22, 4, 3);
    e.ldur64(6, 5, -8);
    e.subImm64(10, 5, 16);

    // Check callee is T_OBJECT and class == .closure:
    e.eorReg64(7, 6, 27);
    e.lsrImm64(0, 7, 48);
    const b_not_obj = e.len;
    e.cbnz64(0, 0);
    e.ldrbImm(0, 7, @intCast(@offsetOf(Object, "class")));
    e.cmpImm64(0, @intFromEnum(objmod.Class.closure));
    const b_not_closure = e.len;
    e.bCond(.ne, 0);

    // Load fp = callee.payload.fp and jfast = fp.jit_fast_fn:
    e.ldrImm64(8, 7, @intCast(@offsetOf(Object, "payload") / 8));
    e.ldrImm64(9, 8, @intCast(@offsetOf(bc.FuncProto, "jit_fast_fn") / 8));
    const b_no_fast = e.len;
    e.cbz64(9, 0);

    // Check vm.frame_top < max_frames:
    e.ldrImm32(11, 19, @intCast(@offsetOf(Vm, "frame_top") / 4));
    e.movz(0, vm_mod.max_frames, 0);
    e.cmpReg32(11, 0);
    const b_frame_ovf = e.len;
    e.bCond(.hs, 0);

    // Check native stack headroom (SP >= vm.stack_limit + 256):
    e.addImm64(0, 31, 0);
    e.ldrImm64(1, 19, @intCast(@offsetOf(Vm, "stack_limit") / 8));
    e.addImm64(1, 1, 256);
    e.cmpReg64(0, 1);
    const b_nat_ovf = e.len;
    e.bCond(.lo, 0);

    // Check JS operand stack headroom (bp + fp.stack_need_bytes <= vm.stack_end):
    e.ldrImm32(0, 8, @intCast(@offsetOf(bc.FuncProto, "stack_need_bytes") / 4));
    e.addReg64(0, 5, 0);
    e.ldrImm64(1, 19, @intCast(@offsetOf(Vm, "stack_end") / 8));
    e.cmpReg64(0, 1);
    const b_js_ovf = e.len;
    e.bCond(.hi, 0);

    // Check interrupt budget (budget - 1 > 0):
    e.ldrImm32(12, 19, @intCast(@offsetOf(Vm, "budget") / 4));
    e.subsImm32(12, 12, 1);
    const b_budget = e.len;
    e.bCond(.le, 0);

    // Load this = ret_sp[0] and handle sloppy `coerce_this`:
    e.ldrImm64(13, 10, 0);
    e.ldrbImm(0, 8, @intCast(@offsetOf(bc.FuncProto, "coerce_this")));
    const b_no_coerce1 = e.len;
    e.cbz32(0, 0);
    e.eorReg64(0, 13, 27);
    e.lsrImm64(0, 0, 48);
    const b_no_coerce2 = e.len;
    e.cbz64(0, 0);
    e.eorReg64(0, 13, 26);
    e.lsrImm64(0, 0, 1);
    e.cmpImm64(0, 1);
    const b_prim_this = e.len;
    e.bCond(.ne, 0);
    e.ldrImm64(13, 19, @intCast(@offsetOf(Vm, "global_obj") / 8));
    e.orrReg64(13, 13, 27);

    // Fast path committed! Update caller_f.pc and vm.budget:
    const commit_idx = e.len;
    e.buf[b_no_coerce1] |= (@as(u32, @intCast(commit_idx - b_no_coerce1)) & 0x7FFFF) << 5;
    e.buf[b_no_coerce2] |= (@as(u32, @intCast(commit_idx - b_no_coerce2)) & 0x7FFFF) << 5;
    e.strImm64(3, 20, @intCast(@offsetOf(Frame, "pc") / 8));
    e.strImm32(12, 19, @intCast(@offsetOf(Vm, "budget") / 4));

    // Zero-fill locals bp[min(argc, nparams)..nlocals] to Value.undefined; x14 = child_sp:
    e.ldrhImm(0, 8, @intCast(@offsetOf(bc.FuncProto, "nparams") / 2));
    e.ldrImm32(1, 8, @intCast(@offsetOf(bc.FuncProto, "nlocals") / 4));
    e.cmpReg32(4, 0);
    e.csel32(0, 4, 0, .lo);
    e.addRegLsl64(14, 5, 1, 3);
    e.addRegLsl64(0, 5, 0, 3);
    e.subImm64(2, 26, 2);
    const init_loop = e.len;
    e.cmpReg64(0, 14);
    const b_init_done = e.len;
    e.bCond(.hs, 0);
    e.strImm64(2, 0, 0);
    e.addImm64(0, 0, 8);
    e.bImm(@as(i32, @intCast(init_loop)) - @as(i32, @intCast(e.len)));
    e.buf[b_init_done] |= (@as(u32, @intCast(e.len - b_init_done)) & 0x7FFFF) << 5;

    // Populate child_f = &vm.frames[frame_top] (x15):
    e.ldrImm64(0, 19, @intCast(@offsetOf(Vm, "frames") / 8));
    e.movz(1, @intCast(@sizeOf(Frame)), 0);
    e.madd64(15, 11, 1, 0);
    e.strImm64(8, 15, @intCast(@offsetOf(Frame, "fp") / 8));
    e.ldrImm64(0, 8, @intCast(@offsetOf(bc.FuncProto, "code") / 8));
    e.strImm64(0, 15, @intCast(@offsetOf(Frame, "pc") / 8));
    e.strImm64(5, 15, @intCast(@offsetOf(Frame, "bp") / 8));
    e.strImm64(10, 15, @intCast(@offsetOf(Frame, "ret_sp") / 8));
    e.ldrImm64(0, 7, @intCast(@offsetOf(Object, "env") / 8));
    e.strImm64(0, 15, @intCast(@offsetOf(Frame, "env") / 8));
    e.strImm64(7, 15, @intCast(@offsetOf(Frame, "func") / 8));
    e.strImm64(13, 15, @intCast(@offsetOf(Frame, "this") / 8));
    e.strImm64(2, 15, @intCast(@offsetOf(Frame, "new_target") / 8));
    e.strImm64(5, 15, @intCast(@offsetOf(Frame, "args") / 8));
    e.strImm32(4, 15, @intCast(@offsetOf(Frame, "argc") / 4));
    e.strbImm(31, 15, @intCast(@offsetOf(Frame, "is_entry")));
    e.strbImm(31, 15, @intCast(@offsetOf(Frame, "is_construct")));
    e.strImm64(31, 15, @intCast(@offsetOf(Frame, "co") / 8));
    e.addImm64(11, 11, 1);
    e.strImm32(11, 19, @intCast(@offsetOf(Vm, "frame_top") / 4));
    e.strImm64(14, 19, @intCast(@offsetOf(Vm, "sp") / 8));

    // Push 48-byte native frame, switch VM regs to child, and invoke fp.jit_fast_fn (x9):
    e.stpPre64(29, 30, 31, -6);
    e.addImm64(29, 31, 0);
    e.stpOffset64(20, 21, 31, 2);
    e.stpOffset64(22, 10, 31, 4);
    e.mov64(20, 15);
    e.mov64(21, 5);
    e.mov64(22, 14);
    e.blr(9);
    const b_child_err = e.len;
    e.cbnz64(1, 0);

    // Normal return: pop child frame, store return value at ret_sp[0], return ret_sp + 8:
    e.ldrImm32(2, 19, @intCast(@offsetOf(Vm, "frame_top") / 4));
    e.subImm64(2, 2, 1);
    e.strImm32(2, 19, @intCast(@offsetOf(Vm, "frame_top") / 4));
    e.ldrImm64(2, 31, 5);
    e.strImm64(0, 2, 0);
    e.addImm64(0, 2, 8);
    e.ldpOffset64(20, 21, 31, 2);
    e.ldpPost64(29, 30, 31, 6);
    e.ret();

    // Child error path: restore caller state and tail-call handleChildErr(vm, caller_sp, child_f, err_code):
    e.buf[b_child_err] |= (@as(u32, @intCast(e.len - b_child_err)) & 0x7FFFF) << 5;
    e.mov64(3, 1);
    e.mov64(0, 19);
    e.ldrImm64(1, 31, 4);
    e.mov64(2, 20);
    e.ldpOffset64(20, 21, 31, 2);
    e.ldpPost64(29, 30, 31, 6);
    e.movImm64(9, @intFromPtr(&jit_calls.handleChildErr));
    e.br(9);

    // Pre-commit fallback: tail-call jitCall(vm, caller_f, caller_sp, next_pc, argc) directly:
    const slow_idx = e.len;
    e.buf[b_not_obj] |= (@as(u32, @intCast(slow_idx - b_not_obj)) & 0x7FFFF) << 5;
    e.buf[b_not_closure] |= (@as(u32, @intCast(slow_idx - b_not_closure)) & 0x7FFFF) << 5;
    e.buf[b_no_fast] |= (@as(u32, @intCast(slow_idx - b_no_fast)) & 0x7FFFF) << 5;
    e.buf[b_frame_ovf] |= (@as(u32, @intCast(slow_idx - b_frame_ovf)) & 0x7FFFF) << 5;
    e.buf[b_nat_ovf] |= (@as(u32, @intCast(slow_idx - b_nat_ovf)) & 0x7FFFF) << 5;
    e.buf[b_js_ovf] |= (@as(u32, @intCast(slow_idx - b_js_ovf)) & 0x7FFFF) << 5;
    e.buf[b_budget] |= (@as(u32, @intCast(slow_idx - b_budget)) & 0x7FFFF) << 5;
    e.buf[b_prim_this] |= (@as(u32, @intCast(slow_idx - b_prim_this)) & 0x7FFFF) << 5;
    e.mov64(0, 19);
    e.mov64(1, 20);
    e.mov64(2, 22);
    e.movImm64(9, @intFromPtr(&jit.jitCall));
    e.br(9);

    if (e.overflow) return null;
    const jfn = jit.global_jit_pool.allocCode(std.heap.page_allocator, stub_words_buf[0..e.len]) orelse return null;
    cached_stub = @ptrCast(jfn);
    return cached_stub;
}
