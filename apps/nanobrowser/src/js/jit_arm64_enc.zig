//! ARM64 (`aarch64`) machine code instruction encoder for the Baseline JIT.

const bc = @import("bytecode.zig");
const Op = bc.Op;
const objmod = @import("object.zig");
const Object = objmod.Object;
const jit = @import("jit.zig");

pub const Cond = enum(u4) {
    eq = 0x0,
    ne = 0x1,
    hs = 0x2,
    lo = 0x3,
    mi = 0x4,
    pl = 0x5,
    vs = 0x6,
    vc = 0x7,
    hi = 0x8,
    ls = 0x9,
    ge = 0xA,
    lt = 0xB,
    gt = 0xC,
    le = 0xD,
};

pub const max_bc_len = 131072;
pub const max_inst_words = 262144;

pub const Emitter = struct {
    buf: *[max_inst_words]u32,
    len: u32 = 0,
    overflow: bool = false,

    pub inline fn emit(e: *Emitter, inst: u32) void {
        if (e.len >= max_inst_words) { e.overflow = true; return; }
        e.buf[e.len] = inst;
        e.len += 1;
    }

    pub inline fn movz(e: *Emitter, rd: u5, imm16: u16, hw: u2) void { e.emit(0xD2800000 | (@as(u32, hw) << 21) | (@as(u32, imm16) << 5) | rd); }
    pub inline fn movk(e: *Emitter, rd: u5, imm16: u16, hw: u2) void { e.emit(0xF2800000 | (@as(u32, hw) << 21) | (@as(u32, imm16) << 5) | rd); }

    pub fn movImm64(e: *Emitter, rd: u5, val: u64) void {
        e.movz(rd, @truncate(val), 0);
        const w1: u16 = @truncate(val >> 16);
        const w2: u16 = @truncate(val >> 32);
        const w3: u16 = @truncate(val >> 48);
        if (w1 != 0) e.movk(rd, w1, 1);
        if (w2 != 0) e.movk(rd, w2, 2);
        if (w3 != 0) e.movk(rd, w3, 3);
    }

    pub inline fn mov64(e: *Emitter, rd: u5, rm: u5) void { e.emit(0xAA0003E0 | (@as(u32, rm) << 16) | rd); }
    pub inline fn mov32(e: *Emitter, rd: u5, rm: u5) void { e.emit(0x2A0003E0 | (@as(u32, rm) << 16) | rd); }
    pub inline fn mvn32(e: *Emitter, rd: u5, rm: u5) void { e.emit(0x2A2003E0 | (@as(u32, rm) << 16) | rd); }
    pub inline fn sxtw64(e: *Emitter, rd: u5, rn: u5) void { e.emit(0x93407C00 | (@as(u32, rn) << 5) | rd); }
    pub inline fn addReg64(e: *Emitter, rd: u5, rn: u5, rm: u5) void { e.emit(0x8B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd); }
    pub inline fn addRegLsl64(e: *Emitter, rd: u5, rn: u5, rm: u5, shift: u6) void { e.emit(0x8B000000 | (@as(u32, rm) << 16) | (@as(u32, shift) << 10) | (@as(u32, rn) << 5) | rd); }
    pub inline fn subReg64(e: *Emitter, rd: u5, rn: u5, rm: u5) void { e.emit(0xCB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd); }
    pub inline fn subRegLsl64(e: *Emitter, rd: u5, rn: u5, rm: u5, shift: u6) void { e.emit(0xCB000000 | (@as(u32, rm) << 16) | (@as(u32, shift) << 10) | (@as(u32, rn) << 5) | rd); }
    pub inline fn madd64(e: *Emitter, rd: u5, rn: u5, rm: u5, ra: u5) void { e.emit(0x9B000000 | (@as(u32, rm) << 16) | (@as(u32, ra) << 10) | (@as(u32, rn) << 5) | rd); }
    pub inline fn smull64(e: *Emitter, rd: u5, rn: u5, rm: u5) void { e.emit(0x9B207C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd); }
    pub inline fn msub32(e: *Emitter, rd: u5, rn: u5, rm: u5, ra: u5) void { e.emit(0x1B008000 | (@as(u32, rm) << 16) | (@as(u32, ra) << 10) | (@as(u32, rn) << 5) | rd); }
    pub inline fn sdiv32(e: *Emitter, rd: u5, rn: u5, rm: u5) void { e.emit(0x1AC00C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd); }
    pub inline fn csel32(e: *Emitter, rd: u5, rn: u5, rm: u5, cond: Cond) void { e.emit(0x1A800000 | (@as(u32, rm) << 16) | (@as(u32, @intFromEnum(cond)) << 12) | (@as(u32, rn) << 5) | rd); }
    pub inline fn scvtf32(e: *Emitter, dd: u5, wn: u5) void { e.emit(0x1E620000 | (@as(u32, wn) << 5) | dd); }
    pub inline fn scvtf64(e: *Emitter, dd: u5, xn: u5) void { e.emit(0x9E620000 | (@as(u32, xn) << 5) | dd); }
    pub inline fn fmovToD(e: *Emitter, dd: u5, xn: u5) void { e.emit(0x9E670000 | (@as(u32, xn) << 5) | dd); }
    pub inline fn fmovFromD(e: *Emitter, xd: u5, dn: u5) void { e.emit(0x9E660000 | (@as(u32, dn) << 5) | xd); }
    pub inline fn fmulD(e: *Emitter, dd: u5, dn: u5, dm: u5) void { e.emit(0x1E600800 | (@as(u32, dm) << 16) | (@as(u32, dn) << 5) | dd); }
    pub inline fn fdivD(e: *Emitter, dd: u5, dn: u5, dm: u5) void { e.emit(0x1E601800 | (@as(u32, dm) << 16) | (@as(u32, dn) << 5) | dd); }
    pub inline fn faddD(e: *Emitter, dd: u5, dn: u5, dm: u5) void { e.emit(0x1E602800 | (@as(u32, dm) << 16) | (@as(u32, dn) << 5) | dd); }
    pub inline fn fsubD(e: *Emitter, dd: u5, dn: u5, dm: u5) void { e.emit(0x1E603800 | (@as(u32, dm) << 16) | (@as(u32, dn) << 5) | dd); }
    pub inline fn fnegD(e: *Emitter, dd: u5, dn: u5) void { e.emit(0x1E614000 | (@as(u32, dn) << 5) | dd); }
    pub inline fn fcmpD(e: *Emitter, dn: u5, dm: u5) void { e.emit(0x1E602000 | (@as(u32, dm) << 16) | (@as(u32, dn) << 5)); }
    pub inline fn fjcvtzs(e: *Emitter, wd: u5, dn: u5) void { e.emit(0x1E7E0000 | (@as(u32, dn) << 5) | wd); }
    pub inline fn addImm64(e: *Emitter, rd: u5, rn: u5, imm12: u12) void { e.emit(0x91000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rd); }
    pub inline fn subImm64(e: *Emitter, rd: u5, rn: u5, imm12: u12) void { e.emit(0xD1000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rd); }
    pub inline fn addsImm32(e: *Emitter, rd: u5, rn: u5, imm12: u12) void { e.emit(0x31000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rd); }
    pub inline fn subsImm32(e: *Emitter, rd: u5, rn: u5, imm12: u12) void { e.emit(0x71000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rd); }
    pub inline fn addsReg32(e: *Emitter, rd: u5, rn: u5, rm: u5) void { e.emit(0x2B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd); }
    pub inline fn subsReg32(e: *Emitter, rd: u5, rn: u5, rm: u5) void { e.emit(0x6B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd); }
    pub inline fn cmpReg32(e: *Emitter, rn: u5, rm: u5) void { e.emit(0x6B00001F | (@as(u32, rm) << 16) | (@as(u32, rn) << 5)); }
    pub inline fn cmpReg64(e: *Emitter, rn: u5, rm: u5) void { e.emit(0xEB00001F | (@as(u32, rm) << 16) | (@as(u32, rn) << 5)); }
    pub inline fn cmpImm64(e: *Emitter, rn: u5, imm12: u12) void { e.emit(0xF100001F | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5)); }
    pub inline fn andReg32(e: *Emitter, rd: u5, rn: u5, rm: u5) void { e.emit(0x0A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd); }
    pub inline fn orrReg32(e: *Emitter, rd: u5, rn: u5, rm: u5) void { e.emit(0x2A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd); }
    pub inline fn orrReg64(e: *Emitter, rd: u5, rn: u5, rm: u5) void { e.emit(0xAA000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd); }
    pub inline fn eorReg32(e: *Emitter, rd: u5, rn: u5, rm: u5) void { e.emit(0x4A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd); }
    pub inline fn eorReg64(e: *Emitter, rd: u5, rn: u5, rm: u5) void { e.emit(0xCA000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd); }
    pub inline fn eorRegLsr64(e: *Emitter, rd: u5, rn: u5, rm: u5, shift: u6) void { e.emit(0xCA400000 | (@as(u32, rm) << 16) | (@as(u32, shift) << 10) | (@as(u32, rn) << 5) | rd); }
    pub inline fn lslvReg32(e: *Emitter, rd: u5, rn: u5, rm: u5) void { e.emit(0x1AC02000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd); }
    pub inline fn lsrvReg32(e: *Emitter, rd: u5, rn: u5, rm: u5) void { e.emit(0x1AC02400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd); }
    pub inline fn asrvReg32(e: *Emitter, rd: u5, rn: u5, rm: u5) void { e.emit(0x1AC02800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd); }
    pub inline fn lsrImm64(e: *Emitter, rd: u5, rn: u5, shift: u6) void { e.emit(0xD340FC00 | (@as(u32, shift) << 16) | (@as(u32, rn) << 5) | rd); }
    pub inline fn ubfm64(e: *Emitter, rd: u5, rn: u5, immr: u6, imms: u6) void { e.emit(0xD3400000 | (@as(u32, immr) << 16) | (@as(u32, imms) << 10) | (@as(u32, rn) << 5) | rd); }
    pub inline fn cset64(e: *Emitter, rd: u5, cond: Cond) void { e.emit(0x9A9F07E0 | ((@as(u32, @intFromEnum(cond)) ^ 1) << 12) | rd); }
    pub inline fn ldrImm64(e: *Emitter, rt: u5, rn: u5, idx8: u12) void { e.emit(0xF9400000 | (@as(u32, idx8) << 10) | (@as(u32, rn) << 5) | rt); }
    pub inline fn strImm64(e: *Emitter, rt: u5, rn: u5, idx8: u12) void { e.emit(0xF9000000 | (@as(u32, idx8) << 10) | (@as(u32, rn) << 5) | rt); }
    pub inline fn ldrImm32(e: *Emitter, rt: u5, rn: u5, idx4: u12) void { e.emit(0xB9400000 | (@as(u32, idx4) << 10) | (@as(u32, rn) << 5) | rt); }
    pub inline fn strImm32(e: *Emitter, rt: u5, rn: u5, idx4: u12) void { e.emit(0xB9000000 | (@as(u32, idx4) << 10) | (@as(u32, rn) << 5) | rt); }
    pub inline fn ldrhImm(e: *Emitter, rt: u5, rn: u5, idx2: u12) void { e.emit(0x79400000 | (@as(u32, idx2) << 10) | (@as(u32, rn) << 5) | rt); }
    pub inline fn strhImm(e: *Emitter, rt: u5, rn: u5, idx2: u12) void { e.emit(0x79000000 | (@as(u32, idx2) << 10) | (@as(u32, rn) << 5) | rt); }
    pub inline fn ldrbImm(e: *Emitter, rt: u5, rn: u5, idx1: u12) void { e.emit(0x39400000 | (@as(u32, idx1) << 10) | (@as(u32, rn) << 5) | rt); }
    pub inline fn ldrbReg(e: *Emitter, rt: u5, rn: u5, rm: u5) void { e.emit(0x38606800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt); }
    pub inline fn strbReg(e: *Emitter, rt: u5, rn: u5, rm: u5) void { e.emit(0x38206800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt); }
    pub inline fn strbImm(e: *Emitter, rt: u5, rn: u5, idx1: u12) void { e.emit(0x39000000 | (@as(u32, idx1) << 10) | (@as(u32, rn) << 5) | rt); }
    pub inline fn ldrhRegScaled(e: *Emitter, rt: u5, rn: u5, rm: u5) void { e.emit(0x78607800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt); }
    pub inline fn ldrRegScaled32(e: *Emitter, rt: u5, rn: u5, rm: u5) void { e.emit(0xB8607800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt); }
    pub inline fn strRegScaled32(e: *Emitter, rt: u5, rn: u5, rm: u5) void { e.emit(0xB8207800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt); }
    pub inline fn ldrRegScaled64(e: *Emitter, rt: u5, rn: u5, rm: u5) void { e.emit(0xF8607800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt); }
    pub inline fn strRegScaled64(e: *Emitter, rt: u5, rn: u5, rm: u5) void { e.emit(0xF8207800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt); }
    pub inline fn ldur64(e: *Emitter, rt: u5, rn: u5, simm9: i9) void { e.emit(0xF8400000 | ((@as(u32, @bitCast(@as(i32, simm9))) & 0x1FF) << 12) | (@as(u32, rn) << 5) | rt); }
    pub inline fn stur64(e: *Emitter, rt: u5, rn: u5, simm9: i9) void { e.emit(0xF8000000 | ((@as(u32, @bitCast(@as(i32, simm9))) & 0x1FF) << 12) | (@as(u32, rn) << 5) | rt); }
    pub inline fn stpOffset64(e: *Emitter, rt1: u5, rt2: u5, rn: u5, simm7: i7) void { e.emit(0xA9000000 | ((@as(u32, @bitCast(@as(i32, simm7))) & 0x7F) << 15) | (@as(u32, rt2) << 10) | (@as(u32, rn) << 5) | rt1); }
    pub inline fn ldpOffset64(e: *Emitter, rt1: u5, rt2: u5, rn: u5, simm7: i7) void { e.emit(0xA9400000 | ((@as(u32, @bitCast(@as(i32, simm7))) & 0x7F) << 15) | (@as(u32, rt2) << 10) | (@as(u32, rn) << 5) | rt1); }
    pub inline fn stpPre64(e: *Emitter, rt1: u5, rt2: u5, rn: u5, simm7: i7) void { e.emit(0xA9800000 | ((@as(u32, @bitCast(@as(i32, simm7))) & 0x7F) << 15) | (@as(u32, rt2) << 10) | (@as(u32, rn) << 5) | rt1); }
    pub inline fn ldpPost64(e: *Emitter, rt1: u5, rt2: u5, rn: u5, simm7: i7) void { e.emit(0xA8C00000 | ((@as(u32, @bitCast(@as(i32, simm7))) & 0x7F) << 15) | (@as(u32, rt2) << 10) | (@as(u32, rn) << 5) | rt1); }
    pub inline fn bImm(e: *Emitter, offset_words: i32) void { e.emit(0x14000000 | (@as(u32, @bitCast(offset_words)) & 0x03FF_FFFF)); }
    pub inline fn blImm(e: *Emitter, offset_words: i32) void { e.emit(0x94000000 | (@as(u32, @bitCast(offset_words)) & 0x03FF_FFFF)); }

    pub inline fn bCond(e: *Emitter, cond: Cond, offset_words: i32) void {
        if (offset_words < -262144 or offset_words > 262143) e.overflow = true;
        e.emit(0x54000000 | ((@as(u32, @bitCast(offset_words)) & 0x7FFFF) << 5) | @intFromEnum(cond));
    }

    pub inline fn cbz64(e: *Emitter, rt: u5, offset_words: i32) void {
        if (offset_words < -262144 or offset_words > 262143) e.overflow = true;
        e.emit(0xB4000000 | ((@as(u32, @bitCast(offset_words)) & 0x7FFFF) << 5) | rt);
    }

    pub inline fn cbnz64(e: *Emitter, rt: u5, offset_words: i32) void {
        if (offset_words < -262144 or offset_words > 262143) e.overflow = true;
        e.emit(0xB5000000 | ((@as(u32, @bitCast(offset_words)) & 0x7FFFF) << 5) | rt);
    }

    pub inline fn cbz32(e: *Emitter, rt: u5, offset_words: i32) void {
        if (offset_words < -262144 or offset_words > 262143) e.overflow = true;
        e.emit(0x34000000 | ((@as(u32, @bitCast(offset_words)) & 0x7FFFF) << 5) | rt);
    }

    pub inline fn cbnz32(e: *Emitter, rt: u5, offset_words: i32) void {
        if (offset_words < -262144 or offset_words > 262143) e.overflow = true;
        e.emit(0x35000000 | ((@as(u32, @bitCast(offset_words)) & 0x7FFFF) << 5) | rt);
    }

    pub inline fn tbnz32(e: *Emitter, rt: u5, bit: u5, offset_words: i14) void {
        const bits: u32 = @as(u32, @bitCast(@as(i32, offset_words))) & 0x3FFF;
        e.emit(0x37000000 | (@as(u32, bit) << 19) | (bits << 5) | rt);
    }

    pub inline fn tbz32(e: *Emitter, rt: u5, bit: u5, offset_words: i14) void {
        const bits: u32 = @as(u32, @bitCast(@as(i32, offset_words))) & 0x3FFF;
        e.emit(0x36000000 | (@as(u32, bit) << 19) | (bits << 5) | rt);
    }

    pub inline fn br(e: *Emitter, rn: u5) void { e.emit(0xD61F0000 | (@as(u32, rn) << 5)); }
    pub inline fn blr(e: *Emitter, rn: u5) void { e.emit(0xD63F0000 | (@as(u32, rn) << 5)); }
    pub inline fn ret(e: *Emitter) void { e.emit(0xD65F03C0); }

    pub fn callHelper4(e: *Emitter, fn_addr: usize, pc_addr: usize, epilogue_idx: u32, pass: u1) void {
        e.mov64(0, 19);
        e.mov64(1, 20);
        e.mov64(2, 22);
        e.movImm64(3, pc_addr);
        e.movImm64(9, fn_addr);
        e.blr(9);
        const ep_rel: i32 = if (pass == 1) @as(i32, @intCast(epilogue_idx)) - @as(i32, @intCast(e.len)) else 0;
        e.cbnz64(1, ep_rel);
    }

    pub fn callHelper5(e: *Emitter, fn_addr: usize, pc_addr: usize, arg4: u32, epilogue_idx: u32, pass: u1) void {
        e.mov64(0, 19);
        e.mov64(1, 20);
        e.mov64(2, 22);
        e.movImm64(3, pc_addr);
        e.movz(4, @truncate(arg4), 0);
        if (arg4 >> 16 != 0) e.movk(4, @truncate(arg4 >> 16), 1);
        e.movImm64(9, fn_addr);
        e.blr(9);
        const ep_rel: i32 = if (pass == 1) @as(i32, @intCast(epilogue_idx)) - @as(i32, @intCast(e.len)) else 0;
        e.cbnz64(1, ep_rel);
    }

    /// Theorem 65 (`NanoUI.Speedometer3Apex.inline_jit_truthy_optchain_and_string_seq_equiv`):
    /// Inline ARM64 truthiness for `T_SPECIAL`, `T_INT`, and `T_OBJECT`.
    pub fn emitTruthyTest(e: *Emitter) void {
        e.eorReg64(2, 0, 26);
        e.cmpImm64(2, 3);
        const b_not_spec = e.len;
        e.bCond(.hi, 0);
        e.cmpImm64(2, 1);
        e.cset64(2, .eq);
        const b_done1 = e.len;
        e.bImm(0);
        const not_spec = e.len;
        e.buf[b_not_spec] |= (@as(u32, @intCast(not_spec - b_not_spec)) & 0x7FFFF) << 5;
        e.eorReg64(2, 0, 25);
        e.lsrImm64(2, 2, 48);
        const b_not_int = e.len;
        e.cbnz64(2, 0);
        e.mov32(2, 0);
        const b_done2 = e.len;
        e.bImm(0);
        const not_int = e.len;
        e.buf[b_not_int] |= (@as(u32, @intCast(not_int - b_not_int)) & 0x7FFFF) << 5;
        e.eorReg64(3, 0, 27);
        e.lsrImm64(2, 3, 48);
        const b_slow = e.len;
        e.cbnz64(2, 0);
        e.ldrbImm(3, 3, @intCast(@offsetOf(Object, "flags")));
        e.mov64(2, 0);
        const b_done3 = e.len;
        e.tbz32(3, @bitOffsetOf(objmod.Flags, "html_dda"), 0);
        const slow_idx = e.len;
        e.buf[b_slow] |= (@as(u32, @intCast(slow_idx - b_slow)) & 0x7FFFF) << 5;
        e.movImm64(9, @intFromPtr(&jit.jitTruthy));
        e.blr(9);
        e.mov64(2, 0);
        e.buf[b_done1] |= @as(u32, @intCast(e.len - b_done1)) & 0x03FF_FFFF;
        e.buf[b_done2] |= @as(u32, @intCast(e.len - b_done2)) & 0x03FF_FFFF;
        e.buf[b_done3] |= (@as(u32, @intCast(e.len - b_done3)) & 0x3FFF) << 5;
    }

    pub const emitGetField = @import("jit_arm64_ic.zig").emitGetField;
    pub const emitPutField = @import("jit_arm64_ic.zig").emitPutField;
    pub const emitDefineField = @import("jit_arm64_ic.zig").emitDefineField;
    pub const emitGetGlobal = @import("jit_arm64_ic.zig").emitGetGlobal;
    pub const emitGetLength = @import("jit_arm64_ic.zig").emitGetLength;
    pub const emitGetElem = @import("jit_arm64_ic.zig").emitGetElem;
    pub const emitPutElem = @import("jit_arm64_ic.zig").emitPutElem;
    pub const emitCompareOp = @import("jit_arm64_ops.zig").emitCompareOp;
    pub const emitBinaryOp = @import("jit_arm64_ops.zig").emitBinaryOp;
    pub const emitUnaryFast = @import("jit_arm64_ops.zig").emitUnaryFast;
};
