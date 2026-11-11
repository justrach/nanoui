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
const Value = @import("value.zig").Value;
const b_fn = @import("b_function.zig");
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
    std.debug.assert(@offsetOf(objmod.BoundData, "target") % 8 == 0);
    std.debug.assert(@offsetOf(objmod.BoundData, "this") % 8 == 0);
    std.debug.assert(@offsetOf(objmod.NativeData, "func") % 8 == 0);
    std.debug.assert(@offsetOf(Vm, "args_strict_shape") % 8 == 0);
    std.debug.assert(@offsetOf(Vm, "args_sloppy_shape") % 8 == 0);
}

var cached_stub: ?*const anyopaque = null;
pub var stub_words_buf: [enc.max_inst_words]u32 = undefined;

/// Builds (once per process) and returns the executable `jitFastCallStub` address.
/// Entry contract from caller JIT code:
///   `x19 = vm`, `x20 = caller_f`, `x21 = caller_bp`, `x22 = caller_sp`,
///   `x25..x27 = NaN-box tag constants`, `x3 = next_pc`, `x4 = argc`.
/// Returns `(x0 = new_sp, x1 = err)` with `x19, x20, x21, x23..x27` preserved.
pub fn getOrBuildStub() ?*const anyopaque {
    if (comptime !jit.enabled) return null;
    if (cached_stub) |s| return s;
    var dummy_val = [1]Value{Value.undefined};
    const dummy_b = objmod.BoundData{ .target = @ptrFromInt(8), .this = .{ .bits = 16 }, .args = &dummy_val };
    const b_words: *const [@sizeOf(objmod.BoundData) / 8]usize = @ptrCast(&dummy_b);
    var bound_args_ptr_idx: u12 = 0;
    var bound_args_len_idx: u12 = 0;
    for (b_words, 0..) |w, idx| {
        if (w == @intFromPtr(&dummy_val)) bound_args_ptr_idx = @intCast(idx);
        if (w == 1) bound_args_len_idx = @intCast(idx);
    }
    var e = Emitter{ .buf = &stub_words_buf };

    // x17 = orig_argc; x16 = args_ptr = caller_sp - argc * 8; x5 = bp; x14 = scratch_sp; x15 = unwrap_budget
    e.mov64(17, 4);
    e.subRegLsl64(16, 22, 4, 3);
    e.mov64(5, 16);
    e.mov64(14, 22);
    e.movz(15, 8, 0);
    e.ldur64(6, 16, -8);
    e.subImm64(10, 16, 16);
    e.ldrImm64(13, 10, 0);

    // Check callee is T_OBJECT (`check_val`), unwrapping `.bound`, `fnCall`, and `fnApply`:
    const check_val = e.len;
    e.eorReg64(7, 6, 27);
    e.lsrImm64(0, 7, 48);
    const b_not_obj = e.len;
    e.cbnz64(0, 0);

    const check_obj = e.len;
    e.ldrbImm(0, 7, @intCast(@offsetOf(Object, "class")));
    e.cmpImm64(0, @intFromEnum(objmod.Class.closure));
    const b_is_closure = e.len;
    e.bCond(.eq, 0);
    e.cmpImm64(0, @intFromEnum(objmod.Class.bound));
    const b_not_bound = e.len;
    e.bCond(.ne, 0);
    e.ldrImm64(0, 7, @intCast(@offsetOf(Object, "payload") / 8));
    e.ldrImm64(1, 0, bound_args_len_idx);
    const b_has_bargs = e.len;
    e.cbnz64(1, 0);
    e.subsImm32(15, 15, 1);
    const b_depth_bound0 = e.len;
    e.bCond(.lt, 0);
    e.ldrImm64(13, 0, @intCast(@offsetOf(objmod.BoundData, "this") / 8));
    e.ldrImm64(7, 0, @intCast(@offsetOf(objmod.BoundData, "target") / 8));
    e.bImm(@as(i32, @intCast(check_obj)) - @as(i32, @intCast(e.len)));

    // Bound function with `1 <= b.args.len <= 16` and `b.args.len + argc <= 32`:
    e.buf[b_has_bargs] |= (@as(u32, @intCast(e.len - b_has_bargs)) & 0x7FFFF) << 5;
    e.subsImm32(15, 15, 1);
    const b_depth_bound1 = e.len;
    e.bCond(.lt, 0);
    e.cmpImm64(1, 16);
    const b_bound_big1 = e.len;
    e.bCond(.hi, 0);
    e.addReg64(2, 1, 4);
    e.cmpImm64(2, 32);
    const b_bound_big2 = e.len;
    e.bCond(.hi, 0);
    e.addRegLsl64(8, 14, 2, 3);
    e.ldrImm64(9, 19, @intCast(@offsetOf(Vm, "stack_end") / 8));
    e.cmpReg64(8, 9);
    const b_bound_ovf = e.len;
    e.bCond(.hi, 0);
    e.ldrImm64(9, 0, bound_args_ptr_idx);
    e.movz(11, 0, 0);
    const bcopy1 = e.len;
    e.cmpReg64(11, 1);
    const b_bcopy1_done = e.len;
    e.bCond(.hs, 0);
    e.ldrRegScaled64(12, 9, 11);
    e.strRegScaled64(12, 14, 11);
    e.addImm64(11, 11, 1);
    e.bImm(@as(i32, @intCast(bcopy1)) - @as(i32, @intCast(e.len)));
    e.buf[b_bcopy1_done] |= (@as(u32, @intCast(e.len - b_bcopy1_done)) & 0x7FFFF) << 5;
    e.addRegLsl64(9, 14, 1, 3);
    e.movz(11, 0, 0);
    const bcopy2 = e.len;
    e.cmpReg32(11, 4);
    const b_bcopy2_done = e.len;
    e.bCond(.hs, 0);
    e.ldrRegScaled64(12, 16, 11);
    e.strRegScaled64(12, 9, 11);
    e.addImm64(11, 11, 1);
    e.bImm(@as(i32, @intCast(bcopy2)) - @as(i32, @intCast(e.len)));
    e.buf[b_bcopy2_done] |= (@as(u32, @intCast(e.len - b_bcopy2_done)) & 0x7FFFF) << 5;
    e.mov64(16, 14);
    e.mov64(5, 14);
    e.mov64(14, 8);
    e.mov64(4, 2);
    e.ldrImm64(13, 0, @intCast(@offsetOf(objmod.BoundData, "this") / 8));
    e.ldrImm64(7, 0, @intCast(@offsetOf(objmod.BoundData, "target") / 8));
    e.bImm(@as(i32, @intCast(check_obj)) - @as(i32, @intCast(e.len)));

    e.buf[b_not_bound] |= (@as(u32, @intCast(e.len - b_not_bound)) & 0x7FFFF) << 5;
    e.cmpImm64(0, @intFromEnum(objmod.Class.native));
    const b_not_native = e.len;
    e.bCond(.ne, 0);
    e.ldrImm64(0, 7, @intCast(@offsetOf(Object, "payload") / 8));
    e.ldrImm64(0, 0, @intCast(@offsetOf(objmod.NativeData, "func") / 8));
    e.movImm64(1, @intFromPtr(&b_fn.fnCall));
    e.cmpReg64(0, 1);
    const b_not_fncall = e.len;
    e.bCond(.ne, 0);
    e.subsImm32(15, 15, 1);
    const b_depth_fncall = e.len;
    e.bCond(.lt, 0);
    e.mov64(6, 13);
    const b_zero_argc = e.len;
    e.cbz32(4, 0);
    e.ldrImm64(13, 16, 0);
    e.addImm64(16, 16, 8);
    e.mov64(5, 16);
    e.subImm64(4, 4, 1);
    e.bImm(@as(i32, @intCast(check_val)) - @as(i32, @intCast(e.len)));
    e.buf[b_zero_argc] |= (@as(u32, @intCast(e.len - b_zero_argc)) & 0x7FFFF) << 5;
    e.subImm64(13, 26, 2);
    e.bImm(@as(i32, @intCast(check_val)) - @as(i32, @intCast(e.len)));

    // Direct native tail-call (`!host_class` and `func != fnApply`) or inline `fnApply` unwrap:
    e.buf[b_not_fncall] |= (@as(u32, @intCast(e.len - b_not_fncall)) & 0x7FFFF) << 5;
    e.movImm64(1, @intFromPtr(&b_fn.fnApply));
    e.cmpReg64(0, 1);
    const b_is_fnapply = e.len;
    e.bCond(.eq, 0);
    e.ldrhImm(1, 7, @intCast(@offsetOf(Object, "flags") / 2));
    const b_host_class = e.len;
    e.tbnz32(1, @bitOffsetOf(objmod.Flags, "host_class"), 0);
    e.strImm64(3, 20, @intCast(@offsetOf(Frame, "pc") / 8));
    e.mov64(6, 4);
    e.mov64(4, 13);
    e.mov64(5, 16);
    e.mov64(3, 7);
    e.mov64(2, 10);
    e.mov64(1, 22);
    e.mov64(0, 19);
    e.movImm64(9, @intFromPtr(&jit_calls.jitCallNativeStub));
    e.br(9);

    // Inline `Function.prototype.apply(thisArg, argArray)` unwrap:
    e.buf[b_is_fnapply] |= (@as(u32, @intCast(e.len - b_is_fnapply)) & 0x7FFFF) << 5;
    e.subsImm32(15, 15, 1);
    const b_depth_apply = e.len;
    e.bCond(.lt, 0);
    e.eorReg64(7, 13, 27);
    e.lsrImm64(0, 7, 48);
    const b_apply_not_obj = e.len;
    e.cbnz64(0, 0);
    e.ldrhImm(0, 7, @intCast(@offsetOf(Object, "flags") / 2));
    const b_apply_not_call = e.len;
    e.tbz32(0, @bitOffsetOf(objmod.Flags, "callable"), 0);
    const b_apply_zero_argc = e.len;
    e.cbz32(4, 0);
    e.cmpImm64(4, 1);
    const b_apply_one_argc = e.len;
    e.bCond(.eq, 0);
    e.ldrImm64(1, 16, 1);
    e.eorReg64(0, 1, 26);
    e.lsrImm64(0, 0, 1);
    e.cmpImm64(0, 1);
    const b_apply_nullish = e.len;
    e.bCond(.eq, 0);
    e.eorReg64(2, 1, 27);
    e.lsrImm64(0, 2, 48);
    const b_apply_arr_not_obj = e.len;
    e.cbnz64(0, 0);
    e.ldrhImm(0, 2, @intCast(@offsetOf(Object, "flags") / 2));
    const b_apply_exotic = e.len;
    e.tbnz32(0, @bitOffsetOf(objmod.Flags, "exotic"), 0);
    const b_apply_sparse = e.len;
    e.tbnz32(0, @bitOffsetOf(objmod.Flags, "has_sparse"), 0);
    e.ldrImm32(8, 2, @intCast(@offsetOf(Object, "elems_len") / 4));
    e.cmpImm64(8, 32);
    const b_apply_big = e.len;
    e.bCond(.hi, 0);
    e.ldrbImm(0, 2, @intCast(@offsetOf(Object, "class")));
    e.cmpImm64(0, @intFromEnum(objmod.Class.array));
    const b_apply_not_arr = e.len;
    e.bCond(.ne, 0);
    e.ldrImm32(9, 2, @intCast(@offsetOf(Object, "arr_len") / 4));
    e.cmpReg32(8, 9);
    const b_apply_arr_mismatch = e.len;
    e.bCond(.ne, 0);
    const b_apply_to_copy = e.len;
    e.bImm(0);

    e.buf[b_apply_not_arr] |= (@as(u32, @intCast(e.len - b_apply_not_arr)) & 0x7FFFF) << 5;
    e.cmpImm64(0, @intFromEnum(objmod.Class.arguments));
    const b_apply_not_args = e.len;
    e.bCond(.ne, 0);
    e.ldrImm64(9, 2, @intCast(@offsetOf(Object, "shape") / 8));
    e.ldrImm64(11, 19, @intCast(@offsetOf(Vm, "args_strict_shape") / 8));
    e.cmpReg64(9, 11);
    const b_apply_strict_ok = e.len;
    e.bCond(.eq, 0);
    e.ldrImm64(11, 19, @intCast(@offsetOf(Vm, "args_sloppy_shape") / 8));
    e.cmpReg64(9, 11);
    const b_apply_bad_shape = e.len;
    e.bCond(.ne, 0);
    e.buf[b_apply_strict_ok] |= (@as(u32, @intCast(e.len - b_apply_strict_ok)) & 0x7FFFF) << 5;
    e.ldrImm64(9, 2, @intCast(@offsetOf(Object, "slots") / 8));
    e.ldrImm64(9, 9, 0);
    e.orrReg64(11, 8, 25);
    e.cmpReg64(9, 11);
    const b_apply_bad_len = e.len;
    e.bCond(.ne, 0);

    e.buf[b_apply_to_copy] |= @as(u32, @intCast(e.len - b_apply_to_copy)) & 0x03FF_FFFF;
    e.addRegLsl64(9, 14, 8, 3);
    e.ldrImm64(11, 19, @intCast(@offsetOf(Vm, "stack_end") / 8));
    e.cmpReg64(9, 11);
    const b_apply_ovf = e.len;
    e.bCond(.hi, 0);
    e.ldrImm64(2, 2, @intCast(@offsetOf(Object, "elems") / 8));
    e.addImm64(11, 26, 2);
    e.movz(0, 0, 0);
    const apply_loop = e.len;
    e.cmpReg32(0, 8);
    const b_apply_done = e.len;
    e.bCond(.hs, 0);
    e.ldrRegScaled64(12, 2, 0);
    e.cmpReg64(12, 11);
    const b_apply_hole = e.len;
    e.bCond(.eq, 0);
    e.strRegScaled64(12, 14, 0);
    e.addImm64(0, 0, 1);
    e.bImm(@as(i32, @intCast(apply_loop)) - @as(i32, @intCast(e.len)));
    e.buf[b_apply_done] |= (@as(u32, @intCast(e.len - b_apply_done)) & 0x7FFFF) << 5;
    e.ldrImm64(13, 16, 0);
    e.mov64(16, 14);
    e.mov64(5, 14);
    e.mov64(14, 9);
    e.mov64(4, 8);
    e.bImm(@as(i32, @intCast(check_obj)) - @as(i32, @intCast(e.len)));

    const apply_one_idx = e.len;
    e.buf[b_apply_one_argc] |= (@as(u32, @intCast(apply_one_idx - b_apply_one_argc)) & 0x7FFFF) << 5;
    e.buf[b_apply_nullish] |= (@as(u32, @intCast(apply_one_idx - b_apply_nullish)) & 0x7FFFF) << 5;
    e.ldrImm64(13, 16, 0);
    const b_apply_finish0 = e.len;
    e.bImm(0);
    e.buf[b_apply_zero_argc] |= (@as(u32, @intCast(e.len - b_apply_zero_argc)) & 0x7FFFF) << 5;
    e.subImm64(13, 26, 2);
    e.buf[b_apply_finish0] |= @as(u32, @intCast(e.len - b_apply_finish0)) & 0x03FF_FFFF;
    e.mov64(16, 14);
    e.mov64(5, 14);
    e.movz(4, 0, 0);
    e.bImm(@as(i32, @intCast(check_obj)) - @as(i32, @intCast(e.len)));

    // Load fp = callee.payload.fp and jfast = fp.jit_fast_fn:
    e.buf[b_is_closure] |= (@as(u32, @intCast(e.len - b_is_closure)) & 0x7FFFF) << 5;
    e.ldrImm64(8, 7, @intCast(@offsetOf(Object, "payload") / 8));
    e.ldrImm64(9, 8, @intCast(@offsetOf(bc.FuncProto, "jit_fast_fn") / 8));
    const b_no_fast = e.len;
    e.cbz64(9, 0);

    // Shift bp = scratch_sp (`args + argc`) when `fp.needs_args and argc > 0`:
    e.ldrbImm(0, 8, @intCast(@offsetOf(bc.FuncProto, "needs_args")));
    const b_no_shift1 = e.len;
    e.cbz32(0, 0);
    const b_no_shift2 = e.len;
    e.cbz32(4, 0);
    e.mov64(5, 14);
    e.buf[b_no_shift1] |= (@as(u32, @intCast(e.len - b_no_shift1)) & 0x7FFFF) << 5;
    e.buf[b_no_shift2] |= (@as(u32, @intCast(e.len - b_no_shift2)) & 0x7FFFF) << 5;

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

    // Handle sloppy `coerce_this` on `x13`:
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

    // Copy min(argc, nparams) words when bp != args_ptr, then fill bp[min..nlocals] with undefined:
    e.ldrhImm(0, 8, @intCast(@offsetOf(bc.FuncProto, "nparams") / 2));
    e.ldrImm32(1, 8, @intCast(@offsetOf(bc.FuncProto, "nlocals") / 4));
    e.cmpReg32(4, 0);
    e.csel32(0, 4, 0, .lo);
    e.addRegLsl64(14, 5, 1, 3);
    e.cmpReg64(5, 16);
    const b_no_copy = e.len;
    e.bCond(.eq, 0);
    e.movz(1, 0, 0);
    const copy_loop = e.len;
    e.cmpReg32(1, 0);
    const b_copy_done = e.len;
    e.bCond(.hs, 0);
    e.ldrRegScaled64(2, 16, 1);
    e.strRegScaled64(2, 5, 1);
    e.addImm64(1, 1, 1);
    e.bImm(@as(i32, @intCast(copy_loop)) - @as(i32, @intCast(e.len)));
    const after_copy = e.len;
    e.buf[b_no_copy] |= (@as(u32, @intCast(after_copy - b_no_copy)) & 0x7FFFF) << 5;
    e.buf[b_copy_done] |= (@as(u32, @intCast(after_copy - b_copy_done)) & 0x7FFFF) << 5;

    e.addRegLsl64(0, 5, 0, 3);
    e.subImm64(2, 26, 2);
    e.subImm64(1, 14, 8);
    const init_pair_loop = e.len;
    e.cmpReg64(0, 1);
    const b_init_tail = e.len;
    e.bCond(.hs, 0);
    e.stpOffset64(2, 2, 0, 0);
    e.addImm64(0, 0, 16);
    e.bImm(@as(i32, @intCast(init_pair_loop)) - @as(i32, @intCast(e.len)));
    e.buf[b_init_tail] |= (@as(u32, @intCast(e.len - b_init_tail)) & 0x7FFFF) << 5;
    e.cmpReg64(0, 14);
    const b_init_done = e.len;
    e.bCond(.hs, 0);
    e.strImm64(2, 0, 0);
    e.buf[b_init_done] |= (@as(u32, @intCast(e.len - b_init_done)) & 0x7FFFF) << 5;

    // Populate child_f = &vm.frames[frame_top] (x15) using paired stores where adjacent:
    const storePair = struct {
        inline fn emit(em: *Emitter, r1: u5, r2: u5, base: u5, comptime f1: []const u8, comptime f2: []const u8) void {
            const o1 = @offsetOf(Frame, f1);
            const o2 = @offsetOf(Frame, f2);
            if (o2 == o1 + 8 and o1 / 8 < 64) {
                em.stpOffset64(r1, r2, base, @intCast(o1 / 8));
            } else if (o1 == o2 + 8 and o2 / 8 < 64) {
                em.stpOffset64(r2, r1, base, @intCast(o2 / 8));
            } else {
                em.strImm64(r1, base, @intCast(o1 / 8));
                em.strImm64(r2, base, @intCast(o2 / 8));
            }
        }
    }.emit;
    e.ldrImm64(0, 19, @intCast(@offsetOf(Vm, "frames") / 8));
    e.movz(1, @intCast(@sizeOf(Frame)), 0);
    e.madd64(15, 11, 1, 0);
    e.ldrImm64(0, 8, @intCast(@offsetOf(bc.FuncProto, "code") / 8));
    storePair(&e, 8, 0, 15, "fp", "pc");
    storePair(&e, 5, 10, 15, "bp", "ret_sp");
    e.ldrImm64(0, 7, @intCast(@offsetOf(Object, "env") / 8));
    storePair(&e, 0, 7, 15, "env", "func");
    storePair(&e, 13, 2, 15, "this", "new_target");
    storePair(&e, 16, 31, 15, "args", "co");
    e.strImm32(4, 15, @intCast(@offsetOf(Frame, "argc") / 4));
    if (@offsetOf(Frame, "is_construct") == @offsetOf(Frame, "is_entry") + 1 and @offsetOf(Frame, "is_entry") % 2 == 0) {
        e.strhImm(31, 15, @intCast(@offsetOf(Frame, "is_entry") / 2));
    } else {
        e.strbImm(31, 15, @intCast(@offsetOf(Frame, "is_entry")));
        e.strbImm(31, 15, @intCast(@offsetOf(Frame, "is_construct")));
    }
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

    // Pre-commit fallback: restore `x4 = orig_argc` and tail-call jitCall(vm, caller_f, caller_sp, next_pc, argc):
    const slow_idx = e.len;
    e.buf[b_not_obj] |= (@as(u32, @intCast(slow_idx - b_not_obj)) & 0x7FFFF) << 5;
    e.buf[b_depth_bound0] |= (@as(u32, @intCast(slow_idx - b_depth_bound0)) & 0x7FFFF) << 5;
    e.buf[b_depth_bound1] |= (@as(u32, @intCast(slow_idx - b_depth_bound1)) & 0x7FFFF) << 5;
    e.buf[b_bound_big1] |= (@as(u32, @intCast(slow_idx - b_bound_big1)) & 0x7FFFF) << 5;
    e.buf[b_bound_big2] |= (@as(u32, @intCast(slow_idx - b_bound_big2)) & 0x7FFFF) << 5;
    e.buf[b_bound_ovf] |= (@as(u32, @intCast(slow_idx - b_bound_ovf)) & 0x7FFFF) << 5;
    e.buf[b_not_native] |= (@as(u32, @intCast(slow_idx - b_not_native)) & 0x7FFFF) << 5;
    e.buf[b_depth_fncall] |= (@as(u32, @intCast(slow_idx - b_depth_fncall)) & 0x7FFFF) << 5;
    e.buf[b_host_class] |= (@as(u32, @intCast(slow_idx - b_host_class)) & 0x3FFF) << 5;
    e.buf[b_depth_apply] |= (@as(u32, @intCast(slow_idx - b_depth_apply)) & 0x7FFFF) << 5;
    e.buf[b_apply_not_obj] |= (@as(u32, @intCast(slow_idx - b_apply_not_obj)) & 0x7FFFF) << 5;
    e.buf[b_apply_not_call] |= (@as(u32, @intCast(slow_idx - b_apply_not_call)) & 0x3FFF) << 5;
    e.buf[b_apply_arr_not_obj] |= (@as(u32, @intCast(slow_idx - b_apply_arr_not_obj)) & 0x7FFFF) << 5;
    e.buf[b_apply_exotic] |= (@as(u32, @intCast(slow_idx - b_apply_exotic)) & 0x3FFF) << 5;
    e.buf[b_apply_sparse] |= (@as(u32, @intCast(slow_idx - b_apply_sparse)) & 0x3FFF) << 5;
    e.buf[b_apply_big] |= (@as(u32, @intCast(slow_idx - b_apply_big)) & 0x7FFFF) << 5;
    e.buf[b_apply_arr_mismatch] |= (@as(u32, @intCast(slow_idx - b_apply_arr_mismatch)) & 0x7FFFF) << 5;
    e.buf[b_apply_not_args] |= (@as(u32, @intCast(slow_idx - b_apply_not_args)) & 0x7FFFF) << 5;
    e.buf[b_apply_bad_shape] |= (@as(u32, @intCast(slow_idx - b_apply_bad_shape)) & 0x7FFFF) << 5;
    e.buf[b_apply_bad_len] |= (@as(u32, @intCast(slow_idx - b_apply_bad_len)) & 0x7FFFF) << 5;
    e.buf[b_apply_ovf] |= (@as(u32, @intCast(slow_idx - b_apply_ovf)) & 0x7FFFF) << 5;
    e.buf[b_apply_hole] |= (@as(u32, @intCast(slow_idx - b_apply_hole)) & 0x7FFFF) << 5;
    e.buf[b_no_fast] |= (@as(u32, @intCast(slow_idx - b_no_fast)) & 0x7FFFF) << 5;
    e.buf[b_frame_ovf] |= (@as(u32, @intCast(slow_idx - b_frame_ovf)) & 0x7FFFF) << 5;
    e.buf[b_nat_ovf] |= (@as(u32, @intCast(slow_idx - b_nat_ovf)) & 0x7FFFF) << 5;
    e.buf[b_js_ovf] |= (@as(u32, @intCast(slow_idx - b_js_ovf)) & 0x7FFFF) << 5;
    e.buf[b_budget] |= (@as(u32, @intCast(slow_idx - b_budget)) & 0x7FFFF) << 5;
    e.buf[b_prim_this] |= (@as(u32, @intCast(slow_idx - b_prim_this)) & 0x7FFFF) << 5;
    e.mov64(4, 17);
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
