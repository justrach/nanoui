//! Element and length ARM64 emitters for Baseline JIT (`get_length`, `get_elem`, `put_elem`).

const bc = @import("bytecode.zig");
const Op = bc.Op;
const objmod = @import("object.zig");
const Object = objmod.Object;
const JSString = @import("string.zig").JSString;
const Vm = @import("vm.zig").Vm;
const b_typed = @import("b_typed.zig");
const TypedData = b_typed.TypedData;
const BufferData = b_typed.BufferData;
const jit = @import("jit.zig");
const ops = @import("jit_arm64_ops.zig");
const Emitter = @import("jit_arm64_enc.zig").Emitter;

fn bufBytesPtrWordIdx() u12 {
    var dummy_byte: u8 = 0;
    const dummy_buf = BufferData{ .bytes = (&dummy_byte)[0..1] };
    const words: *const [@sizeOf(BufferData) / 8]usize = @ptrCast(&dummy_buf);
    for (words, 0..) |w, idx| {
        if (w == @intFromPtr(&dummy_byte)) return @intCast(idx);
    }
    unreachable;
}

const arr_proto_off = @offsetOf(Vm, "protos") + @offsetOf(@FieldType(Vm, "protos"), "array");
const obj_proto_off = @offsetOf(Vm, "protos") + @offsetOf(@FieldType(Vm, "protos"), "object");

const bad_append_flags: u16 = @bitCast(objmod.Flags{
    .extensible = false,
    .exotic = true,
    .elems_frozen = true,
    .elems_sealed = true,
    .length_readonly = true,
    .is_proto = true,
});

pub fn emitGetLength(e: *Emitter, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.ldur64(0, 22, -8);
    e.eorReg64(2, 0, 27);
    e.lsrImm64(3, 2, 48);
    const b_non_obj = e.len;
    e.cbnz64(3, 0);
    e.ldrbImm(3, 2, @intCast(@offsetOf(Object, "class")));
    e.cmpImm64(3, @intFromEnum(objmod.Class.array));
    const b2 = e.len;
    e.bCond(.ne, 0);
    e.ldrImm32(0, 2, @intCast(@offsetOf(Object, "arr_len") / 4));
    const b3 = e.len;
    e.tbnz32(0, 31, 0);
    e.orrReg64(0, 0, 25);
    const b_done1 = e.len;
    e.bImm(0);

    e.buf[b_non_obj] |= (@as(u32, @intCast(e.len - b_non_obj)) & 0x7FFFF) << 5;
    e.cmpImm64(3, 7);
    const b_not_str = e.len;
    e.bCond(.ne, 0);
    e.ubfm64(2, 0, 0, 47);
    e.ldrImm32(0, 2, @intCast(@offsetOf(JSString, "len16") / 4));
    e.orrReg64(0, 0, 25);
    const b_done2 = e.len;
    e.bImm(0);

    const slow_idx = e.len;
    e.buf[b_not_str] |= (@as(u32, @intCast(slow_idx - b_not_str)) & 0x7FFFF) << 5;
    e.buf[b2] |= (@as(u32, @intCast(slow_idx - b2)) & 0x7FFFF) << 5;
    e.buf[b3] |= (@as(u32, @intCast(slow_idx - b3)) & 0x3FFF) << 5;
    e.callHelper4(@intFromPtr(&jit.jitGetLength), pc_addr, epilogue_idx, pass);
    e.buf[b_done1] |= @as(u32, @intCast(e.len - b_done1)) & 0x03FF_FFFF;
    e.buf[b_done2] |= @as(u32, @intCast(e.len - b_done2)) & 0x03FF_FFFF;
    e.stur64(0, 22, -8);
}

pub fn emitGetElem(e: *Emitter, op: Op, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.ldur64(0, 22, -16);
    e.ldur64(1, 22, -8);
    e.eorReg64(2, 0, 27);
    e.eorReg64(3, 1, 25);
    e.orrReg64(3, 2, 3);
    e.lsrImm64(3, 3, 48);
    const b1 = e.len;
    e.cbnz64(3, 0);
    e.ldrhImm(3, 2, @intCast(@offsetOf(Object, "flags") / 2));
    const b2 = e.len;
    e.tbnz32(3, @bitOffsetOf(objmod.Flags, "exotic"), 0);
    e.ldrImm32(4, 2, @intCast(@offsetOf(Object, "elems_len") / 4));
    e.cmpReg32(1, 4);
    const b_oob = e.len;
    e.bCond(.hs, 0);
    e.ldrImm64(4, 2, @intCast(@offsetOf(Object, "elems") / 8));
    e.mov32(5, 1);
    e.ldrRegScaled64(0, 4, 5);
    e.addImm64(5, 26, 2);
    e.cmpReg64(0, 5);
    const b_hole = e.len;
    e.bCond(.eq, 0);
    const b_done = e.len;
    e.bImm(0);

    // Out-of-bounds or hole on clean plain Array (`i >= 0`, `shape == vm.array_root`, `!has_sparse`, `!proto_dirty`) -> `undefined`:
    const oob_idx = e.len;
    e.buf[b_oob] |= (@as(u32, @intCast(oob_idx - b_oob)) & 0x7FFFF) << 5;
    e.buf[b_hole] |= (@as(u32, @intCast(oob_idx - b_hole)) & 0x7FFFF) << 5;
    const b_neg = e.len;
    e.tbnz32(1, 31, 0);
    const b_sparse = e.len;
    e.tbnz32(3, @bitOffsetOf(objmod.Flags, "has_sparse"), 0);
    e.ldrbImm(4, 2, @intCast(@offsetOf(Object, "class")));
    e.cmpImm64(4, @intFromEnum(objmod.Class.array));
    const b_not_arr = e.len;
    e.bCond(.ne, 0);
    e.ldrImm64(4, 2, @intCast(@offsetOf(Object, "shape") / 8));
    e.ldrImm64(5, 19, @intCast(@offsetOf(Vm, "array_root") / 8));
    e.cmpReg64(4, 5);
    const b_arr_sh = e.len;
    e.bCond(.ne, 0);
    e.ldrImm64(4, 19, @intCast(arr_proto_off / 8));
    e.ldrhImm(4, 4, @intCast(@offsetOf(Object, "flags") / 2));
    e.ldrImm64(5, 19, @intCast(obj_proto_off / 8));
    e.ldrhImm(5, 5, @intCast(@offsetOf(Object, "flags") / 2));
    e.orrReg64(4, 4, 5);
    const b_arr_dirty = e.len;
    e.tbnz32(4, @bitOffsetOf(objmod.Flags, "proto_dirty"), 0);
    e.subImm64(0, 26, 2);
    const b_done_oob = e.len;
    e.bImm(0);

    // Non-(T_OBJECT & T_INT): check `T_OBJECT` + `T_STRING` via inline `vm.mega_ic`, or `T_STRING` + `T_INT`:
    e.buf[b1] |= (@as(u32, @intCast(e.len - b1)) & 0x7FFFF) << 5;
    e.lsrImm64(4, 2, 48);
    const b_not_obj = e.len;
    e.cbnz64(4, 0);
    // Receiver `x2` IS `T_OBJECT`; check if key `x1` is `T_STRING` (`tag == 0xFFFC`):
    e.lsrImm64(4, 1, 48);
    e.movz(5, 0xFFFC, 0);
    e.cmpReg64(4, 5);
    const b_not_str_key = e.len;
    e.bCond(.ne, 0);
    e.ldrhImm(3, 2, @intCast(@offsetOf(Object, "flags") / 2));
    const b_exotic2 = e.len;
    e.tbnz32(3, @bitOffsetOf(objmod.Flags, "exotic"), 0);
    const b_lazy2 = e.len;
    e.tbnz32(3, @bitOffsetOf(objmod.Flags, "lazy_fn"), 0);
    e.ubfm64(4, 1, 0, 47);
    e.ldrImm64(6, 4, @intCast(@offsetOf(JSString, "key") / 8));
    const b_no_pk = e.len;
    e.cbz64(6, 0);
    const b_idx_pk = e.len;
    e.tbnz32(6, 1, 0);
    e.ldrImm64(3, 2, @intCast(@offsetOf(Object, "shape") / 8));
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
    const b_m_miss_slot = e.len;
    e.bCond(.eq, 0);
    e.ldrImm64(3, 2, @intCast(@offsetOf(Object, "slots") / 8));
    e.ldrRegScaled64(0, 3, 5);
    const b_done_mown = e.len;
    e.bImm(0);

    e.buf[b_m_miss_slot] |= (@as(u32, @intCast(e.len - b_m_miss_slot)) & 0x7FFFF) << 5;
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
    const b_m_acc = e.len;
    e.tbnz32(5, 31, 0);
    e.ldrImm64(3, 6, @intCast(@offsetOf(Object, "slots") / 8));
    e.ldrRegScaled64(0, 3, 5);
    const b_done_mproto = e.len;
    e.bImm(0);

    e.buf[b_not_obj] |= (@as(u32, @intCast(e.len - b_not_obj)) & 0x7FFFF) << 5;
    e.cmpImm64(4, 7);
    const b_s1 = e.len;
    e.bCond(.ne, 0);
    e.eorReg64(4, 1, 25);
    e.lsrImm64(4, 4, 48);
    const b_s2 = e.len;
    e.cbnz64(4, 0);
    e.ubfm64(2, 0, 0, 47);
    e.ldrbImm(3, 2, @intCast(@offsetOf(JSString, "is_ascii")));
    const b_s3 = e.len;
    e.cbz32(3, 0);
    e.ldrbImm(3, 2, @intCast(@offsetOf(JSString, "is_rope")));
    const b_s4 = e.len;
    e.cbnz32(3, 0);
    e.ldrImm32(3, 2, @intCast(@offsetOf(JSString, "len16") / 4));
    e.cmpReg32(1, 3);
    const b_s5 = e.len;
    e.bCond(.hs, 0);
    e.ldrImm64(3, 2, @intCast(@offsetOf(JSString, "ptr") / 8));
    e.mov32(4, 1);
    e.ldrbReg(4, 3, 4);
    const char_off = @offsetOf(Vm, "char_strs");
    if (char_off < 4096) e.addImm64(3, 19, @intCast(char_off)) else { e.movz(3, @intCast(char_off), 0); e.addReg64(3, 19, 3); }
    e.ldrRegScaled64(0, 3, 4);
    e.movz(4, 0xFFFC, 3);
    e.orrReg64(0, 0, 4);
    const b_done_str = e.len;
    e.bImm(0);

    // Inline TypedArray indexed read (`o.flags.exotic`, `o.class == .typedarray`, `0 <= i < d.len`, `!buf.detached`):
    e.buf[b2] |= (@as(u32, @intCast(e.len - b2)) & 0x3FFF) << 5;
    const b_ta_neg = e.len;
    e.tbnz32(1, 31, 0);
    e.ldrbImm(4, 2, @intCast(@offsetOf(Object, "class")));
    e.cmpImm64(4, @intFromEnum(objmod.Class.typedarray));
    const b_not_ta = e.len;
    e.bCond(.ne, 0);
    e.ldrImm64(4, 2, @intCast(@offsetOf(Object, "payload") / 8));
    e.ldrImm64(5, 4, @intCast(@offsetOf(TypedData, "len") / 8));
    e.mov32(6, 1);
    e.cmpReg64(6, 5);
    const b_ta_oob = e.len;
    e.bCond(.hs, 0);
    e.ldrImm64(5, 4, @intCast(@offsetOf(TypedData, "buffer") / 8));
    e.ldrImm64(5, 5, @intCast(@offsetOf(Object, "payload") / 8));
    e.ldrbImm(7, 5, @intCast(@offsetOf(BufferData, "detached")));
    const b_ta_det = e.len;
    e.cbnz32(7, 0);
    e.ldrImm64(7, 5, bufBytesPtrWordIdx());
    e.ldrImm64(8, 4, @intCast(@offsetOf(TypedData, "offset") / 8));
    e.addReg64(7, 7, 8);
    e.ldrbImm(8, 4, @intCast(@offsetOf(TypedData, "kind")));
    e.cmpImm64(8, @intFromEnum(b_typed.Kind.Float64));
    const b_not_f64 = e.len;
    e.bCond(.ne, 0);
    e.ldrRegScaled64(0, 7, 6);
    e.fmovToD(0, 0);
    ops.emitBoxNumberFromD0(e);
    const b_done_taf64 = e.len;
    e.bImm(0);
    e.buf[b_not_f64] |= (@as(u32, @intCast(e.len - b_not_f64)) & 0x7FFFF) << 5;
    e.cmpImm64(8, @intFromEnum(b_typed.Kind.Int32));
    const b_not_i32 = e.len;
    e.bCond(.ne, 0);
    e.ldrRegScaled32(0, 7, 6);
    e.orrReg64(0, 0, 25);
    const b_done_tai32 = e.len;
    e.bImm(0);
    e.buf[b_not_i32] |= (@as(u32, @intCast(e.len - b_not_i32)) & 0x7FFFF) << 5;
    e.cmpImm64(8, @intFromEnum(b_typed.Kind.Uint8));
    const b_is_u8 = e.len;
    e.bCond(.eq, 0);
    e.cmpImm64(8, @intFromEnum(b_typed.Kind.Uint8Clamped));
    const b_not_u8 = e.len;
    e.bCond(.ne, 0);
    e.buf[b_is_u8] |= (@as(u32, @intCast(e.len - b_is_u8)) & 0x7FFFF) << 5;
    e.ldrbReg(0, 7, 6);
    e.orrReg64(0, 0, 25);
    const b_done_tau8 = e.len;
    e.bImm(0);
    e.buf[b_not_u8] |= (@as(u32, @intCast(e.len - b_not_u8)) & 0x7FFFF) << 5;
    e.cmpImm64(8, @intFromEnum(b_typed.Kind.Uint32));
    const b_not_u32 = e.len;
    e.bCond(.ne, 0);
    e.ldrRegScaled32(0, 7, 6);
    const b_u32_hi = e.len;
    e.tbnz32(0, 31, 0);
    e.orrReg64(0, 0, 25);
    const b_done_tau32 = e.len;
    e.bImm(0);
    e.buf[b_not_u32] |= (@as(u32, @intCast(e.len - b_not_u32)) & 0x7FFFF) << 5;
    e.cmpImm64(8, @intFromEnum(b_typed.Kind.Uint16));
    const b_not_u16 = e.len;
    e.bCond(.ne, 0);
    e.ldrhRegScaled(0, 7, 6);
    e.orrReg64(0, 0, 25);
    const b_done_tau16 = e.len;
    e.bImm(0);

    const slow_idx = e.len;
    inline for (.{ b_s1, b_s2, b_s3, b_s4, b_s5, b_not_arr, b_arr_sh, b_not_str_key, b_no_pk, b_m_sh, b_m_key, b_m_mep, b_m_hep, b_m_hsh, b_not_ta, b_ta_oob, b_ta_det, b_not_u16 }) |bi| {
        e.buf[bi] |= (@as(u32, @intCast(slow_idx - bi)) & 0x7FFFF) << 5;
    }
    inline for (.{ b_ta_neg, b_u32_hi, b_neg, b_sparse, b_arr_dirty, b_exotic2, b_lazy2, b_idx_pk, b_m_acc }) |bi| {
        e.buf[bi] |= (@as(u32, @intCast(slow_idx - bi)) & 0x3FFF) << 5;
    }
    e.callHelper4(@intFromPtr(&jit.jitGetElem), pc_addr, epilogue_idx, pass);
    inline for (.{ b_done, b_done_oob, b_done_mown, b_done_mmiss, b_done_mproto, b_done_str, b_done_taf64, b_done_tai32, b_done_tau8, b_done_tau32, b_done_tau16 }) |bi| {
        e.buf[bi] |= @as(u32, @intCast(e.len - bi)) & 0x03FF_FFFF;
    }
    if (op == .get_elem) {
        e.stur64(0, 22, -16);
        e.subImm64(22, 22, 8);
    } else {
        e.stur64(0, 22, -8);
    }
}

pub fn emitPutElem(e: *Emitter, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    e.ldur64(0, 22, -24);
    e.ldur64(1, 22, -16);
    e.ldur64(6, 22, -8);
    e.eorReg64(2, 0, 27);
    e.eorReg64(3, 1, 25);
    e.orrReg64(3, 2, 3);
    e.lsrImm64(3, 3, 48);
    const b1 = e.len;
    e.cbnz64(3, 0);
    e.ldrhImm(3, 2, @intCast(@offsetOf(Object, "flags") / 2));
    const b2 = e.len;
    e.tbnz32(3, @bitOffsetOf(objmod.Flags, "exotic"), 0);
    const b3 = e.len;
    e.tbnz32(3, @bitOffsetOf(objmod.Flags, "elems_frozen"), 0);
    e.ldrImm32(4, 2, @intCast(@offsetOf(Object, "elems_len") / 4));
    e.cmpReg32(1, 4);
    const b_append = e.len;
    e.bCond(.hs, 0);
    e.ldrImm64(4, 2, @intCast(@offsetOf(Object, "elems") / 8));
    e.mov32(5, 1);
    e.ldrRegScaled64(7, 4, 5);
    e.addImm64(8, 26, 2);
    e.cmpReg64(7, 8);
    const b5 = e.len;
    e.bCond(.eq, 0);
    e.strRegScaled64(6, 4, 5);
    e.stur64(6, 22, -24);
    e.subImm64(22, 22, 16);
    const b_done = e.len;
    e.bImm(0);

    // Dense array append (`i == elems_len and i < elems_cap`) on clean Array:
    e.buf[b_append] |= (@as(u32, @intCast(e.len - b_append)) & 0x7FFFF) << 5;
    const b_not_eq = e.len;
    e.bCond(.ne, 0);
    e.ldrImm32(5, 2, @intCast(@offsetOf(Object, "elems_cap") / 4));
    e.cmpReg32(1, 5);
    const b_full = e.len;
    e.bCond(.hs, 0);
    e.ldrbImm(5, 2, @intCast(@offsetOf(Object, "class")));
    e.cmpImm64(5, @intFromEnum(objmod.Class.array));
    const b_not_arr = e.len;
    e.bCond(.ne, 0);
    e.movz(5, bad_append_flags, 0);
    e.andReg32(5, 3, 5);
    const b_bad_fl = e.len;
    e.cbnz32(5, 0);
    const b_not_ext = e.len;
    e.tbz32(3, @bitOffsetOf(objmod.Flags, "extensible"), 0);
    e.ldrImm64(5, 2, @intCast(@offsetOf(Object, "shape") / 8));
    e.ldrImm64(7, 5, @intCast(@offsetOf(@import("shape.zig").Shape, "proto") / 8));
    e.ldrImm64(8, 19, @intCast(arr_proto_off / 8));
    e.cmpReg64(7, 8);
    const b_bad_pr = e.len;
    e.bCond(.ne, 0);
    e.ldrhImm(7, 8, @intCast(@offsetOf(Object, "flags") / 2));
    e.ldrImm64(8, 19, @intCast(obj_proto_off / 8));
    e.ldrhImm(8, 8, @intCast(@offsetOf(Object, "flags") / 2));
    e.orrReg64(7, 7, 8);
    const b_dirty = e.len;
    e.tbnz32(7, @bitOffsetOf(objmod.Flags, "proto_dirty"), 0);
    e.ldrImm64(5, 2, @intCast(@offsetOf(Object, "elems") / 8));
    e.mov32(7, 1);
    e.strRegScaled64(6, 5, 7);
    e.addImm64(7, 7, 1);
    e.strImm32(7, 2, @intCast(@offsetOf(Object, "elems_len") / 4));
    e.ldrImm32(8, 2, @intCast(@offsetOf(Object, "arr_len") / 4));
    e.cmpReg32(7, 8);
    e.csel32(7, 7, 8, .hi);
    e.strImm32(7, 2, @intCast(@offsetOf(Object, "arr_len") / 4));
    e.stur64(6, 22, -24);
    e.subImm64(22, 22, 16);
    const b_done_app = e.len;
    e.bImm(0);

    // Inline TypedArray indexed write (`o.flags.exotic`, `o.class == .typedarray`, `0 <= i < d.len`, `!buf.detached`):
    e.buf[b2] |= (@as(u32, @intCast(e.len - b2)) & 0x3FFF) << 5;
    const b_ta_neg = e.len;
    e.tbnz32(1, 31, 0);
    e.ldrbImm(4, 2, @intCast(@offsetOf(Object, "class")));
    e.cmpImm64(4, @intFromEnum(objmod.Class.typedarray));
    const b_not_ta = e.len;
    e.bCond(.ne, 0);
    e.ldrImm64(4, 2, @intCast(@offsetOf(Object, "payload") / 8));
    e.ldrImm64(5, 4, @intCast(@offsetOf(TypedData, "len") / 8));
    e.mov32(7, 1);
    e.cmpReg64(7, 5);
    const b_ta_oob = e.len;
    e.bCond(.hs, 0);
    e.ldrImm64(5, 4, @intCast(@offsetOf(TypedData, "buffer") / 8));
    e.ldrImm64(5, 5, @intCast(@offsetOf(Object, "payload") / 8));
    e.ldrbImm(8, 5, @intCast(@offsetOf(BufferData, "detached")));
    const b_ta_det = e.len;
    e.cbnz32(8, 0);
    e.ldrImm64(5, 5, bufBytesPtrWordIdx());
    e.ldrImm64(8, 4, @intCast(@offsetOf(TypedData, "offset") / 8));
    e.addReg64(5, 5, 8);
    e.ldrbImm(8, 4, @intCast(@offsetOf(TypedData, "kind")));
    e.cmpImm64(8, @intFromEnum(b_typed.Kind.Float64));
    const b_not_f64 = e.len;
    e.bCond(.ne, 0);
    e.cmpReg64(6, 25);
    const b_f64_dbl = e.len;
    e.bCond(.lo, 0);
    e.eorReg64(8, 6, 25);
    e.lsrImm64(8, 8, 48);
    const b_f64_not_num = e.len;
    e.cbnz64(8, 0);
    e.scvtf32(0, 6);
    e.fmovFromD(8, 0);
    e.strRegScaled64(8, 5, 7);
    const b_ta_stored1 = e.len;
    e.bImm(0);
    e.buf[b_f64_dbl] |= (@as(u32, @intCast(e.len - b_f64_dbl)) & 0x7FFFF) << 5;
    e.strRegScaled64(6, 5, 7);
    const b_ta_stored2 = e.len;
    e.bImm(0);
    e.buf[b_not_f64] |= (@as(u32, @intCast(e.len - b_not_f64)) & 0x7FFFF) << 5;
    e.eorReg64(4, 6, 25);
    e.lsrImm64(4, 4, 48);
    const b_ta_not_int = e.len;
    e.cbnz64(4, 0);
    e.cmpImm64(8, @intFromEnum(b_typed.Kind.Int32));
    const b_is_32 = e.len;
    e.bCond(.eq, 0);
    e.cmpImm64(8, @intFromEnum(b_typed.Kind.Uint32));
    const b_not_32 = e.len;
    e.bCond(.ne, 0);
    e.buf[b_is_32] |= (@as(u32, @intCast(e.len - b_is_32)) & 0x7FFFF) << 5;
    e.strRegScaled32(6, 5, 7);
    const b_ta_stored3 = e.len;
    e.bImm(0);
    e.buf[b_not_32] |= (@as(u32, @intCast(e.len - b_not_32)) & 0x7FFFF) << 5;
    e.cmpImm64(8, @intFromEnum(b_typed.Kind.Uint8));
    const b_is_8 = e.len;
    e.bCond(.eq, 0);
    e.cmpImm64(8, @intFromEnum(b_typed.Kind.Int8));
    const b_not_8 = e.len;
    e.bCond(.ne, 0);
    e.buf[b_is_8] |= (@as(u32, @intCast(e.len - b_is_8)) & 0x7FFFF) << 5;
    e.strbReg(6, 5, 7);
    const ta_commit = e.len;
    e.buf[b_ta_stored1] |= @as(u32, @intCast(ta_commit - b_ta_stored1)) & 0x03FF_FFFF;
    e.buf[b_ta_stored2] |= @as(u32, @intCast(ta_commit - b_ta_stored2)) & 0x03FF_FFFF;
    e.buf[b_ta_stored3] |= @as(u32, @intCast(ta_commit - b_ta_stored3)) & 0x03FF_FFFF;
    e.stur64(6, 22, -24);
    e.subImm64(22, 22, 16);
    const b_done_ta = e.len;
    e.bImm(0);

    const slow_idx = e.len;
    inline for (.{ b1, b5, b_not_eq, b_full, b_not_arr, b_bad_fl, b_bad_pr, b_not_ta, b_ta_oob, b_ta_det, b_f64_not_num, b_ta_not_int, b_not_8 }) |bi| {
        e.buf[bi] |= (@as(u32, @intCast(slow_idx - bi)) & 0x7FFFF) << 5;
    }
    inline for (.{ b_ta_neg, b3, b_not_ext, b_dirty }) |bi| {
        e.buf[bi] |= (@as(u32, @intCast(slow_idx - bi)) & 0x3FFF) << 5;
    }
    e.callHelper4(@intFromPtr(&jit.jitPutElem), pc_addr, epilogue_idx, pass);
    e.ldur64(0, 22, -8);
    e.stur64(0, 22, -24);
    e.subImm64(22, 22, 16);
    e.buf[b_done] |= @as(u32, @intCast(e.len - b_done)) & 0x03FF_FFFF;
    e.buf[b_done_app] |= @as(u32, @intCast(e.len - b_done_app)) & 0x03FF_FFFF;
    e.buf[b_done_ta] |= @as(u32, @intCast(e.len - b_done_ta)) & 0x03FF_FFFF;
}

pub fn emitMiscOp(e: *Emitter, op: Op, pc_ptr: [*]const u8, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
    switch (op) {
        .get_super_ctor => {
            e.ldur64(0, 22, -8);
            e.eorReg64(2, 0, 27);
            e.ldrbImm(3, 2, @intCast(@offsetOf(Object, "flags")));
            const b1 = e.len;
            e.tbnz32(3, @bitOffsetOf(objmod.Flags, "exotic"), 0);
            e.ldrImm64(2, 2, @intCast(@offsetOf(Object, "shape") / 8));
            e.ldrImm64(2, 2, @intCast(@offsetOf(@import("shape.zig").Shape, "proto") / 8));
            const b2 = e.len;
            e.cbz64(2, 0);
            e.ldrbImm(3, 2, @intCast(@offsetOf(Object, "flags")));
            const b3 = e.len;
            e.tbz32(3, @bitOffsetOf(objmod.Flags, "constructor"), 0);
            e.orrReg64(0, 2, 27);
            e.stur64(0, 22, -8);
            const b_done = e.len;
            e.bImm(0);
            const slow_idx = e.len;
            e.buf[b1] |= (@as(u32, @intCast(slow_idx - b1)) & 0x3FFF) << 5;
            e.buf[b2] |= (@as(u32, @intCast(slow_idx - b2)) & 0x7FFFF) << 5;
            e.buf[b3] |= (@as(u32, @intCast(slow_idx - b3)) & 0x3FFF) << 5;
            e.callHelper5(@intFromPtr(&jit.jitSlowOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
            e.mov64(22, 0);
            e.buf[b_done] |= @as(u32, @intCast(e.len - b_done)) & 0x03FF_FFFF;
        },
        .super_call => {
            const argc = @import("std").mem.readInt(u16, (pc_ptr + 1)[0..2], .little);
            e.callHelper5(@intFromPtr(&jit.jitSuperCall), pc_addr + 3, argc, epilogue_idx, pass);
            e.mov64(22, 0);
        },
        .super_get => {
            e.callHelper4(@intFromPtr(&jit.jitSuperGet), pc_addr, epilogue_idx, pass);
            e.stur64(0, 22, -24);
            e.subImm64(22, 22, 16);
        },
        .define_method => {
            e.callHelper5(@intFromPtr(&jit.jitDefineMethod), pc_addr, pc_ptr[1], epilogue_idx, pass);
            e.subImm64(22, 22, 16);
        },
        else => {
            e.callHelper5(@intFromPtr(&jit.jitSlowOp), pc_addr, @intFromEnum(op), epilogue_idx, pass);
            e.mov64(22, 0);
        },
    }
}
