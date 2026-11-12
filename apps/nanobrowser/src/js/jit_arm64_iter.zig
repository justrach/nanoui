//! Inline ARM64 emission for `for..of`, array destructuring (`iter_*`),
//! zero-allocation `for..in` (`for_in_start`, `for_in_next`), class constructors
//! (`ctor_ret_check`, `check_super_once`, `home`, `run_fields`), and integer `.mod`.

const std = @import("std");
const Vm = @import("vm.zig").Vm;
const Protos = @import("vm.zig").Protos;
const bc = @import("bytecode.zig");
const Op = bc.Op;
const fr = @import("frame.zig");
const Frame = fr.Frame;
const objmod = @import("object.zig");
const Object = objmod.Object;
const shape_mod = @import("shape.zig");
const Shape = shape_mod.Shape;
const jit = @import("jit.zig");
const enc = @import("jit_arm64_enc.zig");
const Emitter = enc.Emitter;

comptime {
    std.debug.assert(@sizeOf(shape_mod.Entry) == 16);
    std.debug.assert(@offsetOf(shape_mod.Entry, "key") == 0);
    std.debug.assert(@offsetOf(shape_mod.Table, "entries") == 0);
    std.debug.assert(@offsetOf(Shape, "cell") == 0);
}

inline fn u16At(p: [*]const u8) u32 {
    return std.mem.readInt(u16, p[0..2], .little);
}

pub fn emitIterInit(e: *Emitter, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.ldur64(0, 22, -8);
    e.eorReg64(2, 0, 27);
    e.lsrImm64(3, 2, 48);
    const b1 = e.len;
    e.cbnz64(3, 0);
    e.ldrbImm(3, 2, @intCast(@offsetOf(Object, "class")));
    e.cmpImm64(3, @intFromEnum(objmod.Class.array));
    const b2 = e.len;
    e.bCond(.ne, 0);
    e.ldrhImm(3, 2, @intCast(@offsetOf(Object, "flags") / 2));
    const b3 = e.len;
    e.tbnz32(3, @bitOffsetOf(objmod.Flags, "has_sparse"), 0);
    e.ldrImm64(3, 2, @intCast(@offsetOf(Object, "shape") / 8));
    e.ldrImm32(4, 3, @intCast(@offsetOf(Shape, "count") / 4));
    const b4 = e.len;
    e.cbnz32(4, 0);
    e.ldrImm64(4, 3, @intCast(@offsetOf(Shape, "proto") / 8));
    e.ldrImm64(5, 19, @intCast((@offsetOf(Vm, "protos") + @offsetOf(Protos, "array")) / 8));
    e.cmpReg64(4, 5);
    const b5 = e.len;
    e.bCond(.ne, 0);
    e.ldrhImm(4, 5, @intCast(@offsetOf(Object, "flags") / 2));
    const b6 = e.len;
    e.tbnz32(4, @bitOffsetOf(objmod.Flags, "proto_dirty"), 0);
    e.ldrImm64(5, 19, @intCast((@offsetOf(Vm, "protos") + @offsetOf(Protos, "array_iter")) / 8));
    e.ldrhImm(4, 5, @intCast(@offsetOf(Object, "flags") / 2));
    const b7 = e.len;
    e.tbnz32(4, @bitOffsetOf(objmod.Flags, "proto_dirty"), 0);
    e.strImm64(25, 22, 0);
    e.movImm64(0, fr.iter_marker.bits);
    e.strImm64(0, 22, 1);
    e.addImm64(22, 22, 16);
    const b_done = e.len;
    e.bImm(0);

    const slow_idx = e.len;
    e.buf[b1] |= (@as(u32, @intCast(slow_idx - b1)) & 0x7FFFF) << 5;
    e.buf[b2] |= (@as(u32, @intCast(slow_idx - b2)) & 0x7FFFF) << 5;
    e.buf[b3] |= (@as(u32, @intCast(slow_idx - b3)) & 0x3FFF) << 5;
    e.buf[b4] |= (@as(u32, @intCast(slow_idx - b4)) & 0x7FFFF) << 5;
    e.buf[b5] |= (@as(u32, @intCast(slow_idx - b5)) & 0x7FFFF) << 5;
    e.buf[b6] |= (@as(u32, @intCast(slow_idx - b6)) & 0x3FFF) << 5;
    e.buf[b7] |= (@as(u32, @intCast(slow_idx - b7)) & 0x3FFF) << 5;
    e.callHelper5(@intFromPtr(&jit.jitSlowOp), pc_addr, @intFromEnum(Op.iter_init), epilogue_idx, pass);
    e.mov64(22, 0);
    e.buf[b_done] |= @as(u32, @intCast(e.len - b_done)) & 0x03FF_FFFF;
}

pub fn emitIterClose(e: *Emitter, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.ldur64(0, 22, -16);
    e.eorReg64(2, 0, 25);
    e.lsrImm64(2, 2, 48);
    const b_fast = e.len;
    e.cbz64(2, 0);
    e.ldur64(1, 22, -8);
    e.movImm64(2, fr.iter_marker.bits);
    e.cmpReg64(1, 2);
    const b_dead = e.len;
    e.bCond(.ne, 0);
    e.callHelper5(@intFromPtr(&jit.jitSlowOp), pc_addr, @intFromEnum(Op.iter_close), epilogue_idx, pass);
    e.mov64(22, 0);
    const b_done = e.len;
    e.bImm(0);

    const fast_idx = e.len;
    e.buf[b_fast] |= (@as(u32, @intCast(fast_idx - b_fast)) & 0x7FFFF) << 5;
    e.buf[b_dead] |= (@as(u32, @intCast(fast_idx - b_dead)) & 0x7FFFF) << 5;
    e.subImm64(22, 22, 24);
    e.buf[b_done] |= @as(u32, @intCast(e.len - b_done)) & 0x03FF_FFFF;
}

pub fn emitIterNext(e: *Emitter, dst_idx: u32, pc_addr: usize, next_pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.ldur64(1, 22, -16);
    e.eorReg64(2, 1, 25);
    e.lsrImm64(2, 2, 48);
    const b_slow1 = e.len;
    e.cbnz64(2, 0);
    e.ldur64(0, 22, -24);
    e.eorReg64(2, 0, 27);
    e.lsrImm64(3, 2, 48);
    const rel_done1: i32 = if (pass == 1) @as(i32, @intCast(dst_idx)) - @as(i32, @intCast(e.len)) else 0;
    e.cbnz64(3, rel_done1);
    e.mov32(5, 1);
    e.ldrImm32(3, 2, @intCast(@offsetOf(Object, "arr_len") / 4));
    e.cmpReg32(5, 3);
    const b_in_bounds = e.len;
    e.bCond(.lo, 0);
    // Exhausted: markDone and jump to dst!
    e.subImm64(0, 26, 2);
    e.stur64(0, 22, -24);
    e.movImm64(0, fr.dead_marker.bits);
    e.stur64(0, 22, -8);
    const rel_done2: i32 = if (pass == 1) @as(i32, @intCast(dst_idx)) - @as(i32, @intCast(e.len)) else 0;
    e.bImm(rel_done2);

    e.buf[b_in_bounds] |= (@as(u32, @intCast(e.len - b_in_bounds)) & 0x7FFFF) << 5;
    e.ldrImm32(3, 2, @intCast(@offsetOf(Object, "elems_len") / 4));
    e.cmpReg32(5, 3);
    const b_slow2 = e.len;
    e.bCond(.hs, 0);
    e.ldrImm64(4, 2, @intCast(@offsetOf(Object, "elems") / 8));
    e.ldrRegScaled64(0, 4, 5);
    e.addImm64(3, 26, 2);
    e.cmpReg64(0, 3);
    const b_slow3 = e.len;
    e.bCond(.eq, 0);
    e.addImm64(5, 5, 1);
    e.orrReg64(5, 5, 25);
    e.stur64(5, 22, -16);
    e.strImm64(0, 22, 0);
    e.addImm64(22, 22, 8);
    const b_ok = e.len;
    e.bImm(0);

    const slow_idx = e.len;
    e.buf[b_slow1] |= (@as(u32, @intCast(slow_idx - b_slow1)) & 0x7FFFF) << 5;
    e.buf[b_slow2] |= (@as(u32, @intCast(slow_idx - b_slow2)) & 0x7FFFF) << 5;
    e.buf[b_slow3] |= (@as(u32, @intCast(slow_idx - b_slow3)) & 0x7FFFF) << 5;
    emitBranchSlow(e, .iter_next, dst_idx, pc_addr, next_pc_addr, epilogue_idx, pass);
    e.buf[b_ok] |= @as(u32, @intCast(e.len - b_ok)) & 0x03FF_FFFF;
}

pub fn emitIterStep(e: *Emitter, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.ldur64(0, 22, -24);
    e.subImm64(6, 26, 2);
    e.cmpReg64(0, 6);
    const b_already_done = e.len;
    e.bCond(.eq, 0);
    e.ldur64(1, 22, -16);
    e.eorReg64(2, 1, 25);
    e.eorReg64(3, 0, 27);
    e.orrReg64(2, 2, 3);
    e.lsrImm64(2, 2, 48);
    const b_slow1 = e.len;
    e.cbnz64(2, 0);
    e.mov32(5, 1);
    e.ldrImm32(4, 3, @intCast(@offsetOf(Object, "arr_len") / 4));
    e.cmpReg32(5, 4);
    const b_in_bounds = e.len;
    e.bCond(.lo, 0);
    e.stur64(6, 22, -24);
    e.movImm64(0, fr.dead_marker.bits);
    e.stur64(0, 22, -8);
    e.buf[b_already_done] |= (@as(u32, @intCast(e.len - b_already_done)) & 0x7FFFF) << 5;
    e.strImm64(6, 22, 0);
    e.addImm64(22, 22, 8);
    const b_done1 = e.len;
    e.bImm(0);

    e.buf[b_in_bounds] |= (@as(u32, @intCast(e.len - b_in_bounds)) & 0x7FFFF) << 5;
    e.ldrImm32(4, 3, @intCast(@offsetOf(Object, "elems_len") / 4));
    e.cmpReg32(5, 4);
    const b_slow2 = e.len;
    e.bCond(.hs, 0);
    e.ldrImm64(4, 3, @intCast(@offsetOf(Object, "elems") / 8));
    e.ldrRegScaled64(0, 4, 5);
    e.addImm64(4, 26, 2);
    e.cmpReg64(0, 4);
    const b_slow3 = e.len;
    e.bCond(.eq, 0);
    e.addImm64(5, 5, 1);
    e.orrReg64(5, 5, 25);
    e.stur64(5, 22, -16);
    e.strImm64(0, 22, 0);
    e.addImm64(22, 22, 8);
    const b_done2 = e.len;
    e.bImm(0);

    const slow_idx = e.len;
    e.buf[b_slow1] |= (@as(u32, @intCast(slow_idx - b_slow1)) & 0x7FFFF) << 5;
    e.buf[b_slow2] |= (@as(u32, @intCast(slow_idx - b_slow2)) & 0x7FFFF) << 5;
    e.buf[b_slow3] |= (@as(u32, @intCast(slow_idx - b_slow3)) & 0x7FFFF) << 5;
    e.callHelper5(@intFromPtr(&jit.jitSlowOp), pc_addr, @intFromEnum(Op.iter_step), epilogue_idx, pass);
    e.mov64(22, 0);
    e.buf[b_done1] |= @as(u32, @intCast(e.len - b_done1)) & 0x03FF_FFFF;
    e.buf[b_done2] |= @as(u32, @intCast(e.len - b_done2)) & 0x03FF_FFFF;
}

pub fn emitForInStart(e: *Emitter, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.ldur64(0, 22, -8);
    e.eorReg64(2, 0, 26);
    e.lsrImm64(2, 2, 1);
    e.cmpImm64(2, 1);
    const b_not_nullish = e.len;
    e.bCond(.ne, 0);
    e.subImm64(2, 26, 2);
    e.stur64(2, 22, -8);
    e.strImm64(2, 22, 0);
    e.addImm64(22, 22, 8);
    const b_done1 = e.len;
    e.bImm(0);

    e.buf[b_not_nullish] |= (@as(u32, @intCast(e.len - b_not_nullish)) & 0x7FFFF) << 5;
    e.eorReg64(2, 0, 27);
    e.lsrImm64(3, 2, 48);
    const b1 = e.len;
    e.cbnz64(3, 0);
    e.ldrbImm(3, 2, @intCast(@offsetOf(Object, "class")));
    e.cmpImm64(3, @intFromEnum(objmod.Class.object));
    const b2 = e.len;
    e.bCond(.ne, 0);
    e.ldrbImm(3, 2, @intCast(@offsetOf(Object, "flags")));
    const b3 = e.len;
    e.tbnz32(3, @bitOffsetOf(objmod.Flags, "exotic"), 0);
    const b4 = e.len;
    e.tbnz32(3, @bitOffsetOf(objmod.Flags, "lazy_fn"), 0);
    e.ldrImm32(3, 2, @intCast(@offsetOf(Object, "elems_len") / 4));
    const b5 = e.len;
    e.cbnz32(3, 0);
    e.ldrImm64(3, 2, @intCast(@offsetOf(Object, "shape") / 8));
    e.ldrbImm(4, 3, @intCast(@offsetOf(Shape, "all_plain_str")));
    const b6 = e.len;
    e.cbz32(4, 0);
    e.ldrImm64(4, 3, @intCast(@offsetOf(Shape, "proto") / 8));
    const b_null_proto = e.len;
    e.cbz64(4, 0);
    e.ldrImm64(5, 19, @intCast((@offsetOf(Vm, "protos") + @offsetOf(Protos, "object")) / 8));
    e.cmpReg64(4, 5);
    const b7 = e.len;
    e.bCond(.ne, 0);
    e.ldrhImm(5, 4, @intCast(@offsetOf(Object, "flags") / 2));
    const b8 = e.len;
    e.tbnz32(5, @bitOffsetOf(objmod.Flags, "proto_dirty"), 0);

    e.buf[b_null_proto] |= (@as(u32, @intCast(e.len - b_null_proto)) & 0x7FFFF) << 5;
    e.movz(4, 0xFFF8, 3);
    e.orrReg64(3, 3, 4);
    e.strImm64(3, 22, 0);
    e.addImm64(22, 22, 8);
    const b_done2 = e.len;
    e.bImm(0);

    const slow_idx = e.len;
    e.buf[b1] |= (@as(u32, @intCast(slow_idx - b1)) & 0x7FFFF) << 5;
    e.buf[b2] |= (@as(u32, @intCast(slow_idx - b2)) & 0x7FFFF) << 5;
    e.buf[b3] |= (@as(u32, @intCast(slow_idx - b3)) & 0x3FFF) << 5;
    e.buf[b4] |= (@as(u32, @intCast(slow_idx - b4)) & 0x3FFF) << 5;
    e.buf[b5] |= (@as(u32, @intCast(slow_idx - b5)) & 0x7FFFF) << 5;
    e.buf[b6] |= (@as(u32, @intCast(slow_idx - b6)) & 0x7FFFF) << 5;
    e.buf[b7] |= (@as(u32, @intCast(slow_idx - b7)) & 0x7FFFF) << 5;
    e.buf[b8] |= (@as(u32, @intCast(slow_idx - b8)) & 0x3FFF) << 5;
    e.callHelper5(@intFromPtr(&jit.jitSlowOp), pc_addr, @intFromEnum(Op.for_in_start), epilogue_idx, pass);
    e.mov64(22, 0);
    e.buf[b_done1] |= @as(u32, @intCast(e.len - b_done1)) & 0x03FF_FFFF;
    e.buf[b_done2] |= @as(u32, @intCast(e.len - b_done2)) & 0x03FF_FFFF;
}

pub fn emitForInNext(e: *Emitter, code_ptr: [*]const u8, dst_idx: u32, pc_addr: usize, next_pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    const keys_slot = u16At(code_ptr + 1);
    const idx_slot = u16At(code_ptr + 3);
    if (keys_slot + 1 < 4096 and idx_slot < 4096) {
        e.ldrImm64(0, 21, @intCast(keys_slot));
        e.subImm64(2, 26, 2);
        e.cmpReg64(0, 2);
        const rel_done1: i32 = if (pass == 1) @as(i32, @intCast(dst_idx)) - @as(i32, @intCast(e.len)) else 0;
        e.bCond(.eq, rel_done1);
        e.ldrImm64(1, 21, @intCast(keys_slot + 1));
        e.movz(2, 0xFFF8, 3);
        e.eorReg64(3, 1, 2);
        e.lsrImm64(4, 3, 48);
        const b_slow1 = e.len;
        e.cbnz64(4, 0);
        e.eorReg64(4, 0, 27);
        e.ldrImm64(5, 4, @intCast(@offsetOf(Object, "shape") / 8));
        e.cmpReg64(5, 3);
        const b_slow2 = e.len;
        e.bCond(.ne, 0);
        e.ldrImm32(5, 4, @intCast(@offsetOf(Object, "elems_len") / 4));
        const b_slow3 = e.len;
        e.cbnz32(5, 0);
        e.ldrImm64(5, 21, @intCast(idx_slot));
        e.mov32(6, 5);
        e.ldrImm32(7, 3, @intCast(@offsetOf(Shape, "count") / 4));
        e.cmpReg32(6, 7);
        const rel_done2: i32 = if (pass == 1) @as(i32, @intCast(dst_idx)) - @as(i32, @intCast(e.len)) else 0;
        e.bCond(.hs, rel_done2);
        e.addImm64(7, 6, 1);
        e.orrReg64(7, 7, 25);
        e.strImm64(7, 21, @intCast(idx_slot));
        e.ldrImm64(7, 3, @intCast(@offsetOf(Shape, "table") / 8));
        e.ldrImm64(7, 7, 0);
        e.addRegLsl64(7, 7, 6, 4);
        e.ldrImm64(0, 7, 0);
        e.movz(2, 0xFFFC, 3);
        e.orrReg64(0, 0, 2);
        e.strImm64(0, 22, 0);
        e.addImm64(22, 22, 8);
        const b_ok = e.len;
        e.bImm(0);

        const slow_idx = e.len;
        e.buf[b_slow1] |= (@as(u32, @intCast(slow_idx - b_slow1)) & 0x7FFFF) << 5;
        e.buf[b_slow2] |= (@as(u32, @intCast(slow_idx - b_slow2)) & 0x7FFFF) << 5;
        e.buf[b_slow3] |= (@as(u32, @intCast(slow_idx - b_slow3)) & 0x7FFFF) << 5;
        emitBranchSlow(e, .for_in_next, dst_idx, pc_addr, next_pc_addr, epilogue_idx, pass);
        e.buf[b_ok] |= @as(u32, @intCast(e.len - b_ok)) & 0x03FF_FFFF;
        return;
    }
    emitBranchSlow(e, .for_in_next, dst_idx, pc_addr, next_pc_addr, epilogue_idx, pass);
}

pub fn emitCtorRetCheck(e: *Emitter, dst_idx: u32, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.ldur64(0, 22, -8);
    e.eorReg64(2, 0, 27);
    e.lsrImm64(2, 2, 48);
    const rel_obj: i32 = if (pass == 1) @as(i32, @intCast(dst_idx)) - @as(i32, @intCast(e.len)) else 0;
    e.cbz64(2, rel_obj);
    e.subImm64(2, 26, 2);
    e.cmpReg64(0, 2);
    const b_throw = e.len;
    e.bCond(.ne, 0);
    e.subImm64(22, 22, 8);
    const b_done = e.len;
    e.bImm(0);
    e.buf[b_throw] |= (@as(u32, @intCast(e.len - b_throw)) & 0x7FFFF) << 5;
    e.callHelper5(@intFromPtr(&jit.jitSlowOp), pc_addr, @intFromEnum(Op.ctor_ret_check), epilogue_idx, pass);
    e.buf[b_done] |= @as(u32, @intCast(e.len - b_done)) & 0x03FF_FFFF;
}

pub fn emitClassMisc(e: *Emitter, op: Op, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    switch (op) {
        .home => {
            e.ldrImm64(2, 20, @intCast(@offsetOf(Frame, "func") / 8));
            e.ldrImm64(2, 2, @intCast(@offsetOf(Object, "host") / 8));
            e.subImm64(0, 26, 2);
            const b1 = e.len;
            e.cbz64(2, 0);
            e.ldrImm64(2, 2, @intCast(@offsetOf(objmod.FnExtra, "home") / 8));
            const b2 = e.len;
            e.cbz64(2, 0);
            e.orrReg64(0, 2, 27);
            const done = e.len;
            e.buf[b1] |= (@as(u32, @intCast(done - b1)) & 0x7FFFF) << 5;
            e.buf[b2] |= (@as(u32, @intCast(done - b2)) & 0x7FFFF) << 5;
            e.strImm64(0, 22, 0);
            e.addImm64(22, 22, 8);
        },
        .check_super_once => {
            e.ldur64(0, 22, -8);
            e.addImm64(2, 26, 2);
            e.cmpReg64(0, 2);
            const b_ok = e.len;
            e.bCond(.eq, 0);
            e.callHelper5(@intFromPtr(&jit.jitSlowOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
            e.buf[b_ok] |= (@as(u32, @intCast(e.len - b_ok)) & 0x7FFFF) << 5;
            e.subImm64(22, 22, 8);
        },
        .run_fields => {
            e.ldur64(1, 22, -8);
            e.eorReg64(2, 1, 27);
            e.ldrImm64(2, 2, @intCast(@offsetOf(Object, "host") / 8));
            const b_no1 = e.len;
            e.cbz64(2, 0);
            e.ldrImm64(2, 2, @intCast(@offsetOf(objmod.FnExtra, "fields") / 8));
            e.subImm64(3, 26, 2);
            e.cmpReg64(2, 3);
            const b_no2 = e.len;
            e.bCond(.eq, 0);
            e.callHelper5(@intFromPtr(&jit.jitSlowOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
            e.mov64(22, 0);
            const b_done = e.len;
            e.bImm(0);
            const fast_pop = e.len;
            e.buf[b_no1] |= (@as(u32, @intCast(fast_pop - b_no1)) & 0x7FFFF) << 5;
            e.buf[b_no2] |= (@as(u32, @intCast(fast_pop - b_no2)) & 0x7FFFF) << 5;
            e.subImm64(22, 22, 16);
            e.buf[b_done] |= @as(u32, @intCast(e.len - b_done)) & 0x03FF_FFFF;
        },
        else => unreachable,
    }
}

pub fn emitMod(e: *Emitter, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.ldur64(0, 22, -16);
    e.ldur64(1, 22, -8);
    e.eorReg64(2, 0, 25);
    e.eorReg64(3, 1, 25);
    e.orrReg64(2, 2, 3);
    e.lsrImm64(2, 2, 48);
    const b1 = e.len;
    e.cbnz64(2, 0);
    const b2 = e.len;
    e.tbnz32(0, 31, 0);
    e.subsImm32(3, 1, 0);
    const b3 = e.len;
    e.bCond(.le, 0);
    e.sdiv32(2, 0, 1);
    e.msub32(0, 2, 1, 0);
    e.orrReg64(0, 0, 25);
    const b_done = e.len;
    e.bImm(0);
    const slow_idx = e.len;
    e.buf[b1] |= (@as(u32, @intCast(slow_idx - b1)) & 0x7FFFF) << 5;
    e.buf[b2] |= (@as(u32, @intCast(slow_idx - b2)) & 0x3FFF) << 5;
    e.buf[b3] |= (@as(u32, @intCast(slow_idx - b3)) & 0x7FFFF) << 5;
    e.callHelper5(@intFromPtr(&jit.jitBinaryOp), pc_addr, @intFromEnum(Op.mod), epilogue_idx, pass);
    e.buf[b_done] |= @as(u32, @intCast(e.len - b_done)) & 0x03FF_FFFF;
    e.stur64(0, 22, -16);
    e.subImm64(22, 22, 8);
}

pub fn emitBranchSlow(e: *Emitter, op: Op, dst_idx: u32, pc_addr: usize, next_pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.mov64(0, 19);
    e.mov64(1, 20);
    e.mov64(2, 22);
    e.movImm64(3, pc_addr);
    e.movz(4, @intFromEnum(op), 0);
    e.movImm64(5, next_pc_addr);
    e.movImm64(9, @intFromPtr(&jit.jitBranchSlowOp));
    e.blr(9);
    const ep_rel: i32 = if (pass == 1) @as(i32, @intCast(epilogue_idx)) - @as(i32, @intCast(e.len)) else 0;
    e.cbnz64(1, ep_rel);
    e.ubfm64(22, 0, 0, 62);
    e.lsrImm64(0, 0, 63);
    const rel: i32 = if (pass == 1) @as(i32, @intCast(dst_idx)) - @as(i32, @intCast(e.len)) else 0;
    e.cbnz64(0, rel);
}

pub fn emitArgsGet(e: *Emitter, slot: u32, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    if (slot < 4096) e.ldrImm64(0, 21, @intCast(slot)) else { e.movz(2, @intCast(slot), 0); e.ldrRegScaled64(0, 21, 2); }
    e.addImm64(2, 26, 2);
    e.cmpReg64(0, 2);
    const b_ready = e.len;
    e.bCond(.ne, 0);
    e.callHelper5(@intFromPtr(&jit.jitArgsGet), pc_addr, slot, epilogue_idx, pass);
    e.buf[b_ready] |= (@as(u32, @intCast(e.len - b_ready)) & 0x7FFFF) << 5;
    e.strImm64(0, 22, 0);
    e.addImm64(22, 22, 8);
}

pub fn emitArgsLen(e: *Emitter, slot: u32, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    if (slot < 4096) e.ldrImm64(0, 21, @intCast(slot)) else { e.movz(2, @intCast(slot), 0); e.ldrRegScaled64(0, 21, 2); }
    e.addImm64(2, 26, 2);
    e.cmpReg64(0, 2);
    const b_slow = e.len;
    e.bCond(.ne, 0);
    e.ldrImm32(0, 20, @intCast(@offsetOf(Frame, "argc") / 4));
    e.orrReg64(0, 0, 25);
    const b_done = e.len;
    e.bImm(0);
    e.buf[b_slow] |= (@as(u32, @intCast(e.len - b_slow)) & 0x7FFFF) << 5;
    e.callHelper5(@intFromPtr(&jit.jitArgsLen), pc_addr, slot, epilogue_idx, pass);
    e.buf[b_done] |= @as(u32, @intCast(e.len - b_done)) & 0x03FF_FFFF;
    e.strImm64(0, 22, 0);
    e.addImm64(22, 22, 8);
}

pub fn emitArgsElem(e: *Emitter, slot: u32, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.ldur64(1, 22, -8);
    if (slot < 4096) e.ldrImm64(0, 21, @intCast(slot)) else { e.movz(2, @intCast(slot), 0); e.ldrRegScaled64(0, 21, 2); }
    e.addImm64(2, 26, 2);
    e.cmpReg64(0, 2);
    const b_s1 = e.len;
    e.bCond(.ne, 0);
    e.eorReg64(2, 1, 25);
    e.lsrImm64(2, 2, 48);
    const b_s2 = e.len;
    e.cbnz64(2, 0);
    e.ldrImm32(2, 20, @intCast(@offsetOf(Frame, "argc") / 4));
    e.cmpReg32(1, 2);
    const b_s3 = e.len;
    e.bCond(.hs, 0);
    e.ldrImm64(3, 20, @intCast(@offsetOf(Frame, "args") / 8));
    e.mov32(4, 1);
    e.ldrRegScaled64(0, 3, 4);
    const b_done = e.len;
    e.bImm(0);
    const slow_idx = e.len;
    e.buf[b_s1] |= (@as(u32, @intCast(slow_idx - b_s1)) & 0x7FFFF) << 5;
    e.buf[b_s2] |= (@as(u32, @intCast(slow_idx - b_s2)) & 0x7FFFF) << 5;
    e.buf[b_s3] |= (@as(u32, @intCast(slow_idx - b_s3)) & 0x7FFFF) << 5;
    e.callHelper5(@intFromPtr(&jit.jitArgsElem), pc_addr, slot, epilogue_idx, pass);
    e.buf[b_done] |= @as(u32, @intCast(e.len - b_done)) & 0x03FF_FFFF;
    e.stur64(0, 22, -8);
}

pub fn emitPushTry(e: *Emitter, dst_bc: u32) void {
    e.ldrImm64(2, 20, @intCast(@offsetOf(Frame, "env") / 8));
    e.subImm64(0, 26, 2);
    const b_no_env = e.len;
    e.cbz64(2, 0);
    if (@offsetOf(@import("heap.zig").Env, "cell") != 0) e.addImm64(2, 2, @intCast(@offsetOf(@import("heap.zig").Env, "cell")));
    e.movz(3, 0xFFF8, 3);
    e.orrReg64(0, 2, 3);
    e.buf[b_no_env] |= (@as(u32, @intCast(e.len - b_no_env)) & 0x7FFFF) << 5;
    e.strImm64(0, 22, 0);
    e.movImm64(0, @import("frame.zig").catchMarker(dst_bc).bits);
    e.strImm64(0, 22, 1);
    e.addImm64(22, 22, 16);
}

pub fn emitOptChain(e: *Emitter, dst_idx: u32, extra: u12, pass: u1) void {
    e.ldur64(0, 22, -8);
    e.eorReg64(2, 0, 26);
    e.lsrImm64(2, 2, 1);
    e.cmpImm64(2, 1);
    const b_not_nullish = e.len;
    e.bCond(.ne, 0);
    if (extra != 0) e.subImm64(22, 22, extra);
    e.subImm64(0, 26, 2);
    e.stur64(0, 22, -8);
    const rel: i32 = if (pass == 1) @as(i32, @intCast(dst_idx)) - @as(i32, @intCast(e.len)) else 0;
    e.bImm(rel);
    e.buf[b_not_nullish] |= (@as(u32, @intCast(e.len - b_not_nullish)) & 0x7FFFF) << 5;
}
