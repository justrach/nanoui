//! Inline ARM64 arithmetic, comparison, unary, and peephole-fused super-instruction
//! emitters for the Baseline JIT (`add`, `sub`, `mul`, `div`, bitwise, relational,
//! equality, and operand/branch fusions).

const std = @import("std");
const bc = @import("bytecode.zig");
const Op = bc.Op;
const Value = @import("value.zig").Value;
const Frame = @import("frame.zig").Frame;
const objmod = @import("object.zig");
const Object = objmod.Object;
const JSString = @import("string.zig").JSString;
const jit = @import("jit.zig");
const enc = @import("jit_arm64_enc.zig");
const Emitter = enc.Emitter;
const Cond = enc.Cond;

pub const BranchTarget = struct {
    word: u32,
    on_true: bool,
    pass: u1,
};

inline fn branchToTarget(e: *Emitter, cond: Cond, bt: BranchTarget) void {
    const rel: i32 = if (bt.pass == 1) @as(i32, @intCast(bt.word)) - @as(i32, @intCast(e.len)) else 0;
    e.bCond(cond, rel);
}

inline fn jumpToTarget(e: *Emitter, bt: BranchTarget) void {
    const rel: i32 = if (bt.pass == 1) @as(i32, @intCast(bt.word)) - @as(i32, @intCast(e.len)) else 0;
    e.bImm(rel);
}

fn emitLoadTwoNumsToD0D1(e: *Emitter, b_slow_a: *u32, b_slow_b: *u32) void {
    e.cmpReg64(0, 25);
    const b_a_f64 = e.len;
    e.bCond(.lo, 0);
    e.eorReg64(2, 0, 25);
    e.lsrImm64(2, 2, 48);
    b_slow_a.* = e.len;
    e.cbnz64(2, 0);
    e.scvtf32(0, 0);
    const b_a_done = e.len;
    e.bImm(0);
    e.buf[b_a_f64] |= (@as(u32, @intCast(e.len - b_a_f64)) & 0x7FFFF) << 5;
    e.fmovToD(0, 0);
    e.buf[b_a_done] |= @as(u32, @intCast(e.len - b_a_done)) & 0x03FF_FFFF;

    e.cmpReg64(1, 25);
    const b_b_f64 = e.len;
    e.bCond(.lo, 0);
    e.eorReg64(3, 1, 25);
    e.lsrImm64(3, 3, 48);
    b_slow_b.* = e.len;
    e.cbnz64(3, 0);
    e.scvtf32(1, 1);
    const b_b_done = e.len;
    e.bImm(0);
    e.buf[b_b_f64] |= (@as(u32, @intCast(e.len - b_b_f64)) & 0x7FFFF) << 5;
    e.fmovToD(1, 1);
    e.buf[b_b_done] |= @as(u32, @intCast(e.len - b_b_done)) & 0x03FF_FFFF;
}

/// Boxes `d0` into `x0` matching `Value.fromNumber(d0)` (`FJCVTZS` exact non-`-0` `i32` -> `T_INT`, NaN -> `Value.nan`).
pub fn emitBoxNumberFromD0(e: *Emitter) void {
    e.fjcvtzs(2, 0);
    const b_not_int = e.len;
    e.bCond(.ne, 0);
    e.orrReg64(0, 2, 25);
    const b_done = e.len;
    e.bImm(0);
    e.buf[b_not_int] |= (@as(u32, @intCast(e.len - b_not_int)) & 0x7FFFF) << 5;
    e.fcmpD(0, 0);
    e.fmovFromD(0, 0);
    const b_not_nan = e.len;
    e.bCond(.vc, 0);
    e.movz(0, 0x7FF8, 3);
    e.buf[b_done] |= @as(u32, @intCast(e.len - b_done)) & 0x03FF_FFFF;
    e.buf[b_not_nan] |= (@as(u32, @intCast(e.len - b_not_nan)) & 0x7FFFF) << 5;
}

pub fn emitBinaryRegs(e: *Emitter, op: Op, pc_addr: usize, epilogue_idx: u32, pass: u1, on_stack: bool) void {
    if (op == .div) {
        var b_sa: u32 = 0;
        var b_sb: u32 = 0;
        emitLoadTwoNumsToD0D1(e, &b_sa, &b_sb);
        e.fdivD(0, 0, 1);
        emitBoxNumberFromD0(e);
        const b_done = e.len;
        e.bImm(0);
        const slow_idx = e.len;
        e.buf[b_sa] |= (@as(u32, @intCast(slow_idx - b_sa)) & 0x7FFFF) << 5;
        e.buf[b_sb] |= (@as(u32, @intCast(slow_idx - b_sb)) & 0x7FFFF) << 5;
        if (!on_stack) {
            e.stpOffset64(0, 1, 22, 0);
            e.addImm64(22, 22, 16);
        }
        e.callHelper5(@intFromPtr(&jit.jitBinaryOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
        if (!on_stack) e.subImm64(22, 22, 16);
        e.buf[b_done] |= @as(u32, @intCast(e.len - b_done)) & 0x03FF_FFFF;
        return;
    }

    e.eorReg64(2, 0, 25);
    e.eorReg64(3, 1, 25);
    e.orrReg64(2, 2, 3);
    e.lsrImm64(2, 2, 48);
    const b_not_both_int = e.len;
    e.cbnz64(2, 0);

    const int_op_idx = e.len;
    var b_ovf: ?u32 = null;
    var b_mul_z: ?u32 = null;
    switch (op) {
        .add => {
            e.addsReg32(2, 0, 1);
            b_ovf = e.len;
            e.bCond(.vs, 0);
            e.orrReg64(0, 2, 25);
        },
        .sub => {
            e.subsReg32(2, 0, 1);
            b_ovf = e.len;
            e.bCond(.vs, 0);
            e.orrReg64(0, 2, 25);
        },
        .mul => {
            e.smull64(2, 0, 1);
            b_mul_z = e.len;
            e.cbz64(2, 0);
            e.sxtw64(3, 2);
            e.cmpReg64(2, 3);
            b_ovf = e.len;
            e.bCond(.ne, 0);
            e.ubfm64(0, 2, 0, 31);
            e.orrReg64(0, 0, 25);
        },
        .bit_and => { e.andReg32(0, 0, 1); e.orrReg64(0, 0, 25); },
        .bit_or => { e.orrReg32(0, 0, 1); e.orrReg64(0, 0, 25); },
        .bit_xor => { e.eorReg32(0, 0, 1); e.orrReg64(0, 0, 25); },
        .shl => { e.lslvReg32(0, 0, 1); e.orrReg64(0, 0, 25); },
        .sar => { e.asrvReg32(0, 0, 1); e.orrReg64(0, 0, 25); },
        .shr => {
            e.lsrvReg32(0, 0, 1);
            b_ovf = e.len;
            e.tbnz32(0, 31, 0);
            e.orrReg64(0, 0, 25);
        },
        else => unreachable,
    }
    const b_done1 = e.len;
    e.bImm(0);

    if (op == .add or op == .sub or op == .mul) {
        var b_done_z: ?u32 = null;
        var b_done_nz: ?u32 = null;
        if (op == .mul) {
            e.buf[b_mul_z.?] |= (@as(u32, @intCast(e.len - b_mul_z.?)) & 0x7FFFF) << 5;
            e.orrReg32(3, 0, 1);
            const b_neg0 = e.len;
            e.tbnz32(3, 31, 0);
            e.mov64(0, 25);
            b_done_z = e.len;
            e.bImm(0);
            e.buf[b_neg0] |= (@as(u32, @intCast(e.len - b_neg0)) & 0x3FFF) << 5;
            e.movz(0, 0x8000, 3);
            b_done_nz = e.len;
            e.bImm(0);
        }

        e.buf[b_ovf.?] |= (@as(u32, @intCast(e.len - b_ovf.?)) & 0x7FFFF) << 5;
        if (op == .mul) {
            e.scvtf64(0, 2);
        } else {
            e.sxtw64(0, 0);
            e.sxtw64(1, 1);
            if (op == .add) e.addReg64(0, 0, 1) else e.subReg64(0, 0, 1);
            e.scvtf64(0, 0);
        }
        e.fmovFromD(0, 0);
        const b_ovf_done = e.len;
        e.bImm(0);

        e.buf[b_not_both_int] |= (@as(u32, @intCast(e.len - b_not_both_int)) & 0x7FFFF) << 5;
        var b_sa: u32 = 0;
        var b_sb: u32 = 0;
        emitLoadTwoNumsToD0D1(e, &b_sa, &b_sb);
        switch (op) {
            .add => e.faddD(0, 0, 1),
            .sub => e.fsubD(0, 0, 1),
            .mul => e.fmulD(0, 0, 1),
            else => unreachable,
        }
        emitBoxNumberFromD0(e);
        const b_fp_done = e.len;
        e.bImm(0);

        const slow_idx = e.len;
        e.buf[b_sa] |= (@as(u32, @intCast(slow_idx - b_sa)) & 0x7FFFF) << 5;
        e.buf[b_sb] |= (@as(u32, @intCast(slow_idx - b_sb)) & 0x7FFFF) << 5;
        if (!on_stack) {
            e.stpOffset64(0, 1, 22, 0);
            e.addImm64(22, 22, 16);
        }
        e.callHelper5(@intFromPtr(&jit.jitBinaryOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
        if (!on_stack) e.subImm64(22, 22, 16);
        e.buf[b_ovf_done] |= @as(u32, @intCast(e.len - b_ovf_done)) & 0x03FF_FFFF;
        e.buf[b_fp_done] |= @as(u32, @intCast(e.len - b_fp_done)) & 0x03FF_FFFF;
        if (b_done_z) |bz| e.buf[bz] |= @as(u32, @intCast(e.len - bz)) & 0x03FF_FFFF;
        if (b_done_nz) |bnz| e.buf[bnz] |= @as(u32, @intCast(e.len - bnz)) & 0x03FF_FFFF;
    } else {
        e.buf[b_not_both_int] |= (@as(u32, @intCast(e.len - b_not_both_int)) & 0x7FFFF) << 5;
        var b_sa: u32 = 0;
        var b_sb: u32 = 0;
        emitLoadTwoNumsToD0D1(e, &b_sa, &b_sb);
        e.fjcvtzs(0, 0);
        e.fjcvtzs(1, 1);
        e.bImm(@as(i32, @intCast(int_op_idx)) - @as(i32, @intCast(e.len)));

        const slow_idx = e.len;
        e.buf[b_sa] |= (@as(u32, @intCast(slow_idx - b_sa)) & 0x7FFFF) << 5;
        e.buf[b_sb] |= (@as(u32, @intCast(slow_idx - b_sb)) & 0x7FFFF) << 5;
        if (b_ovf) |bo| e.buf[bo] |= (@as(u32, @intCast(slow_idx - bo)) & 0x3FFF) << 5;
        if (!on_stack) {
            e.stpOffset64(0, 1, 22, 0);
            e.addImm64(22, 22, 16);
        }
        e.callHelper5(@intFromPtr(&jit.jitBinaryOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
        if (!on_stack) e.subImm64(22, 22, 16);
    }
    e.buf[b_done1] |= @as(u32, @intCast(e.len - b_done1)) & 0x03FF_FFFF;
}

pub fn emitBinaryOp(e: *Emitter, op: Op, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.ldur64(0, 22, -16);
    e.ldur64(1, 22, -8);
    emitBinaryRegs(e, op, pc_addr, epilogue_idx, pass, true);
    e.stur64(0, 22, -16);
    e.subImm64(22, 22, 8);
}

pub fn emitCompareRegs(e: *Emitter, op: Op, pc_addr: usize, epilogue_idx: u32, pass: u1, on_stack: bool, bt: ?BranchTarget) void {
    if (op == .seq or op == .sne) {
        const want_eq = if (bt) |b| ((op == .seq) == b.on_true) else (op == .seq);
        e.cmpReg64(0, 25);
        const b_dbl1 = e.len;
        e.bCond(.lo, 0);
        e.cmpReg64(1, 25);
        const b_dbl2 = e.len;
        e.bCond(.lo, 0);
        e.cmpReg64(0, 1);
        const b_eq1 = e.len;
        e.bCond(.eq, 0);
        e.eorReg64(2, 0, 1);
        e.lsrImm64(2, 2, 48);
        const b_ne1 = e.len;
        e.cbnz64(2, 0);
        e.subReg64(2, 0, 25);
        e.lsrImm64(2, 2, 48);
        e.cmpImm64(2, 3);
        const b_ne2 = e.len;
        e.bCond(.lo, 0);
        const b_not_str = e.len;
        e.bCond(.hi, 0);
        e.ubfm64(2, 0, 0, 47);
        e.ubfm64(3, 1, 0, 47);
        e.ldrImm32(4, 2, @intCast(@offsetOf(JSString, "byte_len") / 4));
        e.ldrImm32(5, 3, @intCast(@offsetOf(JSString, "byte_len") / 4));
        e.cmpReg32(4, 5);
        const b_ne3 = e.len;
        e.bCond(.ne, 0);
        e.ldrImm64(4, 2, @intCast(@offsetOf(JSString, "key") / 8));
        const b_slow3 = e.len;
        e.cbz64(4, 0);
        e.ldrImm64(5, 3, @intCast(@offsetOf(JSString, "key") / 8));
        const b_slow4 = e.len;
        e.cbz64(5, 0);
        e.cmpReg64(4, 5);
        const b_eq2 = e.len;
        e.bCond(.eq, 0);
        const b_ne4 = e.len;
        e.bImm(0);

        e.buf[b_not_str] |= (@as(u32, @intCast(e.len - b_not_str)) & 0x7FFFF) << 5;
        e.cmpImm64(2, 4);
        const b_slow5 = e.len;
        e.bCond(.ne, 0);
        const b_ne5 = e.len;
        e.bImm(0);

        const dbl_idx = e.len;
        e.buf[b_dbl1] |= (@as(u32, @intCast(dbl_idx - b_dbl1)) & 0x7FFFF) << 5;
        e.buf[b_dbl2] |= (@as(u32, @intCast(dbl_idx - b_dbl2)) & 0x7FFFF) << 5;
        var b_not_num_a: u32 = 0;
        var b_not_num_b: u32 = 0;
        emitLoadTwoNumsToD0D1(e, &b_not_num_a, &b_not_num_b);
        e.fcmpD(0, 1);
        const b_fp_eq = e.len;
        e.bCond(.eq, 0);

        const ne_idx = e.len;
        e.buf[b_ne1] |= (@as(u32, @intCast(ne_idx - b_ne1)) & 0x7FFFF) << 5;
        e.buf[b_ne2] |= (@as(u32, @intCast(ne_idx - b_ne2)) & 0x7FFFF) << 5;
        e.buf[b_ne3] |= (@as(u32, @intCast(ne_idx - b_ne3)) & 0x7FFFF) << 5;
        e.buf[b_ne4] |= @as(u32, @intCast(ne_idx - b_ne4)) & 0x03FF_FFFF;
        e.buf[b_ne5] |= @as(u32, @intCast(ne_idx - b_ne5)) & 0x03FF_FFFF;
        e.buf[b_not_num_a] |= (@as(u32, @intCast(ne_idx - b_not_num_a)) & 0x7FFFF) << 5;
        e.buf[b_not_num_b] |= (@as(u32, @intCast(ne_idx - b_not_num_b)) & 0x7FFFF) << 5;
        if (bt) |b| {
            if (!want_eq) jumpToTarget(e, b);
        } else {
            if (want_eq) e.mov64(0, 26) else e.addImm64(0, 26, 1);
        }
        const b_done1 = e.len;
        e.bImm(0);

        const eq_idx = e.len;
        e.buf[b_eq1] |= (@as(u32, @intCast(eq_idx - b_eq1)) & 0x7FFFF) << 5;
        e.buf[b_eq2] |= (@as(u32, @intCast(eq_idx - b_eq2)) & 0x7FFFF) << 5;
        e.buf[b_fp_eq] |= (@as(u32, @intCast(eq_idx - b_fp_eq)) & 0x7FFFF) << 5;
        if (bt) |b| {
            if (want_eq) jumpToTarget(e, b);
        } else {
            if (want_eq) e.addImm64(0, 26, 1) else e.mov64(0, 26);
        }
        const b_done2 = e.len;
        e.bImm(0);

        const slow_idx = e.len;
        e.buf[b_slow3] |= (@as(u32, @intCast(slow_idx - b_slow3)) & 0x7FFFF) << 5;
        e.buf[b_slow4] |= (@as(u32, @intCast(slow_idx - b_slow4)) & 0x7FFFF) << 5;
        e.buf[b_slow5] |= (@as(u32, @intCast(slow_idx - b_slow5)) & 0x7FFFF) << 5;
        if (!on_stack) {
            e.stpOffset64(0, 1, 22, 0);
            e.addImm64(22, 22, 16);
        }
        e.callHelper5(@intFromPtr(&jit.jitCompareOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
        if (!on_stack) e.subImm64(22, 22, 16);
        if (bt) |b| {
            e.cmpReg64(0, 26);
            branchToTarget(e, if (b.on_true) .ne else .eq, b);
        }
        e.buf[b_done1] |= @as(u32, @intCast(e.len - b_done1)) & 0x03FF_FFFF;
        e.buf[b_done2] |= @as(u32, @intCast(e.len - b_done2)) & 0x03FF_FFFF;
        return;
    }

    if (op == .eq or op == .ne) {
        const want_eq = if (bt) |b| ((op == .eq) == b.on_true) else (op == .eq);
        e.eorReg64(2, 0, 25);
        e.eorReg64(3, 1, 25);
        e.orrReg64(2, 2, 3);
        e.lsrImm64(2, 2, 48);
        const b_not_int = e.len;
        e.cbnz64(2, 0);
        e.cmpReg32(0, 1);
        if (bt) |b| {
            branchToTarget(e, if (want_eq) .eq else .ne, b);
        } else {
            e.cset64(0, if (want_eq) .eq else .ne);
            e.orrReg64(0, 0, 26);
        }
        const b_done_int = e.len;
        e.bImm(0);

        e.buf[b_not_int] |= (@as(u32, @intCast(e.len - b_not_int)) & 0x7FFFF) << 5;
        e.eorReg64(3, 1, 26);
        e.lsrImm64(3, 3, 1);
        e.cmpImm64(3, 1);
        const b_not_b_nullish = e.len;
        e.bCond(.ne, 0);
        e.eorReg64(2, 0, 26);
        e.lsrImm64(2, 2, 1);
        e.cmpImm64(2, 1);
        const b_eq_null = e.len;
        e.bCond(.eq, 0);
        e.eorReg64(2, 0, 27);
        e.lsrImm64(3, 2, 48);
        const b_ne_null1 = e.len;
        e.cbnz64(3, 0);
        e.ldrbImm(3, 2, @intCast(@offsetOf(Object, "flags")));
        const b_ne_null2 = e.len;
        e.tbz32(3, @bitOffsetOf(objmod.Flags, "html_dda"), 0);
        const b_eq_dda = e.len;
        e.bImm(0);

        e.buf[b_not_b_nullish] |= (@as(u32, @intCast(e.len - b_not_b_nullish)) & 0x7FFFF) << 5;
        e.cmpReg64(0, 25);
        const b_slow1 = e.len;
        e.bCond(.lo, 0);
        e.cmpReg64(0, 1);
        const b_slow2 = e.len;
        e.bCond(.ne, 0);

        const eq_l_idx = e.len;
        e.buf[b_eq_null] |= (@as(u32, @intCast(eq_l_idx - b_eq_null)) & 0x7FFFF) << 5;
        e.buf[b_eq_dda] |= @as(u32, @intCast(eq_l_idx - b_eq_dda)) & 0x03FF_FFFF;
        if (bt) |b| {
            if (want_eq) jumpToTarget(e, b);
        } else {
            if (want_eq) e.addImm64(0, 26, 1) else e.mov64(0, 26);
        }
        const b_done_eq = e.len;
        e.bImm(0);

        const ne_l_idx = e.len;
        e.buf[b_ne_null1] |= (@as(u32, @intCast(ne_l_idx - b_ne_null1)) & 0x7FFFF) << 5;
        e.buf[b_ne_null2] |= (@as(u32, @intCast(ne_l_idx - b_ne_null2)) & 0x3FFF) << 5;
        if (bt) |b| {
            if (!want_eq) jumpToTarget(e, b);
        } else {
            if (want_eq) e.mov64(0, 26) else e.addImm64(0, 26, 1);
        }
        const b_done_ne = e.len;
        e.bImm(0);

        const slow_l_idx = e.len;
        e.buf[b_slow1] |= (@as(u32, @intCast(slow_l_idx - b_slow1)) & 0x7FFFF) << 5;
        e.buf[b_slow2] |= (@as(u32, @intCast(slow_l_idx - b_slow2)) & 0x7FFFF) << 5;
        if (!on_stack) {
            e.stpOffset64(0, 1, 22, 0);
            e.addImm64(22, 22, 16);
        }
        e.callHelper5(@intFromPtr(&jit.jitCompareOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
        if (!on_stack) e.subImm64(22, 22, 16);
        if (bt) |b| {
            e.cmpReg64(0, 26);
            branchToTarget(e, if (b.on_true) .ne else .eq, b);
        }
        e.buf[b_done_int] |= @as(u32, @intCast(e.len - b_done_int)) & 0x03FF_FFFF;
        e.buf[b_done_eq] |= @as(u32, @intCast(e.len - b_done_eq)) & 0x03FF_FFFF;
        e.buf[b_done_ne] |= @as(u32, @intCast(e.len - b_done_ne)) & 0x03FF_FFFF;
        return;
    }

    const int_true: Cond = switch (op) { .lt => .lt, .le => .le, .gt => .gt, else => .ge };
    const int_false: Cond = @enumFromInt(@intFromEnum(int_true) ^ 1);
    const fp_true: Cond = switch (op) { .lt => .mi, .le => .ls, .gt => .gt, else => .ge };
    const fp_false: Cond = @enumFromInt(@intFromEnum(fp_true) ^ 1);

    e.eorReg64(2, 0, 25);
    e.eorReg64(3, 1, 25);
    e.orrReg64(2, 2, 3);
    e.lsrImm64(2, 2, 48);
    const b_not_int = e.len;
    e.cbnz64(2, 0);
    e.cmpReg32(0, 1);
    if (bt) |b| {
        branchToTarget(e, if (b.on_true) int_true else int_false, b);
    } else {
        e.cset64(0, int_true);
        e.orrReg64(0, 0, 26);
    }
    const b_done_int = e.len;
    e.bImm(0);

    e.buf[b_not_int] |= (@as(u32, @intCast(e.len - b_not_int)) & 0x7FFFF) << 5;
    var b_sa: u32 = 0;
    var b_sb: u32 = 0;
    emitLoadTwoNumsToD0D1(e, &b_sa, &b_sb);
    e.fcmpD(0, 1);
    if (bt) |b| {
        branchToTarget(e, if (b.on_true) fp_true else fp_false, b);
    } else {
        e.cset64(0, fp_true);
        e.orrReg64(0, 0, 26);
    }
    const b_done_fp = e.len;
    e.bImm(0);

    const slow_idx = e.len;
    e.buf[b_sa] |= (@as(u32, @intCast(slow_idx - b_sa)) & 0x7FFFF) << 5;
    e.buf[b_sb] |= (@as(u32, @intCast(slow_idx - b_sb)) & 0x7FFFF) << 5;
    if (!on_stack) {
        e.stpOffset64(0, 1, 22, 0);
        e.addImm64(22, 22, 16);
    }
    e.callHelper5(@intFromPtr(&jit.jitCompareOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
    if (!on_stack) e.subImm64(22, 22, 16);
    if (bt) |b| {
        e.cmpReg64(0, 26);
        branchToTarget(e, if (b.on_true) .ne else .eq, b);
    }
    e.buf[b_done_int] |= @as(u32, @intCast(e.len - b_done_int)) & 0x03FF_FFFF;
    e.buf[b_done_fp] |= @as(u32, @intCast(e.len - b_done_fp)) & 0x03FF_FFFF;
}

pub fn emitCompareOp(e: *Emitter, op: Op, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.ldur64(0, 22, -16);
    e.ldur64(1, 22, -8);
    emitCompareRegs(e, op, pc_addr, epilogue_idx, pass, true, null);
    e.stur64(0, 22, -16);
    e.subImm64(22, 22, 8);
}

pub fn emitUnaryFast(e: *Emitter, op: Op, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.ldur64(0, 22, -8);
    switch (op) {
        .bit_not => {
            e.eorReg64(2, 0, 25);
            e.lsrImm64(2, 2, 48);
            const b_slow = e.len;
            e.cbnz64(2, 0);
            e.mvn32(0, 0);
            e.orrReg64(0, 0, 25);
            e.stur64(0, 22, -8);
            const b_done = e.len;
            e.bImm(0);
            e.buf[b_slow] |= (@as(u32, @intCast(e.len - b_slow)) & 0x7FFFF) << 5;
            e.callHelper5(@intFromPtr(&jit.jitSlowOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
            e.mov64(22, 0);
            e.buf[b_done] |= @as(u32, @intCast(e.len - b_done)) & 0x03FF_FFFF;
        },
        .neg => {
            e.eorReg64(2, 0, 25);
            e.lsrImm64(2, 2, 48);
            const b_not_int = e.len;
            e.cbnz64(2, 0);
            const b_zero = e.len;
            e.cbz32(0, 0);
            e.subsReg32(2, 31, 0);
            const b_ovf = e.len;
            e.bCond(.vs, 0);
            e.orrReg64(0, 2, 25);
            const b_done1 = e.len;
            e.bImm(0);

            e.buf[b_zero] |= (@as(u32, @intCast(e.len - b_zero)) & 0x7FFFF) << 5;
            e.movz(0, 0x8000, 3);
            const b_done2 = e.len;
            e.bImm(0);

            e.buf[b_ovf] |= (@as(u32, @intCast(e.len - b_ovf)) & 0x7FFFF) << 5;
            e.movz(0, 0x41E0, 3);
            const b_done3 = e.len;
            e.bImm(0);

            e.buf[b_not_int] |= (@as(u32, @intCast(e.len - b_not_int)) & 0x7FFFF) << 5;
            e.cmpReg64(0, 25);
            const b_slow = e.len;
            e.bCond(.hs, 0);
            e.fmovToD(0, 0);
            e.fnegD(0, 0);
            emitBoxNumberFromD0(e);
            const b_done4 = e.len;
            e.bImm(0);

            e.buf[b_slow] |= (@as(u32, @intCast(e.len - b_slow)) & 0x7FFFF) << 5;
            e.callHelper5(@intFromPtr(&jit.jitSlowOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
            e.mov64(22, 0);
            const b_end = e.len;
            e.bImm(0);

            const store_idx = e.len;
            e.buf[b_done1] |= @as(u32, @intCast(store_idx - b_done1)) & 0x03FF_FFFF;
            e.buf[b_done2] |= @as(u32, @intCast(store_idx - b_done2)) & 0x03FF_FFFF;
            e.buf[b_done3] |= @as(u32, @intCast(store_idx - b_done3)) & 0x03FF_FFFF;
            e.buf[b_done4] |= @as(u32, @intCast(store_idx - b_done4)) & 0x03FF_FFFF;
            e.stur64(0, 22, -8);
            e.buf[b_end] |= @as(u32, @intCast(e.len - b_end)) & 0x03FF_FFFF;
        },
        .to_propkey => {
            e.subReg64(2, 0, 25);
            e.lsrImm64(2, 2, 48);
            const b_int = e.len;
            e.cbz64(2, 0);
            e.subImm64(3, 2, 3);
            e.cmpImm64(3, 1);
            const b_str_sym = e.len;
            e.bCond(.ls, 0);
            e.callHelper5(@intFromPtr(&jit.jitSlowOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
            e.mov64(22, 0);
            e.buf[b_int] |= (@as(u32, @intCast(e.len - b_int)) & 0x7FFFF) << 5;
            e.buf[b_str_sym] |= (@as(u32, @intCast(e.len - b_str_sym)) & 0x7FFFF) << 5;
        },
        else => {
            e.eorReg64(2, 0, 25);
            e.lsrImm64(2, 2, 48);
            const b_slow1 = e.len;
            e.cbnz64(2, 0);
            if (op == .inc) e.addsImm32(0, 0, 1) else e.subsImm32(0, 0, 1);
            const b_slow2 = e.len;
            e.bCond(.vs, 0);
            e.orrReg64(0, 0, 25);
            const b_done = e.len;
            e.bImm(0);
            const slow_idx = e.len;
            e.buf[b_slow1] |= (@as(u32, @intCast(slow_idx - b_slow1)) & 0x7FFFF) << 5;
            e.buf[b_slow2] |= (@as(u32, @intCast(slow_idx - b_slow2)) & 0x7FFFF) << 5;
            e.callHelper5(@intFromPtr(&jit.jitUnaryOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
            e.buf[b_done] |= @as(u32, @intCast(e.len - b_done)) & 0x03FF_FFFF;
            e.stur64(0, 22, -8);
        },
    }
}
