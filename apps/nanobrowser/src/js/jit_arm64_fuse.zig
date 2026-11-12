//! Peephole super-instruction fusion for the ARM64 Baseline JIT.
//! Eliminates operand-stack memory roundtrips (`[x22]`) and intermediate boolean
//! boxing/`emitTruthyTest` across basic-block-internal instruction sequences.

const std = @import("std");
const bc = @import("bytecode.zig");
const Op = bc.Op;
const Value = @import("value.zig").Value;
const Frame = @import("frame.zig").Frame;
const jit = @import("jit.zig");
const enc = @import("jit_arm64_enc.zig");
const Emitter = enc.Emitter;
const ops_emit = @import("jit_arm64_ops.zig");

inline fn u16At(p: [*]const u8) u16 { return std.mem.readInt(u16, p[0..2], .little); }
inline fn u32At(p: [*]const u8) u32 { return std.mem.readInt(u32, p[0..4], .little); }
inline fn relAt(p: [*]const u8) i32 { return std.mem.readInt(i32, p[0..4], .little); }

inline fn targetPc(pc: usize, base_off: usize, rel: i32) usize {
    const base: i64 = @intCast(pc + base_off);
    return @intCast(base + rel);
}

pub fn computeJumpTargets(code: []const u8, targets: []bool, instrLen: *const fn (Op) ?usize) bool {
    @memset(targets, false);
    var pc: usize = 0;
    while (pc < code.len) {
        const op: Op = @enumFromInt(code[pc]);
        const step = instrLen(op) orelse return false;
        if (pc + step > code.len) return false;
        switch (op) {
            .jump, .loop, .jump_false, .jump_true, .jump_false_keep, .jump_true_keep,
            .jump_notnull_keep, .jump_not_undef, .push_try, .opt_chain, .ctor_ret_check,
            .iter_next, .iter_result => {
                const dst = targetPc(pc, 5, relAt(code.ptr + pc + 1));
                if (dst > code.len) return false;
                targets[dst] = true;
            },
            .gosub => {
                const dst = targetPc(pc, 5, relAt(code.ptr + pc + 1));
                if (dst > code.len) return false;
                targets[dst] = true;
                targets[pc + 5] = true;
            },
            .for_in_next, .with_get, .with_get_call, .with_put, .with_delete => {
                const dst = targetPc(pc, 9, relAt(code.ptr + pc + 5));
                if (dst > code.len) return false;
                targets[dst] = true;
            },
            else => {},
        }
        pc += step;
    }
    return true;
}

pub fn buildCatchMap(vm: *@import("vm.zig").Vm, fp: *bc.FuncProto, pc_map: []const u32, instrLen: *const fn (Op) ?usize) void {
    if (fp.catch_map.len > 0) return;
    const code = fp.code;
    var count: usize = 0;
    var pc: usize = 0;
    while (pc < code.len) {
        const op: Op = @enumFromInt(code[pc]);
        const step = instrLen(op) orelse return;
        if (op == .push_try) count += 1;
        pc += step;
    }
    if (count == 0) return;
    const alloc = if (fp.borrowed_code) @import("script_cache.zig").permanentAlloc() else vm.gpa;
    const entries = alloc.alloc(bc.CatchEntry, count) catch return;
    var idx: usize = 0;
    pc = 0;
    while (pc < code.len) {
        const op: Op = @enumFromInt(code[pc]);
        const step = instrLen(op).?;
        if (op == .push_try) {
            const dst = targetPc(pc, 5, relAt(code.ptr + pc + 1));
            entries[idx] = .{ .bc_pc = @intCast(dst), .word_off = pc_map[dst] };
            idx += 1;
        }
        pc += step;
    }
    fp.catch_map = entries;
}

inline fn purePushLen(code: []const u8, pc: usize) ?usize {
    if (pc >= code.len) return null;
    return switch (@as(Op, @enumFromInt(code[pc]))) {
        .undef, .null_, .true_, .false_, .this => 1,
        .int8 => if (pc + 2 <= code.len) 2 else null,
        .get_loc => if (pc + 3 <= code.len and u16At(code.ptr + pc + 1) < 4096) 3 else null,
        .int32 => if (pc + 5 <= code.len) 5 else null,
        .constant => if (pc + 5 <= code.len and u32At(code.ptr + pc + 1) < 4096) 5 else null,
        else => null,
    };
}

inline fn emitPureLoad(e: *Emitter, code: []const u8, pc: usize, rd: u5) void {
    switch (@as(Op, @enumFromInt(code[pc]))) {
        .undef => e.subImm64(rd, 26, 2),
        .null_ => e.subImm64(rd, 26, 1),
        .false_ => e.mov64(rd, 26),
        .true_ => e.addImm64(rd, 26, 1),
        .this => e.ldrImm64(rd, 20, @intCast(@offsetOf(Frame, "this") / 8)),
        .int8 => {
            const i: i8 = @bitCast(code[pc + 1]);
            if (i >= 0) e.addImm64(rd, 25, @intCast(i)) else e.movImm64(rd, Value.fromInt(i).bits);
        },
        .int32 => {
            const i: i32 = @bitCast(u32At(code.ptr + pc + 1));
            if (i >= 0 and i < 4096) e.addImm64(rd, 25, @intCast(i)) else e.movImm64(rd, Value.fromInt(i).bits);
        },
        .constant => e.ldrImm64(rd, 23, @intCast(u32At(code.ptr + pc + 1))),
        .get_loc => e.ldrImm64(rd, 21, @intCast(u16At(code.ptr + pc + 1))),
        else => unreachable,
    }
}

inline fn isCompareOp(op: Op) bool {
    return switch (op) {
        .lt, .le, .gt, .ge, .seq, .sne, .eq, .ne => true,
        else => false,
    };
}

inline fn isBinaryOp(op: Op) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .bit_and, .bit_or, .bit_xor, .shl, .sar, .shr => true,
        else => false,
    };
}

inline fn matchBranchTail(code: []const u8, start_pc: usize, targets: []const bool) ?struct { end_pc: usize, dst: usize, on_true: bool } {
    var p = start_pc;
    var invert = false;
    while (p < code.len and !targets[p] and @as(Op, @enumFromInt(code[p])) == .not) : (p += 1) {
        invert = !invert;
    }
    if (p + 5 > code.len or targets[p]) return null;
    const jop: Op = @enumFromInt(code[p]);
    if (jop != .jump_false and jop != .jump_true) return null;
    const dst = targetPc(p, 5, relAt(code.ptr + p + 1));
    if (dst > code.len) return null;
    return .{
        .end_pc = p + 5,
        .dst = dst,
        .on_true = (jop == .jump_true) != invert,
    };
}

pub fn tryEmitFused(
    e: *Emitter,
    code: []const u8,
    pc: usize,
    targets: []const bool,
    pc_map: []const u32,
    epilogue_idx: u32,
    pass: u1,
) ?usize {
    const op1: Op = @enumFromInt(code[pc]);

    // 1. `get_loc S + (inc | dec) + (put_loc S2 | set_loc S2)` (for-loop `i++` / `++i`):
    if (op1 == .get_loc and pc + 7 <= code.len and !targets[pc + 3] and !targets[pc + 4]) {
        const s1 = u16At(code.ptr + pc + 1);
        const op2: Op = @enumFromInt(code[pc + 3]);
        if (s1 < 4096 and (op2 == .inc or op2 == .dec)) {
            const op3: Op = @enumFromInt(code[pc + 4]);
            if (op3 == .put_loc or op3 == .set_loc) {
                const s2 = u16At(code.ptr + pc + 5);
                if (s2 < 4096) {
                    e.ldrImm64(0, 21, @intCast(s1));
                    e.eorReg64(2, 0, 25);
                    e.lsrImm64(2, 2, 48);
                    const b_slow1 = e.len;
                    e.cbnz64(2, 0);
                    if (op2 == .inc) e.addsImm32(0, 0, 1) else e.subsImm32(0, 0, 1);
                    const b_slow2 = e.len;
                    e.bCond(.vs, 0);
                    e.orrReg64(0, 0, 25);
                    const b_done = e.len;
                    e.bImm(0);
                    const slow_idx = e.len;
                    e.buf[b_slow1] |= (@as(u32, @intCast(slow_idx - b_slow1)) & 0x7FFFF) << 5;
                    e.buf[b_slow2] |= (@as(u32, @intCast(slow_idx - b_slow2)) & 0x7FFFF) << 5;
                    e.strImm64(0, 22, 0);
                    e.addImm64(22, 22, 8);
                    e.callHelper5(@intFromPtr(&jit.jitUnaryOp), @intFromPtr(code.ptr + pc + 3), @intFromEnum(op2), epilogue_idx, pass);
                    e.subImm64(22, 22, 8);
                    e.buf[b_done] |= @as(u32, @intCast(e.len - b_done)) & 0x03FF_FFFF;
                    e.strImm64(0, 21, @intCast(s2));
                    if (op3 == .set_loc) {
                        e.strImm64(0, 22, 0);
                        e.addImm64(22, 22, 8);
                    }
                    return 7;
                }
            }
        }
    }

    // 2. Pure-push operand fusions:
    if (purePushLen(code, pc)) |lenA| {
        const pcB = pc + lenA;
        if (pcB < code.len and !targets[pcB]) {
            if (purePushLen(code, pcB)) |lenB| {
                const pcOp = pcB + lenB;
                if (pcOp < code.len and !targets[pcOp]) {
                    const op3: Op = @enumFromInt(code[pcOp]);
                    if (isCompareOp(op3)) {
                        if (matchBranchTail(code, pcOp + 1, targets)) |br| {
                            emitPureLoad(e, code, pc, 0);
                            emitPureLoad(e, code, pcB, 1);
                            ops_emit.emitCompareRegs(e, op3, @intFromPtr(code.ptr + pcOp), epilogue_idx, pass, false, .{
                                .word = if (pass == 1) pc_map[br.dst] else 0,
                                .on_true = br.on_true,
                                .pass = pass,
                            });
                            return br.end_pc - pc;
                        }
                        emitPureLoad(e, code, pc, 0);
                        emitPureLoad(e, code, pcB, 1);
                        ops_emit.emitCompareRegs(e, op3, @intFromPtr(code.ptr + pcOp), epilogue_idx, pass, false, null);
                        if (pcOp + 4 <= code.len and !targets[pcOp + 1]) {
                            const sop: Op = @enumFromInt(code[pcOp + 1]);
                            const s_out = u16At(code.ptr + pcOp + 2);
                            if ((sop == .put_loc or sop == .set_loc) and s_out < 4096) {
                                e.strImm64(0, 21, @intCast(s_out));
                                if (sop == .set_loc) {
                                    e.strImm64(0, 22, 0);
                                    e.addImm64(22, 22, 8);
                                }
                                return (pcOp + 4) - pc;
                            }
                        }
                        e.strImm64(0, 22, 0);
                        e.addImm64(22, 22, 8);
                        return (pcOp + 1) - pc;
                    }
                    if (isBinaryOp(op3)) {
                        emitPureLoad(e, code, pc, 0);
                        emitPureLoad(e, code, pcB, 1);
                        ops_emit.emitBinaryRegs(e, op3, @intFromPtr(code.ptr + pcOp), epilogue_idx, pass, false);
                        if (pcOp + 4 <= code.len and !targets[pcOp + 1]) {
                            const sop: Op = @enumFromInt(code[pcOp + 1]);
                            const s_out = u16At(code.ptr + pcOp + 2);
                            if ((sop == .put_loc or sop == .set_loc) and s_out < 4096) {
                                e.strImm64(0, 21, @intCast(s_out));
                                if (sop == .set_loc) {
                                    e.strImm64(0, 22, 0);
                                    e.addImm64(22, 22, 8);
                                }
                                return (pcOp + 4) - pc;
                            }
                        }
                        e.strImm64(0, 22, 0);
                        e.addImm64(22, 22, 8);
                        return (pcOp + 1) - pc;
                    }
                }
            }

            // 2b. `[PurePush A] + (0..N .not) + [jump_false | jump_true]` (`if (x)` / `if (!x)`):
            if (matchBranchTail(code, pcB, targets)) |br| {
                emitPureLoad(e, code, pc, 0);
                e.emitTruthyTest();
                const rel: i32 = if (pass == 1) @as(i32, @intCast(pc_map[br.dst])) - @as(i32, @intCast(e.len)) else 0;
                if (br.on_true) e.cbnz64(2, rel) else e.cbz64(2, rel);
                return br.end_pc - pc;
            }

            // 2c. `[PurePush A] + (put_loc | set_loc)` (`x = 0`, `a = b`, `self = this`):
            if (pcB + 3 <= code.len) {
                const sop: Op = @enumFromInt(code[pcB]);
                if (sop == .put_loc or sop == .set_loc) {
                    const s_out = u16At(code.ptr + pcB + 1);
                    if (s_out < 4096) {
                        emitPureLoad(e, code, pc, 0);
                        e.strImm64(0, 21, @intCast(s_out));
                        if (sop == .set_loc) {
                            e.strImm64(0, 22, 0);
                            e.addImm64(22, 22, 8);
                        }
                        return (pcB + 3) - pc;
                    }
                }
            }
        }
    }

    // 3. Standalone `[CompareOp] + (0..N .not) + [jump_false | jump_true]`:
    if (isCompareOp(op1)) {
        if (matchBranchTail(code, pc + 1, targets)) |br| {
            e.ldur64(0, 22, -16);
            e.ldur64(1, 22, -8);
            e.subImm64(22, 22, 16);
            ops_emit.emitCompareRegs(e, op1, @intFromPtr(code.ptr + pc), epilogue_idx, pass, false, .{
                .word = if (pass == 1) pc_map[br.dst] else 0,
                .on_true = br.on_true,
                .pass = pass,
            });
            return br.end_pc - pc;
        }
    }

    // 4. Standalone `.not + (0..N .not) + [jump_false | jump_true]` (`if (!expr())`):
    if (op1 == .not) {
        if (matchBranchTail(code, pc, targets)) |br| {
            e.ldur64(0, 22, -8);
            e.subImm64(22, 22, 8);
            e.emitTruthyTest();
            const rel: i32 = if (pass == 1) @as(i32, @intCast(pc_map[br.dst])) - @as(i32, @intCast(e.len)) else 0;
            if (br.on_true) e.cbnz64(2, rel) else e.cbz64(2, rel);
            return br.end_pc - pc;
        }
    }

    return null;
}
