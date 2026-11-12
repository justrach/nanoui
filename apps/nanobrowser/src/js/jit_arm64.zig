//! Baseline JIT compiler for `aarch64` (Theorem 17, `NanoUI.JitPerf.jit_template_dispatch_equiv`).
//! Translates `FuncProto` bytecode into native ARM64 machine code in two passes over stack buffers.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const value = @import("value.zig");
const Value = value.Value;
const bc = @import("bytecode.zig");
const Op = bc.Op;
const fr = @import("frame.zig");
const Frame = fr.Frame;
const objmod = @import("object.zig");
const Object = objmod.Object;
const heap = @import("heap.zig");
const jit = @import("jit.zig");
const JitFn = jit.JitFn;
const enc = @import("jit_arm64_enc.zig");
const arm64_iter = @import("jit_arm64_iter.zig");
const arm64_fuse = @import("jit_arm64_fuse.zig");
const Cond = enc.Cond;
const Emitter = enc.Emitter;

inline fn u16At(p: [*]const u8) u32 { return std.mem.readInt(u16, p[0..2], .little); }
inline fn u32At(p: [*]const u8) u32 { return std.mem.readInt(u32, p[0..4], .little); }
inline fn relAt(p: [*]const u8) isize { return std.mem.readInt(i32, p[0..4], .little); }
inline fn targetPc(pc: usize, op_len: usize, rel: isize) usize {
    const base = pc + op_len;
    return if (rel >= 0) base + @as(usize, @intCast(rel)) else base - @as(usize, @intCast(-rel));
}
inline fn pushReg(e: *Emitter, r: u5) void { e.strImm64(r, 22, 0); e.addImm64(22, 22, 8); }

fn instrLen(op: Op) ?usize {
    return switch (op) {
        .undef, .null_, .true_, .false_, .hole, .this, .callee, .new_target, .home, .arguments => 1,
        .pop, .dup, .dup2, .swap, .nip, .insert2, .insert3, .rot3l, .rot3r => 1,
        .pop_env, .clone_env, .import_meta, .dynamic_import => 1,
        .get_elem, .get_elem2, .put_elem, .delete_elem, .super_get, .super_put, .define_elem => 1,
        .set_proto, .set_fn_name, .get_private, .put_private, .define_private, .home_set, .has_private => 1,
        .new_object, .array_append, .array_spread, .object_spread, .set_fields, .run_static, .run_fields => 1,
        .add, .sub, .mul, .div, .mod, .pow, .bit_and, .bit_or, .bit_xor, .shl, .sar, .shr => 1,
        .lt, .le, .gt, .ge, .eq, .ne, .seq, .sne, .neg, .plus, .not, .bit_not, .inc, .dec => 1,
        .typeof_, .to_numeric, .to_propkey, .to_str, .instanceof_, .in_ => 1,
        .apply, .apply_new, .get_super_ctor, .super_apply, .super_forward, .check_super_once => 1,
        .ret, .ret_undef, .throw_, .check_coercible, .pop_try, .ret_sub => 1,
        .iter_init, .iter_step, .iter_rest, .iter_close, .iter_drop, .for_in_start, .to_object, .nop => 1,
        .int8, .define_method, .define_private_method => 2,
        .args_get, .args_len, .args_elem, .args_apply => 3,
        .rest, .get_loc, .put_loc, .set_loc, .set_hole, .push_env, .object_rest, .call, .new_, .super_call => 3,
        .get_env, .put_env => 4,
        .int32, .constant, .get_global, .get_global_typeof, .put_global, .decl_global_var, .def_global_fn => 5,
        .init_global_lex, .delete_global, .get_import, .get_field, .get_field2, .put_field, .get_length => 5,
        .define_field, .new_private, .array_from, .closure, .push_try, .gosub => 5,
        .jump, .loop, .jump_false, .jump_true, .jump_false_keep, .jump_true_keep => 5,
        .jump_notnull_keep, .jump_not_undef, .ctor_ret_check, .throw_const, .iter_next, .iter_result => 5,
        .decl_global_lex, .make_class, .opt_chain => 6,
        .get_loc_check, .put_loc_check => 7,
        .get_env_check, .put_env_check => 8,
        .new_regexp, .for_in_next, .with_get, .with_get_call, .with_put, .with_delete => 9,
        else => null,
    };
}

fn emitFunction(e: *Emitter, fp: *bc.FuncProto, targets: []const bool, pc_map: []u32, epilogue_idx: u32, pass: u1) bool {
    const code = fp.code;
    // Standard C-ABI entry (`fp.jit_fn`, words 0..23): saves callee-saved regs and calls `fp.jit_fast_fn` (word 24).
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
    e.ldrImm64(8, 20, @intCast(@offsetOf(Frame, "fp") / 8));
    e.movz(25, 0xFFF9, 3);
    e.movz(26, 2, 0);
    e.movk(26, 0xFFFA, 3);
    e.movz(27, 0xFFFB, 3);
    e.blImm(8);
    e.ldrImm64(27, 31, 10);
    e.ldpOffset64(25, 26, 31, 8);
    e.ldpOffset64(23, 24, 31, 6);
    e.ldpOffset64(21, 22, 31, 4);
    e.ldpOffset64(19, 20, 31, 2);
    e.ldpPost64(29, 30, 31, 12);
    e.ret();
    std.debug.assert(e.len == bc.FuncProto.fast_entry_words);

    // Direct JIT-to-JIT entry (`fp.jit_fast_fn`, word 24): expects `x8 = fp`, `x19..x22` & `x25..x27` live.
    e.stpPre64(29, 30, 31, -4);
    e.addImm64(29, 31, 0);
    e.stpOffset64(23, 24, 31, 2);
    e.ldrImm64(23, 8, @intCast(@offsetOf(bc.FuncProto, "constants") / 8));
    e.ldrImm64(24, 8, @intCast(@offsetOf(bc.FuncProto, "ics") / 8));

    var pc: usize = 0;
    while (pc < code.len) {
        if (pass == 0) {
            pc_map[pc] = e.len;
        } else if (pc_map[pc] != e.len) {
            return false;
        }
        if (arm64_fuse.tryEmitFused(e, code, pc, targets, pc_map, epilogue_idx, pass)) |fused_step| {
            if (e.overflow) return false;
            pc += fused_step;
            continue;
        }
        const op: Op = @enumFromInt(code[pc]);
        const step = instrLen(op) orelse return false;
        if (pc + step > code.len) return false;
        const pc_addr = @intFromPtr(code.ptr + pc);

        switch (op) {
            .undef => { e.subImm64(0, 26, 2); pushReg(e, 0); },
            .null_ => { e.subImm64(0, 26, 1); pushReg(e, 0); },
            .false_ => pushReg(e, 26),
            .true_ => { e.addImm64(0, 26, 1); pushReg(e, 0); },
            .hole => { e.addImm64(0, 26, 2); pushReg(e, 0); },
            .int8 => {
                const i: i8 = @bitCast(code[pc + 1]);
                if (i >= 0) e.addImm64(0, 25, @intCast(i)) else e.movImm64(0, Value.fromInt(i).bits);
                pushReg(e, 0);
            },
            .int32 => {
                const i: i32 = @bitCast(u32At(code.ptr + pc + 1));
                if (i >= 0 and i < 4096) e.addImm64(0, 25, @intCast(i)) else e.movImm64(0, Value.fromInt(i).bits);
                pushReg(e, 0);
            },
            .constant => {
                const k = u32At(code.ptr + pc + 1);
                if (k < 4096) {
                    e.ldrImm64(0, 23, @intCast(k));
                } else {
                    e.movImm64(2, k);
                    e.ldrRegScaled64(0, 23, 2);
                }
                pushReg(e, 0);
            },
            .this => { e.ldrImm64(0, 20, @intCast(@offsetOf(Frame, "this") / 8)); pushReg(e, 0); },
            .callee => {
                e.ldrImm64(0, 20, @intCast(@offsetOf(Frame, "func") / 8));
                e.orrReg64(0, 0, 27);
                pushReg(e, 0);
            },
            .new_target => { e.ldrImm64(0, 20, @intCast(@offsetOf(Frame, "new_target") / 8)); pushReg(e, 0); },
            .home, .check_super_once, .run_fields => arm64_iter.emitClassMisc(e, op, pc_addr, epilogue_idx, pass),
            .check_coercible => {
                e.ldur64(0, 22, -8);
                e.eorReg64(2, 0, 26);
                e.lsrImm64(2, 2, 1);
                e.cmpImm64(2, 1);
                const b_ok = e.len;
                e.bCond(.ne, 0);
                e.callHelper5(@intFromPtr(&jit.jitSlowOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
                e.buf[b_ok] |= (@as(u32, @intCast(e.len - b_ok)) & 0x7FFFF) << 5;
            },
            .pop => e.subImm64(22, 22, 8),
            .dup => { e.ldur64(0, 22, -8); pushReg(e, 0); },
            .dup2 => {
                e.ldur64(0, 22, -16);
                e.ldur64(1, 22, -8);
                e.strImm64(0, 22, 0);
                e.strImm64(1, 22, 1);
                e.addImm64(22, 22, 16);
            },
            .swap => {
                e.ldur64(0, 22, -16);
                e.ldur64(1, 22, -8);
                e.stur64(1, 22, -16);
                e.stur64(0, 22, -8);
            },
            .nip => {
                e.ldur64(0, 22, -8);
                e.stur64(0, 22, -16);
                e.subImm64(22, 22, 8);
            },
            .insert2 => {
                e.ldur64(0, 22, -16);
                e.ldur64(1, 22, -8);
                e.stur64(1, 22, -16);
                e.stur64(0, 22, -8);
                pushReg(e, 1);
            },
            .insert3, .rot3r => {
                e.ldur64(0, 22, -24);
                e.ldur64(1, 22, -16);
                e.ldur64(2, 22, -8);
                e.stur64(2, 22, -24);
                e.stur64(0, 22, -16);
                e.stur64(1, 22, -8);
                if (op == .insert3) pushReg(e, 2);
            },
            .rot3l => {
                e.ldur64(0, 22, -24);
                e.ldur64(1, 22, -16);
                e.ldur64(2, 22, -8);
                e.stur64(1, 22, -24);
                e.stur64(2, 22, -16);
                e.stur64(0, 22, -8);
            },
            .pop_env => {
                e.ldrImm64(2, 20, @intCast(@offsetOf(Frame, "env") / 8));
                e.ldrImm64(2, 2, @intCast(@offsetOf(heap.Env, "parent") / 8));
                e.strImm64(2, 20, @intCast(@offsetOf(Frame, "env") / 8));
            },
            .get_loc => {
                const slot = u16At(code.ptr + pc + 1);
                if (slot < 4096) e.ldrImm64(0, 21, @intCast(slot)) else { e.movz(2, @intCast(slot), 0); e.ldrRegScaled64(0, 21, 2); }
                pushReg(e, 0);
            },
            .put_loc => {
                const slot = u16At(code.ptr + pc + 1);
                e.ldur64(0, 22, -8);
                e.subImm64(22, 22, 8);
                if (slot < 4096) e.strImm64(0, 21, @intCast(slot)) else { e.movz(2, @intCast(slot), 0); e.strRegScaled64(0, 21, 2); }
            },
            .set_loc => {
                const slot = u16At(code.ptr + pc + 1);
                e.ldur64(0, 22, -8);
                if (slot < 4096) e.strImm64(0, 21, @intCast(slot)) else { e.movz(2, @intCast(slot), 0); e.strRegScaled64(0, 21, 2); }
            },
            .set_hole => {
                const slot = u16At(code.ptr + pc + 1);
                e.addImm64(0, 26, 2);
                if (slot < 4096) e.strImm64(0, 21, @intCast(slot)) else { e.movz(2, @intCast(slot), 0); e.strRegScaled64(0, 21, 2); }
            },
            .get_loc_check, .put_loc_check => {
                const slot = u16At(code.ptr + pc + 1);
                const name_idx = u32At(code.ptr + pc + 3);
                if (slot < 4096) e.ldrImm64(0, 21, @intCast(slot)) else { e.movz(3, @intCast(slot), 0); e.ldrRegScaled64(0, 21, 3); }
                e.addImm64(2, 26, 2);
                e.cmpReg64(0, 2);
                const before_call = e.len;
                e.bCond(.ne, 0);
                e.callHelper5(@intFromPtr(&jit.jitThrowTdz), pc_addr, name_idx, epilogue_idx, pass);
                e.buf[before_call] |= (@as(u32, @intCast(e.len - before_call)) & 0x7FFFF) << 5;
                if (op == .get_loc_check) {
                    e.strImm64(0, 22, 0);
                    e.addImm64(22, 22, 8);
                } else {
                    e.ldur64(0, 22, -8);
                    e.subImm64(22, 22, 8);
                    if (slot < 4096) e.strImm64(0, 21, @intCast(slot)) else { e.movz(3, @intCast(slot), 0); e.strRegScaled64(0, 21, 3); }
                }
            },
            .get_env, .put_env, .get_env_check, .put_env_check => {
                const depth = code[pc + 1];
                const slot = u16At(code.ptr + pc + 2);
                const slot_off = @sizeOf(heap.Env) / 8 + slot;
                if (depth <= 32 and slot_off < 4096) {
                    e.ldrImm64(2, 20, @intCast(@offsetOf(Frame, "env") / 8));
                    var d: u8 = 0;
                    while (d < depth) : (d += 1) {
                        e.ldrImm64(2, 2, @intCast(@offsetOf(heap.Env, "parent") / 8));
                    }
                    if (op == .get_env_check or op == .put_env_check) {
                        const name_idx = u32At(code.ptr + pc + 4);
                        e.ldrImm64(0, 2, @intCast(slot_off));
                        e.addImm64(3, 26, 2);
                        e.cmpReg64(0, 3);
                        const before_call = e.len;
                        e.bCond(.ne, 0);
                        e.callHelper5(@intFromPtr(&jit.jitThrowTdz), pc_addr, name_idx, epilogue_idx, pass);
                        e.buf[before_call] |= (@as(u32, @intCast(e.len - before_call)) & 0x7FFFF) << 5;
                    }
                    if (op == .get_env) {
                        e.ldrImm64(0, 2, @intCast(slot_off));
                        e.strImm64(0, 22, 0);
                        e.addImm64(22, 22, 8);
                    } else if (op == .get_env_check) {
                        e.strImm64(0, 22, 0);
                        e.addImm64(22, 22, 8);
                    } else {
                        e.ldur64(0, 22, -8);
                        e.subImm64(22, 22, 8);
                        e.strImm64(0, 2, @intCast(slot_off));
                    }
                } else return false;
            },
            .get_field, .get_field2 => {
                const ic_off = u32At(code.ptr + pc + 1) * @sizeOf(bc.IC);
                e.emitGetField(op, ic_off, pc_addr, epilogue_idx, pass);
            },
            .put_field => {
                const ic_off = u32At(code.ptr + pc + 1) * @sizeOf(bc.IC);
                e.emitPutField(ic_off, pc_addr, epilogue_idx, pass);
            },
            .define_field => {
                const ic_off = u32At(code.ptr + pc + 1) * @sizeOf(bc.IC);
                e.emitDefineField(ic_off, pc_addr, epilogue_idx, pass);
            },
            .get_global => {
                const ic_off = u32At(code.ptr + pc + 1) * @sizeOf(bc.IC);
                e.emitGetGlobal(ic_off, pc_addr, epilogue_idx, pass);
            },
            .put_global => e.callHelper4(@intFromPtr(&jit.jitPutGlobal), pc_addr, epilogue_idx, pass),
            .get_length => e.emitGetLength(pc_addr, epilogue_idx, pass),
            .get_elem, .get_elem2 => e.emitGetElem(op, pc_addr, epilogue_idx, pass),
            .put_elem => e.emitPutElem(pc_addr, epilogue_idx, pass),
            .new_object => {
                e.callHelper4(@intFromPtr(&jit.jitNewObject), pc_addr, epilogue_idx, pass);
                pushReg(e, 0);
            },
            .closure => {
                const proto_idx = u32At(code.ptr + pc + 1);
                e.callHelper5(@intFromPtr(&jit.jitClosure), pc_addr, proto_idx, epilogue_idx, pass);
                pushReg(e, 0);
            },
            .push_env => {
                const n = u16At(code.ptr + pc + 1);
                e.callHelper5(@intFromPtr(&jit.jitPushEnv), pc_addr, n, epilogue_idx, pass);
            },
            .array_from => {
                const n = u32At(code.ptr + pc + 1);
                e.callHelper5(@intFromPtr(&jit.jitArrayFrom), pc_addr, n, epilogue_idx, pass);
                e.mov64(22, 0);
            },
            .arguments => {
                e.callHelper4(@intFromPtr(&jit.jitArguments), pc_addr, epilogue_idx, pass);
                pushReg(e, 0);
            },
            .args_get => arm64_iter.emitArgsGet(e, u16At(code.ptr + pc + 1), pc_addr, epilogue_idx, pass),
            .args_len => arm64_iter.emitArgsLen(e, u16At(code.ptr + pc + 1), pc_addr, epilogue_idx, pass),
            .args_elem => arm64_iter.emitArgsElem(e, u16At(code.ptr + pc + 1), pc_addr, epilogue_idx, pass),
            .args_apply => {
                e.movImm64(3, @intFromPtr(code.ptr + pc + 3));
                e.movz(4, @truncate(u16At(code.ptr + pc + 1)), 0);
                e.ldrImm64(9, 19, @intCast(@offsetOf(Vm, "fast_args_apply_stub") / 8));
                e.blr(9);
                const ep_rel: i32 = if (pass == 1) @as(i32, @intCast(epilogue_idx)) - @as(i32, @intCast(e.len)) else 0;
                e.cbnz64(1, ep_rel);
                e.mov64(22, 0);
            },
            .rest => {
                e.callHelper5(@intFromPtr(&jit.jitRest), pc_addr, u16At(code.ptr + pc + 1), epilogue_idx, pass);
                pushReg(e, 0);
            },
            .new_regexp => {
                e.callHelper4(@intFromPtr(&jit.jitNewRegExp), pc_addr, epilogue_idx, pass);
                pushReg(e, 0);
            },
            .in_, .instanceof_ => {
                e.callHelper4(if (op == .in_) @intFromPtr(&jit.jitIn) else @intFromPtr(&jit.jitInstanceOf), pc_addr, epilogue_idx, pass);
                e.stur64(0, 22, -16);
                e.subImm64(22, 22, 8);
            },
            .bit_not, .neg, .to_propkey, .inc, .dec => e.emitUnaryFast(op, pc_addr, epilogue_idx, pass),
            .add, .sub, .mul, .div, .bit_and, .bit_or, .bit_xor, .shl, .sar, .shr => e.emitBinaryOp(op, pc_addr, epilogue_idx, pass),
            .mod => arm64_iter.emitMod(e, pc_addr, epilogue_idx, pass),
            .lt, .le, .gt, .ge, .seq, .sne, .eq, .ne => e.emitCompareOp(op, pc_addr, epilogue_idx, pass),
            .not => {
                e.ldur64(0, 22, -8);
                e.emitTruthyTest();
                e.cmpImm64(2, 0);
                e.cset64(0, .eq);
                e.orrReg64(0, 0, 26);
                e.stur64(0, 22, -8);
            },
            .typeof_ => {
                e.mov64(0, 19);
                e.ldur64(1, 22, -8);
                e.movImm64(9, @intFromPtr(&jit.jitTypeOf));
                e.blr(9);
                e.stur64(0, 22, -8);
            },
            .to_str => {
                e.ldur64(0, 22, -8);
                e.subReg64(2, 0, 25);
                e.lsrImm64(2, 2, 48);
                e.cmpImm64(2, 3);
                const b_str = e.len;
                e.bCond(.eq, 0);
                e.callHelper5(@intFromPtr(&jit.jitSlowOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
                e.mov64(22, 0);
                e.buf[b_str] |= (@as(u32, @intCast(e.len - b_str)) & 0x7FFFF) << 5;
            },
            .to_numeric, .plus => {
                e.ldur64(0, 22, -8);
                e.cmpReg64(0, 25);
                const b_num1 = e.len;
                e.bCond(.lo, 0);
                e.eorReg64(2, 0, 25);
                e.lsrImm64(2, 2, 48);
                const b_num2 = e.len;
                e.cbz64(2, 0);
                if (op == .plus) {
                    e.callHelper5(@intFromPtr(&jit.jitUnaryOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
                    e.stur64(0, 22, -8);
                } else {
                    e.callHelper5(@intFromPtr(&jit.jitSlowOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
                    e.mov64(22, 0);
                }
                e.buf[b_num1] |= (@as(u32, @intCast(e.len - b_num1)) & 0x7FFFF) << 5;
                e.buf[b_num2] |= (@as(u32, @intCast(e.len - b_num2)) & 0x7FFFF) << 5;
            },
            .jump => {
                const dst = targetPc(pc, 5, relAt(code.ptr + pc + 1));
                if (dst > code.len) return false;
                const rel: i32 = if (pass == 1) @as(i32, @intCast(pc_map[dst])) - @as(i32, @intCast(e.len)) else 0;
                e.bImm(rel);
            },
            .loop => {
                const dst = targetPc(pc, 5, relAt(code.ptr + pc + 1));
                if (dst > code.len) return false;
                e.ldrImm32(0, 19, @intCast(@offsetOf(Vm, "budget") / 4));
                e.subsImm32(0, 0, 1);
                e.strImm32(0, 19, @intCast(@offsetOf(Vm, "budget") / 4));
                const rel1: i32 = if (pass == 1) @as(i32, @intCast(pc_map[dst])) - @as(i32, @intCast(e.len)) else 0;
                e.bCond(.gt, rel1);
                e.callHelper4(@intFromPtr(&jit.jitInterrupt), @intFromPtr(code.ptr + dst), epilogue_idx, pass);
                const rel2: i32 = if (pass == 1) @as(i32, @intCast(pc_map[dst])) - @as(i32, @intCast(e.len)) else 0;
                e.bImm(rel2);
            },
            .jump_false, .jump_true => {
                const dst = targetPc(pc, 5, relAt(code.ptr + pc + 1));
                if (dst > code.len) return false;
                e.ldur64(0, 22, -8);
                e.subImm64(22, 22, 8);
                e.emitTruthyTest();
                const rel: i32 = if (pass == 1) @as(i32, @intCast(pc_map[dst])) - @as(i32, @intCast(e.len)) else 0;
                if (op == .jump_false) e.cbz64(2, rel) else e.cbnz64(2, rel);
            },
            .jump_false_keep, .jump_true_keep => {
                const dst = targetPc(pc, 5, relAt(code.ptr + pc + 1));
                if (dst > code.len) return false;
                e.ldur64(0, 22, -8);
                e.emitTruthyTest();
                const rel: i32 = if (pass == 1) @as(i32, @intCast(pc_map[dst])) - @as(i32, @intCast(e.len)) else 0;
                if (op == .jump_false_keep) e.cbz64(2, rel) else e.cbnz64(2, rel);
                e.subImm64(22, 22, 8);
            },
            .jump_notnull_keep => {
                const dst = targetPc(pc, 5, relAt(code.ptr + pc + 1));
                if (dst > code.len) return false;
                e.ldur64(0, 22, -8);
                e.eorReg64(2, 0, 26);
                e.lsrImm64(2, 2, 1);
                e.cmpImm64(2, 1);
                const rel: i32 = if (pass == 1) @as(i32, @intCast(pc_map[dst])) - @as(i32, @intCast(e.len)) else 0;
                e.bCond(.ne, rel);
                e.subImm64(22, 22, 8);
            },
            .jump_not_undef => {
                const dst = targetPc(pc, 5, relAt(code.ptr + pc + 1));
                if (dst > code.len) return false;
                e.ldur64(0, 22, -8);
                e.subImm64(2, 26, 2);
                e.cmpReg64(0, 2);
                const rel: i32 = if (pass == 1) @as(i32, @intCast(pc_map[dst])) - @as(i32, @intCast(e.len)) else 0;
                e.bCond(.ne, rel);
                e.subImm64(22, 22, 8);
            },
            .call => {
                const argc = u16At(code.ptr + pc + 1);
                e.movImm64(3, @intFromPtr(code.ptr + pc + 3));
                e.movz(4, @truncate(argc), 0);
                e.ldrImm64(9, 19, @intCast(@offsetOf(Vm, "fast_call_stub") / 8));
                e.blr(9);
                const ep_rel: i32 = if (pass == 1) @as(i32, @intCast(epilogue_idx)) - @as(i32, @intCast(e.len)) else 0;
                e.cbnz64(1, ep_rel);
                e.mov64(22, 0);
            },
            .new_ => {
                const argc = u16At(code.ptr + pc + 1);
                e.callHelper5(@intFromPtr(&jit.jitNew), @intFromPtr(code.ptr + pc + 3), argc, epilogue_idx, pass);
                e.mov64(22, 0);
            },
            .apply, .apply_new => {
                e.callHelper5(@intFromPtr(&jit.jitApply), @intFromPtr(code.ptr + pc + 1), @intFromBool(op == .apply_new), epilogue_idx, pass);
                e.mov64(22, 0);
            },
            .ret => {
                e.ldur64(0, 22, -8);
                e.subImm64(22, 22, 8);
                e.movz(1, 0, 0);
                const rel: i32 = if (pass == 1) @as(i32, @intCast(epilogue_idx)) - @as(i32, @intCast(e.len)) else 0;
                e.bImm(rel);
            },
            .ret_undef => {
                e.subImm64(0, 26, 2);
                e.movz(1, 0, 0);
                const rel: i32 = if (pass == 1) @as(i32, @intCast(epilogue_idx)) - @as(i32, @intCast(e.len)) else 0;
                e.bImm(rel);
            },
            .push_try => {
                const dst = targetPc(pc, 5, relAt(code.ptr + pc + 1));
                if (dst > code.len) return false;
                arm64_iter.emitPushTry(e, @intCast(dst));
            },
            .pop_try => e.subImm64(22, 22, 16),
            .gosub => {
                const dst = targetPc(pc, 5, relAt(code.ptr + pc + 1));
                if (dst > code.len) return false;
                const ret_bc = pc + 5;
                if (ret_bc < 65536) e.movz(0, @intCast(ret_bc), 0) else e.movImm64(0, ret_bc);
                e.orrReg64(0, 0, 25);
                e.strImm64(0, 22, 0);
                e.addImm64(22, 22, 8);
                const rel: i32 = if (pass == 1) @as(i32, @intCast(pc_map[dst])) - @as(i32, @intCast(e.len)) else 0;
                e.bImm(rel);
            },
            .ret_sub => {
                e.ldur64(0, 22, -8);
                e.subImm64(22, 22, 8);
                var g_pc: usize = 0;
                var gosub_count: u32 = 0;
                while (g_pc < code.len) {
                    const g_op: Op = @enumFromInt(code[g_pc]);
                    const g_step = instrLen(g_op) orelse return false;
                    if (g_op == .gosub) {
                        gosub_count += 1;
                        if (gosub_count > 512) return false;
                        const ret_bc = g_pc + 5;
                        if (ret_bc < 65536) e.movz(2, @intCast(ret_bc), 0) else e.movImm64(2, ret_bc);
                        e.cmpReg32(0, 2);
                        const rel: i32 = if (pass == 1) @as(i32, @intCast(pc_map[ret_bc])) - @as(i32, @intCast(e.len)) else 0;
                        e.bCond(.eq, rel);
                    }
                    g_pc += g_step;
                }
            },
            .opt_chain => {
                const dst = targetPc(pc, 5, relAt(code.ptr + pc + 1));
                if (dst > code.len) return false;
                arm64_iter.emitOptChain(e, if (pass == 1) pc_map[dst] else 0, @as(u12, code[pc + 5]) * 8, pass);
            },
            .iter_drop => e.subImm64(22, 22, 24),
            .iter_close => arm64_iter.emitIterClose(e, pc_addr, epilogue_idx, pass),
            .iter_init => arm64_iter.emitIterInit(e, pc_addr, epilogue_idx, pass),
            .iter_step => arm64_iter.emitIterStep(e, pc_addr, epilogue_idx, pass),
            .for_in_start => arm64_iter.emitForInStart(e, pc_addr, epilogue_idx, pass),
            .ctor_ret_check => {
                const dst = targetPc(pc, 5, relAt(code.ptr + pc + 1));
                if (dst > code.len) return false;
                arm64_iter.emitCtorRetCheck(e, if (pass == 1) pc_map[dst] else 0, pc_addr, epilogue_idx, pass);
            },
            .iter_next => {
                const dst = targetPc(pc, 5, relAt(code.ptr + pc + 1));
                if (dst > code.len) return false;
                arm64_iter.emitIterNext(e, if (pass == 1) pc_map[dst] else 0, pc_addr, @intFromPtr(code.ptr + pc + 5), epilogue_idx, pass);
            },
            .for_in_next => {
                const dst = targetPc(pc, 9, relAt(code.ptr + pc + 5));
                if (dst > code.len) return false;
                arm64_iter.emitForInNext(e, code.ptr + pc, if (pass == 1) pc_map[dst] else 0, pc_addr, @intFromPtr(code.ptr + pc + 9), epilogue_idx, pass);
            },
            .iter_result, .with_get, .with_get_call, .with_put, .with_delete => {
                const is_9 = op != .iter_result;
                const rel_off: usize = if (is_9) 5 else 1;
                const base_off: usize = if (is_9) 9 else 5;
                const dst = targetPc(pc, base_off, relAt(code.ptr + pc + rel_off));
                if (dst > code.len) return false;
                arm64_iter.emitBranchSlow(e, op, if (pass == 1) pc_map[dst] else 0, pc_addr, @intFromPtr(code.ptr + pc + step), epilogue_idx, pass);
            },
            else => @import("jit_arm64_elem.zig").emitMiscOp(e, op, code.ptr + pc, pc_addr, epilogue_idx, pass),
        }
        if (e.overflow) return false;
        pc += step;
    }

    if (pass == 0) {
        pc_map[code.len] = e.len;
    } else if (pc_map[code.len] != e.len) {
        return false;
    }

    e.ldpOffset64(23, 24, 31, 2);
    e.ldpPost64(29, 30, 31, 4);
    e.ret();
    return !e.overflow;
}

threadlocal var targets_buf: [enc.max_bc_len + 1]bool = undefined;
threadlocal var pc_map_buf: [enc.max_bc_len + 1]u32 = undefined;
threadlocal var inst_words_buf: [enc.max_inst_words]u32 = undefined;

pub fn compile(vm: *Vm, fp: *bc.FuncProto) ?JitFn {
    if (comptime !jit.enabled) return null;
    if (fp.is_generator or fp.is_async or fp.code.len == 0 or fp.code.len > enc.max_bc_len) return null;
    const targets = targets_buf[0 .. fp.code.len + 1];
    if (!arm64_fuse.computeJumpTargets(fp.code, targets, &instrLen)) return null;
    var e = Emitter{ .buf = &inst_words_buf };
    if (!emitFunction(&e, fp, targets, pc_map_buf[0 .. fp.code.len + 1], 0, 0)) return null;
    const epilogue_idx = pc_map_buf[fp.code.len];
    e.len = 0;
    if (!emitFunction(&e, fp, targets, pc_map_buf[0 .. fp.code.len + 1], epilogue_idx, 1)) return null;
    const jfn = (if (fp.borrowed_code) jit.global_jit_pool.allocCode(std.heap.page_allocator, inst_words_buf[0..e.len]) else vm.jit_pool.allocCode(vm.raw_gpa, inst_words_buf[0..e.len])) orelse return null;
    arm64_fuse.buildCatchMap(vm, fp, pc_map_buf[0 .. fp.code.len + 1], &instrLen);
    return jfn;
}
