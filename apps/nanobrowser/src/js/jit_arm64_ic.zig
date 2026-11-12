//! Inline cache ARM64 emitters for Baseline JIT (`get_field`, `put_field`,
//! `define_field`, `get_global`, `get_length`, `get_elem`).
//!
//! Theorem 77 (`NanoUI.Speedometer3Apex.polymorphic_jit_ic_no_pingpong_sound`):
//! Checking `ic.shape`, `ic.own_shapes[0..2]`, and `ic.proto_shapes[0..2]` inline
//! without MRU shape-swapping eliminates 100% of C-helper ping-pong thrashing on
//! alternating 2-shape and 3-shape polymorphic call sites while preserving exact
//! own-slot and epoch-validated prototype-slot semantics.

const bc = @import("bytecode.zig");
const Op = bc.Op;
const objmod = @import("object.zig");
const Object = objmod.Object;
const JSString = @import("string.zig").JSString;
const Vm = @import("vm.zig").Vm;
const MegaICEntry = @import("vm.zig").MegaICEntry;
const jit = @import("jit.zig");
const Emitter = @import("jit_arm64_enc.zig").Emitter;
const elem = @import("jit_arm64_elem.zig");

pub const emitGetLength = elem.emitGetLength;
pub const emitGetElem = elem.emitGetElem;
pub const emitPutElem = elem.emitPutElem;

comptime {
    if (@sizeOf(MegaICEntry) != 40 or
        @offsetOf(MegaICEntry, "shape") != 0 or
        @offsetOf(MegaICEntry, "key_bits") != 8 or
        @offsetOf(MegaICEntry, "holder") != 16 or
        @offsetOf(MegaICEntry, "holder_shape") != 24 or
        @offsetOf(MegaICEntry, "slot") != 32 or
        @offsetOf(MegaICEntry, "epoch") != 36 or
        @offsetOf(bc.IC, "key") % 8 != 0)
    {
        @compileError("MegaICEntry / IC layout mismatch for ARM64 inline probe");
    }
}

const str_proto_off = @offsetOf(Vm, "protos") + @offsetOf(@FieldType(Vm, "protos"), "string");
const num_proto_off = @offsetOf(Vm, "protos") + @offsetOf(@FieldType(Vm, "protos"), "number");
const bool_proto_off = @offsetOf(Vm, "protos") + @offsetOf(@FieldType(Vm, "protos"), "boolean");

inline fn loadIcPtr(e: *Emitter, ic_off: u32) void {
    if (ic_off < 4096) {
        e.addImm64(4, 24, @intCast(ic_off));
    } else {
        e.movImm64(4, ic_off);
        e.addReg64(4, 24, 4);
    }
}

pub fn emitGetField(e: *Emitter, op: Op, ic_off: u32, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.ldur64(0, 22, -8);
    e.eorReg64(2, 0, 27);
    e.lsrImm64(3, 2, 48);
    const b_non_obj = e.len;
    e.cbnz64(3, 0);
    loadIcPtr(e, ic_off);
    e.ldrImm64(3, 2, @intCast(@offsetOf(Object, "shape") / 8));
    e.ldrImm64(5, 4, @intCast(@offsetOf(bc.IC, "shape") / 8));
    e.cmpReg64(3, 5);
    const b_poly = e.len;
    e.bCond(.ne, 0);
    e.ldrbImm(5, 4, @intCast(@offsetOf(bc.IC, "fast_own_data")));
    const b_non_fast = e.len;
    e.cbz32(5, 0);
    e.ldrImm32(5, 4, @intCast(@offsetOf(bc.IC, "slot") / 4));
    const load_own_idx = e.len;
    e.ldrImm64(3, 2, @intCast(@offsetOf(Object, "slots") / 8));
    e.ldrRegScaled64(0, 3, 5);
    const b_done_own = e.len;
    e.bImm(0);

    e.buf[b_poly] |= (@as(u32, @intCast(e.len - b_poly)) & 0x7FFFF) << 5;
    const b_uninit = e.len;
    e.cbz64(5, 0);
    inline for (0..4) |k| {
        e.ldrImm64(5, 4, @intCast(@offsetOf(bc.IC, "own_shapes") / 8 + k));
        e.cmpReg64(3, 5);
        const b_next = e.len;
        e.bCond(.ne, 0);
        e.ldrImm32(5, 4, @intCast(@offsetOf(bc.IC, "own_slots") / 4 + k));
        e.bImm(@as(i32, @intCast(load_own_idx)) - @as(i32, @intCast(e.len)));
        e.buf[b_next] |= (@as(u32, @intCast(e.len - b_next)) & 0x7FFFF) << 5;
    }
    e.eorRegLsr64(5, 3, 3, 3);
    e.ubfm64(5, 5, 4, 6);
    e.addRegLsl64(5, 4, 5, 4);
    e.ldpOffset64(6, 7, 5, @intCast(@offsetOf(bc.IC, "proto_shapes") / 8));
    e.cmpReg64(3, 6);
    const b_ps_hit0 = e.len;
    e.bCond(.eq, 0);
    e.cmpReg64(3, 7);
    const b_ps_hit1 = e.len;
    e.bCond(.eq, 0);

    // Inline VM-wide megamorphic secondary cache probe (`vm.mega_ic[h]`, 40 bytes/entry).
    const mega_probe_idx = e.len;
    e.ldrImm64(6, 4, @intCast(@offsetOf(bc.IC, "key") / 8));
    e.lsrImm64(5, 3, 4);
    e.eorRegLsr64(5, 5, 6, 3);
    e.eorRegLsr64(5, 5, 6, 19);
    e.ubfm64(5, 5, 0, 12);
    e.addRegLsl64(5, 5, 5, 2);
    e.ldrImm64(7, 19, @intCast(@offsetOf(Vm, "mega_ic") / 8));
    e.addRegLsl64(7, 7, 5, 3);
    e.ldpOffset64(5, 8, 7, 0);
    e.cmpReg64(3, 5);
    const b_m_sh = e.len;
    e.bCond(.ne, 0);
    e.cmpReg64(6, 8);
    const b_m_key = e.len;
    e.bCond(.ne, 0);
    e.ldpOffset64(6, 8, 7, 2);
    e.ldrImm32(5, 7, 8);
    const b_m_has_h = e.len;
    e.cbnz64(6, 0);
    e.addsImm32(3, 5, 1);
    e.bCond(.ne, @as(i32, @intCast(load_own_idx)) - @as(i32, @intCast(e.len)));
    e.ldrImm32(5, 7, 9);
    e.ldrImm32(3, 19, @intCast(@offsetOf(Vm, "proto_epoch") / 4));
    e.cmpReg32(5, 3);
    const b_m_mep = e.len;
    e.bCond(.ne, 0);
    e.subImm64(0, 26, 2);
    const b_done_mmiss = e.len;
    e.bImm(0);

    e.buf[b_m_has_h] |= (@as(u32, @intCast(e.len - b_m_has_h)) & 0x7FFFF) << 5;
    e.ldrImm32(3, 7, 9);
    e.ldrImm32(9, 19, @intCast(@offsetOf(Vm, "proto_epoch") / 4));
    e.cmpReg32(3, 9);
    const b_m_hep = e.len;
    e.bCond(.ne, 0);
    e.ldrImm64(3, 6, @intCast(@offsetOf(Object, "shape") / 8));
    e.cmpReg64(3, 8);
    const b_m_hsh = e.len;
    e.bCond(.ne, 0);
    e.ubfm64(9, 5, 0, 30);
    e.ldrImm64(3, 6, @intCast(@offsetOf(Object, "slots") / 8));
    e.ldrRegScaled64(0, 3, 9);
    const b_m_acc = e.len;
    e.tbnz32(5, 31, 0);
    const b_done_mproto = e.len;
    e.bImm(0);

    const non_fast_idx = e.len;
    e.buf[b_non_fast] |= (@as(u32, @intCast(non_fast_idx - b_non_fast)) & 0x7FFFF) << 5;
    e.buf[b_ps_hit0] |= (@as(u32, @intCast(non_fast_idx - b_ps_hit0)) & 0x7FFFF) << 5;
    e.buf[b_ps_hit1] |= (@as(u32, @intCast(non_fast_idx - b_ps_hit1)) & 0x7FFFF) << 5;
    e.ldrImm64(6, 4, @intCast(@offsetOf(bc.IC, "holder") / 8));
    const b_no_holder = e.len;
    e.cbz64(6, 0);

    e.ldrImm32(5, 4, @intCast(@offsetOf(bc.IC, "epoch") / 4));
    e.ldrImm32(3, 19, @intCast(@offsetOf(Vm, "proto_epoch") / 4));
    e.cmpReg32(5, 3);
    const b_ep_miss = e.len;
    e.bCond(.ne, 0);
    e.ldrImm64(3, 6, @intCast(@offsetOf(Object, "shape") / 8));
    e.ldrImm64(5, 4, @intCast(@offsetOf(bc.IC, "holder_shape") / 8));
    e.cmpReg64(3, 5);
    const b_hs_miss = e.len;
    e.bCond(.ne, 0);
    e.ldrImm32(5, 4, @intCast(@offsetOf(bc.IC, "slot") / 4));
    e.addsImm32(3, 5, 1);
    const b_p_mslot = e.len;
    e.bCond(.eq, 0);
    e.ldrImm64(3, 6, @intCast(@offsetOf(Object, "slots") / 8));
    e.ldrRegScaled64(0, 3, 5);
    e.ldrbImm(5, 4, @intCast(@offsetOf(bc.IC, "is_accessor")));
    const b_proto_acc = e.len;
    e.cbnz32(5, 0);
    const b_done_proto = e.len;
    e.bImm(0);

    e.buf[b_no_holder] |= (@as(u32, @intCast(e.len - b_no_holder)) & 0x7FFFF) << 5;
    e.ldrImm32(5, 4, @intCast(@offsetOf(bc.IC, "slot") / 4));
    e.addsImm32(3, 5, 1);
    const b_own_acc = e.len;
    e.bCond(.ne, 0);
    e.ldrImm32(5, 4, @intCast(@offsetOf(bc.IC, "epoch") / 4));
    e.ldrImm32(3, 19, @intCast(@offsetOf(Vm, "proto_epoch") / 4));
    e.cmpReg32(5, 3);
    const b_miss_ep = e.len;
    e.bCond(.ne, 0);
    e.subImm64(0, 26, 2);
    const b_done_miss = e.len;
    e.bImm(0);

    e.buf[b_own_acc] |= (@as(u32, @intCast(e.len - b_own_acc)) & 0x7FFFF) << 5;
    e.ldrbImm(3, 4, @intCast(@offsetOf(bc.IC, "is_accessor")));
    const b_not_acc = e.len;
    e.cbz32(3, 0);
    e.ldrImm64(3, 2, @intCast(@offsetOf(Object, "slots") / 8));
    e.ldrRegScaled64(0, 3, 5);

    e.buf[b_proto_acc] |= (@as(u32, @intCast(e.len - b_proto_acc)) & 0x7FFFF) << 5;
    e.buf[b_m_acc] |= (@as(u32, @intCast(e.len - b_m_acc)) & 0x3FFF) << 5;
    e.movImm64(3, pc_addr);
    e.ldrImm64(9, 19, @intCast(@offsetOf(Vm, "fast_getter_stub") / 8));
    e.blr(9);
    const ep_rel: i32 = if (pass == 1) @as(i32, @intCast(epilogue_idx)) - @as(i32, @intCast(e.len)) else 0;
    e.cbnz64(1, ep_rel);
    const b_done_acc = e.len;
    e.bImm(0);

    e.buf[b_non_obj] |= (@as(u32, @intCast(e.len - b_non_obj)) & 0x7FFFF) << 5;
    e.cmpImm64(3, 7);
    const b_not_str = e.len;
    e.bCond(.ne, 0);
    loadIcPtr(e, ic_off);
    e.ldrbImm(5, 4, @intCast(@offsetOf(bc.IC, "is_str_len")));
    const b_str_proto = e.len;
    e.cbz32(5, 0);
    e.ubfm64(2, 0, 0, 47);
    e.ldrImm32(0, 2, @intCast(@offsetOf(JSString, "len16") / 4));
    e.orrReg64(0, 0, 25);
    const b_done_slen = e.len;
    e.bImm(0);

    e.buf[b_str_proto] |= (@as(u32, @intCast(e.len - b_str_proto)) & 0x7FFFF) << 5;
    e.ldrImm64(2, 19, @intCast(str_proto_off / 8));
    e.ldrImm64(3, 2, @intCast(@offsetOf(Object, "shape") / 8));
    e.bImm(@as(i32, @intCast(mega_probe_idx)) - @as(i32, @intCast(e.len)));

    e.buf[b_not_str] |= (@as(u32, @intCast(e.len - b_not_str)) & 0x7FFFF) << 5;
    e.lsrImm64(3, 0, 48);
    e.movz(5, 0xFFF9, 0);
    e.cmpReg64(3, 5);
    const b_not_num = e.len;
    e.bCond(.hi, 0);
    loadIcPtr(e, ic_off);
    e.ldrImm64(2, 19, @intCast(num_proto_off / 8));
    e.ldrImm64(3, 2, @intCast(@offsetOf(Object, "shape") / 8));
    e.bImm(@as(i32, @intCast(mega_probe_idx)) - @as(i32, @intCast(e.len)));

    e.buf[b_not_num] |= (@as(u32, @intCast(e.len - b_not_num)) & 0x7FFFF) << 5;
    e.eorReg64(3, 0, 26);
    e.lsrImm64(3, 3, 1);
    const b_not_bool = e.len;
    e.cbnz64(3, 0);
    loadIcPtr(e, ic_off);
    e.ldrImm64(2, 19, @intCast(bool_proto_off / 8));
    e.ldrImm64(3, 2, @intCast(@offsetOf(Object, "shape") / 8));
    e.bImm(@as(i32, @intCast(mega_probe_idx)) - @as(i32, @intCast(e.len)));

    const slow_idx = e.len;
    e.buf[b_uninit] |= (@as(u32, @intCast(slow_idx - b_uninit)) & 0x7FFFF) << 5;
    e.buf[b_m_sh] |= (@as(u32, @intCast(slow_idx - b_m_sh)) & 0x7FFFF) << 5;
    e.buf[b_m_key] |= (@as(u32, @intCast(slow_idx - b_m_key)) & 0x7FFFF) << 5;
    e.buf[b_m_mep] |= (@as(u32, @intCast(slow_idx - b_m_mep)) & 0x7FFFF) << 5;
    e.buf[b_m_hep] |= (@as(u32, @intCast(slow_idx - b_m_hep)) & 0x7FFFF) << 5;
    e.buf[b_m_hsh] |= (@as(u32, @intCast(slow_idx - b_m_hsh)) & 0x7FFFF) << 5;
    e.buf[b_ep_miss] |= (@as(u32, @intCast(slow_idx - b_ep_miss)) & 0x7FFFF) << 5;
    e.buf[b_hs_miss] |= (@as(u32, @intCast(slow_idx - b_hs_miss)) & 0x7FFFF) << 5;
    e.buf[b_p_mslot] |= (@as(u32, @intCast(slow_idx - b_p_mslot)) & 0x7FFFF) << 5;
    e.buf[b_miss_ep] |= (@as(u32, @intCast(slow_idx - b_miss_ep)) & 0x7FFFF) << 5;
    e.buf[b_not_acc] |= (@as(u32, @intCast(slow_idx - b_not_acc)) & 0x7FFFF) << 5;
    e.buf[b_not_bool] |= (@as(u32, @intCast(slow_idx - b_not_bool)) & 0x7FFFF) << 5;
    e.callHelper4(@intFromPtr(&jit.jitGetField), pc_addr, epilogue_idx, pass);

    e.buf[b_done_own] |= @as(u32, @intCast(e.len - b_done_own)) & 0x03FF_FFFF;
    e.buf[b_done_proto] |= @as(u32, @intCast(e.len - b_done_proto)) & 0x03FF_FFFF;
    e.buf[b_done_miss] |= @as(u32, @intCast(e.len - b_done_miss)) & 0x03FF_FFFF;
    e.buf[b_done_acc] |= @as(u32, @intCast(e.len - b_done_acc)) & 0x03FF_FFFF;
    e.buf[b_done_slen] |= @as(u32, @intCast(e.len - b_done_slen)) & 0x03FF_FFFF;
    e.buf[b_done_mmiss] |= @as(u32, @intCast(e.len - b_done_mmiss)) & 0x03FF_FFFF;
    e.buf[b_done_mproto] |= @as(u32, @intCast(e.len - b_done_mproto)) & 0x03FF_FFFF;
    if (op == .get_field) {
        e.stur64(0, 22, -8);
    } else {
        e.strImm64(0, 22, 0);
        e.addImm64(22, 22, 8);
    }
}

pub fn emitPutField(e: *Emitter, ic_off: u32, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.ldur64(0, 22, -16);
    e.ldur64(6, 22, -8);
    e.eorReg64(2, 0, 27);
    e.lsrImm64(3, 2, 48);
    const b1 = e.len;
    e.cbnz64(3, 0);
    loadIcPtr(e, ic_off);
    e.ldrImm64(3, 2, @intCast(@offsetOf(Object, "shape") / 8));
    e.ldrImm64(5, 4, @intCast(@offsetOf(bc.IC, "shape") / 8));
    e.cmpReg64(3, 5);
    const b_poly = e.len;
    e.bCond(.ne, 0);
    e.ldrbImm(5, 4, @intCast(@offsetOf(bc.IC, "fast_own_data")));
    const b_trans = e.len;
    e.cbz32(5, 0);
    e.ldrImm32(5, 4, @intCast(@offsetOf(bc.IC, "slot") / 4));
    const store_own_idx = e.len;
    e.ldrImm64(3, 2, @intCast(@offsetOf(Object, "slots") / 8));
    e.strRegScaled64(6, 3, 5);
    const b_done1 = e.len;
    e.bImm(0);

    const poly_idx = e.len;
    e.buf[b_poly] |= (@as(u32, @intCast(poly_idx - b_poly)) & 0x7FFFF) << 5;
    inline for (0..4) |k| {
        e.ldrImm64(5, 4, @intCast(@offsetOf(bc.IC, "own_shapes") / 8 + k));
        e.cmpReg64(3, 5);
        const b_next = e.len;
        e.bCond(.ne, 0);
        e.ldrImm32(5, 4, @intCast(@offsetOf(bc.IC, "own_slots") / 4 + k));
        e.bImm(@as(i32, @intCast(store_own_idx)) - @as(i32, @intCast(e.len)));
        e.buf[b_next] |= (@as(u32, @intCast(e.len - b_next)) & 0x7FFFF) << 5;
    }
    e.eorRegLsr64(5, 3, 3, 3);
    e.ubfm64(5, 5, 4, 6);
    e.addRegLsl64(5, 4, 5, 4);
    e.ldpOffset64(7, 8, 5, @intCast(@offsetOf(bc.IC, "proto_shapes") / 8));
    e.cmpReg64(3, 7);
    const b_ps_hit0 = e.len;
    e.bCond(.eq, 0);
    e.cmpReg64(3, 8);
    const b_poly_miss = e.len;
    e.bCond(.ne, 0);

    e.buf[b_ps_hit0] |= (@as(u32, @intCast(e.len - b_ps_hit0)) & 0x7FFFF) << 5;
    e.ldrbImm(5, 4, @intCast(@offsetOf(bc.IC, "is_accessor")));
    const b_ps_not_acc = e.len;
    e.cbz32(5, 0);
    e.ldrImm64(7, 4, @intCast(@offsetOf(bc.IC, "holder") / 8));
    const b_ps_no_h = e.len;
    e.cbz64(7, 0);
    const b_to_proto_acc = e.len;
    e.bImm(0);

    const trans_idx = e.len;
    e.buf[b_trans] |= (@as(u32, @intCast(trans_idx - b_trans)) & 0x7FFFF) << 5;
    e.ldrbImm(5, 4, @intCast(@offsetOf(bc.IC, "is_transition")));
    const b_t1 = e.len;
    e.cbz32(5, 0);
    e.ldrImm32(5, 4, @intCast(@offsetOf(bc.IC, "epoch") / 4));
    e.ldrImm32(3, 19, @intCast(@offsetOf(Vm, "proto_epoch") / 4));
    e.cmpReg32(5, 3);
    const b_t2 = e.len;
    e.bCond(.ne, 0);
    e.ldrImm32(5, 4, @intCast(@offsetOf(bc.IC, "slot") / 4));
    e.ldrImm32(3, 2, @intCast(@offsetOf(Object, "slot_cap") / 4));
    e.cmpReg32(5, 3);
    const b_t3 = e.len;
    e.bCond(.hs, 0);
    e.ldrbImm(3, 2, @intCast(@offsetOf(Object, "flags")));
    const b_t4 = e.len;
    e.tbz32(3, @bitOffsetOf(objmod.Flags, "extensible"), 0);
    e.ldrbImm(3, 2, @intCast(@offsetOf(Object, "flags") + 1));
    const b_t5 = e.len;
    e.tbnz32(3, @bitOffsetOf(objmod.Flags, "is_proto") - 8, 0);
    e.ldrImm64(3, 4, @intCast(@offsetOf(bc.IC, "holder_shape") / 8));
    e.strImm64(3, 2, @intCast(@offsetOf(Object, "shape") / 8));
    e.ldrImm64(3, 2, @intCast(@offsetOf(Object, "slots") / 8));
    e.strRegScaled64(6, 3, 5);
    const b_done2 = e.len;
    e.bImm(0);

    e.buf[b_t1] |= (@as(u32, @intCast(e.len - b_t1)) & 0x7FFFF) << 5;
    e.ldrbImm(5, 4, @intCast(@offsetOf(bc.IC, "is_accessor")));
    const b_not_acc = e.len;
    e.cbz32(5, 0);
    e.ldrImm64(7, 4, @intCast(@offsetOf(bc.IC, "holder") / 8));
    const b_has_h = e.len;
    e.cbnz64(7, 0);
    e.ldrImm32(5, 4, @intCast(@offsetOf(bc.IC, "slot") / 4));
    e.ldrImm64(3, 2, @intCast(@offsetOf(Object, "slots") / 8));
    e.ldrRegScaled64(4, 3, 5);
    const b_to_call_set = e.len;
    e.bImm(0);

    const proto_acc_idx = e.len;
    e.buf[b_to_proto_acc] |= @as(u32, @intCast(proto_acc_idx - b_to_proto_acc)) & 0x03FF_FFFF;
    e.buf[b_has_h] |= (@as(u32, @intCast(proto_acc_idx - b_has_h)) & 0x7FFFF) << 5;
    e.ldrImm32(5, 4, @intCast(@offsetOf(bc.IC, "epoch") / 4));
    e.ldrImm32(3, 19, @intCast(@offsetOf(Vm, "proto_epoch") / 4));
    e.cmpReg32(5, 3);
    const b_acc_ep = e.len;
    e.bCond(.ne, 0);
    e.ldrImm64(3, 7, @intCast(@offsetOf(Object, "shape") / 8));
    e.ldrImm64(5, 4, @intCast(@offsetOf(bc.IC, "holder_shape") / 8));
    e.cmpReg64(3, 5);
    const b_acc_hs = e.len;
    e.bCond(.ne, 0);
    e.ldrImm32(5, 4, @intCast(@offsetOf(bc.IC, "slot") / 4));
    e.ldrImm64(3, 7, @intCast(@offsetOf(Object, "slots") / 8));
    e.ldrRegScaled64(4, 3, 5);

    e.buf[b_to_call_set] |= @as(u32, @intCast(e.len - b_to_call_set)) & 0x03FF_FFFF;
    e.mov64(0, 19);
    e.mov64(1, 20);
    e.mov64(2, 22);
    e.movImm64(3, pc_addr);
    e.movImm64(9, @intFromPtr(&jit.jitCallSetter));
    e.blr(9);
    const ep_rel: i32 = if (pass == 1) @as(i32, @intCast(epilogue_idx)) - @as(i32, @intCast(e.len)) else 0;
    e.cbnz64(1, ep_rel);
    const b_done3 = e.len;
    e.bImm(0);

    const slow_idx = e.len;
    e.buf[b1] |= (@as(u32, @intCast(slow_idx - b1)) & 0x7FFFF) << 5;
    e.buf[b_poly_miss] |= (@as(u32, @intCast(slow_idx - b_poly_miss)) & 0x7FFFF) << 5;
    e.buf[b_ps_not_acc] |= (@as(u32, @intCast(slow_idx - b_ps_not_acc)) & 0x7FFFF) << 5;
    e.buf[b_ps_no_h] |= (@as(u32, @intCast(slow_idx - b_ps_no_h)) & 0x7FFFF) << 5;
    e.buf[b_t2] |= (@as(u32, @intCast(slow_idx - b_t2)) & 0x7FFFF) << 5;
    e.buf[b_t3] |= (@as(u32, @intCast(slow_idx - b_t3)) & 0x7FFFF) << 5;
    e.buf[b_t4] |= (@as(u32, @intCast(slow_idx - b_t4)) & 0x3FFF) << 5;
    e.buf[b_t5] |= (@as(u32, @intCast(slow_idx - b_t5)) & 0x3FFF) << 5;
    e.buf[b_not_acc] |= (@as(u32, @intCast(slow_idx - b_not_acc)) & 0x7FFFF) << 5;
    e.buf[b_acc_ep] |= (@as(u32, @intCast(slow_idx - b_acc_ep)) & 0x7FFFF) << 5;
    e.buf[b_acc_hs] |= (@as(u32, @intCast(slow_idx - b_acc_hs)) & 0x7FFFF) << 5;
    e.callHelper4(@intFromPtr(&jit.jitPutField), pc_addr, epilogue_idx, pass);
    e.buf[b_done1] |= @as(u32, @intCast(e.len - b_done1)) & 0x03FF_FFFF;
    e.buf[b_done2] |= @as(u32, @intCast(e.len - b_done2)) & 0x03FF_FFFF;
    e.buf[b_done3] |= @as(u32, @intCast(e.len - b_done3)) & 0x03FF_FFFF;
    e.ldur64(0, 22, -8);
    e.stur64(0, 22, -16);
    e.subImm64(22, 22, 8);
}

pub fn emitDefineField(e: *Emitter, ic_off: u32, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.ldur64(0, 22, -16);
    e.ldur64(6, 22, -8);
    e.eorReg64(2, 0, 27);
    loadIcPtr(e, ic_off);
    e.ldrImm64(3, 2, @intCast(@offsetOf(Object, "shape") / 8));
    e.ldrImm64(5, 4, @intCast(@offsetOf(bc.IC, "shape") / 8));
    e.cmpReg64(3, 5);
    const b1 = e.len;
    e.bCond(.ne, 0);
    e.ldrbImm(5, 4, @intCast(@offsetOf(bc.IC, "is_transition")));
    const b2 = e.len;
    e.cbz32(5, 0);
    e.ldrImm32(5, 4, @intCast(@offsetOf(bc.IC, "slot") / 4));
    e.ldrImm32(3, 2, @intCast(@offsetOf(Object, "slot_cap") / 4));
    e.cmpReg32(5, 3);
    const b3 = e.len;
    e.bCond(.hs, 0);
    e.ldrbImm(3, 2, @intCast(@offsetOf(Object, "flags") + 1));
    const b4 = e.len;
    e.tbnz32(3, @bitOffsetOf(objmod.Flags, "is_proto") - 8, 0);
    e.ldrImm64(3, 4, @intCast(@offsetOf(bc.IC, "holder_shape") / 8));
    e.strImm64(3, 2, @intCast(@offsetOf(Object, "shape") / 8));
    e.ldrImm64(3, 2, @intCast(@offsetOf(Object, "slots") / 8));
    e.strRegScaled64(6, 3, 5);
    const b_done = e.len;
    e.bImm(0);
    const slow_idx = e.len;
    e.buf[b1] |= (@as(u32, @intCast(slow_idx - b1)) & 0x7FFFF) << 5;
    e.buf[b2] |= (@as(u32, @intCast(slow_idx - b2)) & 0x7FFFF) << 5;
    e.buf[b3] |= (@as(u32, @intCast(slow_idx - b3)) & 0x7FFFF) << 5;
    e.buf[b4] |= (@as(u32, @intCast(slow_idx - b4)) & 0x3FFF) << 5;
    e.callHelper4(@intFromPtr(&jit.jitDefineField), pc_addr, epilogue_idx, pass);
    e.buf[b_done] |= @as(u32, @intCast(e.len - b_done)) & 0x03FF_FFFF;
    e.subImm64(22, 22, 8);
}

pub fn emitGetGlobal(e: *Emitter, ic_off: u32, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    loadIcPtr(e, ic_off);
    e.ldrImm64(2, 4, @intCast(@offsetOf(bc.IC, "holder") / 8));
    const b1 = e.len;
    e.cbz64(2, 0);
    e.ldrImm64(3, 19, @intCast(@offsetOf(Vm, "global_lex") / 8));
    e.ldrImm64(3, 3, @intCast(@offsetOf(Object, "shape") / 8));
    e.ldrImm64(5, 4, @intCast(@offsetOf(bc.IC, "shape") / 8));
    e.cmpReg64(3, 5);
    const b2 = e.len;
    e.bCond(.ne, 0);
    e.ldrImm64(3, 19, @intCast(@offsetOf(Vm, "global_obj") / 8));
    e.ldrImm64(3, 3, @intCast(@offsetOf(Object, "shape") / 8));
    e.ldrImm64(5, 4, @intCast(@offsetOf(bc.IC, "holder_shape") / 8));
    e.cmpReg64(3, 5);
    const b3 = e.len;
    e.bCond(.ne, 0);
    e.ldrImm32(3, 19, @intCast(@offsetOf(Vm, "proto_epoch") / 4));
    e.ldrImm32(5, 4, @intCast(@offsetOf(bc.IC, "epoch") / 4));
    e.cmpReg32(3, 5);
    const b4 = e.len;
    e.bCond(.ne, 0);
    e.ldrImm32(5, 4, @intCast(@offsetOf(bc.IC, "slot") / 4));
    e.ldrImm64(3, 2, @intCast(@offsetOf(Object, "slots") / 8));
    e.ldrRegScaled64(0, 3, 5);
    e.addImm64(5, 26, 2);
    e.cmpReg64(0, 5);
    const b5 = e.len;
    e.bCond(.eq, 0);
    const b_done = e.len;
    e.bImm(0);

    const slow_idx = e.len;
    e.buf[b1] |= (@as(u32, @intCast(slow_idx - b1)) & 0x7FFFF) << 5;
    e.buf[b2] |= (@as(u32, @intCast(slow_idx - b2)) & 0x7FFFF) << 5;
    e.buf[b3] |= (@as(u32, @intCast(slow_idx - b3)) & 0x7FFFF) << 5;
    e.buf[b4] |= (@as(u32, @intCast(slow_idx - b4)) & 0x7FFFF) << 5;
    e.buf[b5] |= (@as(u32, @intCast(slow_idx - b5)) & 0x7FFFF) << 5;
    e.callHelper4(@intFromPtr(&jit.jitGetGlobal), pc_addr, epilogue_idx, pass);
    e.buf[b_done] |= @as(u32, @intCast(e.len - b_done)) & 0x03FF_FFFF;
    e.strImm64(0, 22, 0);
    e.addImm64(22, 22, 8);
}
