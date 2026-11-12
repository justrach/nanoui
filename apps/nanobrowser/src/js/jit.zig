//! Baseline JIT runtime: executable `MAP_JIT` slab allocator on `aarch64-macos`,
//! hot-function compilation dispatch, and C-ABI property/arithmetic helpers invoked by
//! emitted native machine code. Call/slow helpers live in `jit_calls.zig`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const value = @import("value.zig");
const Value = value.Value;
const PropKey = value.PropKey;
const bc = @import("bytecode.zig");
const Op = bc.Op;
const fr = @import("frame.zig");
const Frame = fr.Frame;
const objmod = @import("object.zig");
const Object = objmod.Object;
const ops = @import("ops.zig");
const str = @import("string.zig");
const icache = @import("interp_ic.zig");
const calls = @import("interp_call.zig");
const slow = @import("interp_slow.zig");
const typed = @import("b_typed.zig");
const arm64 = @import("jit_arm64.zig");
const arm64_stub = @import("jit_arm64_stub.zig");
const arm64_resume = @import("jit_arm64_resume.zig");
const jit_calls = @import("jit_calls.zig");

pub const enabled = builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos;
pub const getFastCallStub = arm64_stub.getOrBuildStub;
pub const getFastGetterStub = arm64_resume.getFastGetterStub;
pub const getFastArgsApplyStub = arm64_resume.getFastArgsApplyStub;

pub const JitResult = extern struct { bits: u64, err: u64 };
pub const JitFn = *const fn (vm: *Vm, f: *Frame, bp: [*]Value, sp: [*]Value) callconv(.c) JitResult;

pub const runEntry = jit_calls.runEntry;
pub const jitCallGetter = jit_calls.jitCallGetter;
pub const jitCallSetter = jit_calls.jitCallSetter;
pub const jitCall = jit_calls.jitCall;
pub const jitNew = jit_calls.jitNew;
pub const jitApply = jit_calls.jitApply;
pub const jitClosure = jit_calls.jitClosure;
pub const jitPushEnv = jit_calls.jitPushEnv;
pub const jitArrayFrom = jit_calls.jitArrayFrom;
pub const jitArguments = jit_calls.jitArguments;
pub const jitArgsGet = jit_calls.jitArgsGet;
pub const jitArgsLen = jit_calls.jitArgsLen;
pub const jitArgsElem = jit_calls.jitArgsElem;
pub const jitArgsApply = jit_calls.jitArgsApply;
pub const jitRest = jit_calls.jitRest;
pub const jitNewRegExp = jit_calls.jitNewRegExp;
pub const jitIn = jit_calls.jitIn;
pub const jitInstanceOf = jit_calls.jitInstanceOf;
pub const jitSuperCall = jit_calls.jitSuperCall;
pub const jitSuperGet = jit_calls.jitSuperGet;
pub const jitDefineMethod = jit_calls.jitDefineMethod;
pub const jitSlowOp = jit_calls.jitSlowOp;
pub const jitBranchSlowOp = jit_calls.jitBranchSlowOp;

const slab_size: usize = 2 * 1024 * 1024;
const PROT_READ: c_int = 1;
const PROT_WRITE: c_int = 2;
const PROT_EXEC: c_int = 4;
const MAP_PRIVATE: c_int = 0x0002;
const MAP_ANON: c_int = 0x1000;
const MAP_JIT: c_int = 0x0800;

const darwin = struct {
    extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) ?*anyopaque;
    extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
    extern "c" fn pthread_jit_write_protect_np(protect: c_int) void;
    extern "c" fn sys_icache_invalidate(start: *const anyopaque, len: usize) void;
};

pub const JitPool = struct {
    slabs: std.ArrayList([*]align(16384) u8) = .empty,
    used: usize = slab_size,
    threadlocal var cached_slab: ?[*]align(16384) u8 = null;

    pub fn allocCode(pool: *JitPool, gpa: Allocator, words: []const u32) ?JitFn {
        if (comptime !enabled) return null;
        const bytes_len = words.len * @sizeOf(u32);
        const aligned_len = (bytes_len + 15) & ~@as(usize, 15);
        if (aligned_len > slab_size) return null;
        if (pool.used + aligned_len > slab_size) {
            const p: [*]align(16384) u8 = if (cached_slab) |s| blk: {
                cached_slab = null;
                break :blk s;
            } else blk: {
                const raw = darwin.mmap(null, slab_size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0) orelse return null;
                if (@intFromPtr(raw) == std.math.maxInt(usize)) return null;
                break :blk @ptrCast(@alignCast(raw));
            };
            pool.slabs.append(gpa, p) catch {
                _ = darwin.munmap(p, slab_size);
                return null;
            };
            pool.used = 0;
        }
        const slab = pool.slabs.items[pool.slabs.items.len - 1];
        const dst: [*]align(16) u32 = @ptrCast(@alignCast(slab + pool.used));
        pool.used += aligned_len;
        darwin.pthread_jit_write_protect_np(0);
        @memcpy(dst[0..words.len], words);
        darwin.pthread_jit_write_protect_np(1);
        darwin.sys_icache_invalidate(dst, bytes_len);
        return @ptrCast(dst);
    }

    pub fn deinit(pool: *JitPool, gpa: Allocator) void {
        if (comptime enabled) {
            for (pool.slabs.items) |s| if (cached_slab == null) {
                cached_slab = s;
            } else {
                _ = darwin.munmap(s, slab_size);
            };
        }
        pool.slabs.deinit(gpa);
    }
};

pub inline fn encodeErr(e: Error) u64 {
    return switch (e) { error.Thrown => 1, error.Terminated => 2, error.OutOfMemory => 3 };
}

pub inline fn decodeErr(code: u64) Error {
    return switch (code) { 2 => error.Terminated, 3 => error.OutOfMemory, else => error.Thrown };
}

pub inline fn errRes(vm: *Vm, sp: [*]Value, e: Error) JitResult {
    vm.sp = sp;
    return .{ .bits = 0, .err = encodeErr(e) };
}

pub var global_jit_pool: JitPool = .{};

noinline fn compileSlow(vm: *Vm, fp: *bc.FuncProto) ?JitFn {
    if (arm64.compile(vm, fp)) |jfn| {
        fp.setJitFn(@ptrCast(jfn));
        if (fp.jit_cache_slot) |slot| {
            slot.catch_map = fp.catch_map;
            slot.jit_fn = @ptrCast(jfn);
        }
        return jfn;
    }
    @import("../perf_rules.zig").prof_jit_disabled += 1;
    fp.jit_disabled = true;
    return null;
}

/// Theorem 58 (`NanoUI.Speedometer3Climb.loop_aware_jit_threshold_and_stack_pool_equiv`):
/// Compiles non-top-level functions (`<= 32 KiB`) and loop-containing functions on call 1,
/// deferring only loop-free top-level script/module initializers to call 2.
pub inline fn getOrCompile(vm: *Vm, fp: *bc.FuncProto) ?JitFn {
    if (comptime !enabled) return null;
    if (fp.jit_fn) |p| return @ptrCast(@alignCast(p));
    if (fp.jit_disabled) return null;
    if (fp.jit_cache_slot) |slot| if (slot.jit_fn) |p| {
        fp.catch_map = slot.catch_map;
        fp.setJitFn(p);
        return @ptrCast(@alignCast(p));
    };
    fp.hot_count +|= 1;
    const threshold: u16 = if (fp.has_loop) 1 else 2;
    return if (fp.hot_count < threshold) null else compileSlow(vm, fp);
}

pub inline fn execFrame(vm: *Vm, f: *Frame, jfn: JitFn, sp_out: *[*]Value) Error!Value {
    try vm.checkNativeStack();
    vm.sp = sp_out.*;
    const res = jfn(vm, f, f.bp, sp_out.*);
    if (res.err != 0) {
        sp_out.* = vm.sp;
        return decodeErr(res.err);
    }
    var r = Value{ .bits = res.bits };
    if (f.is_construct and !r.isObject()) r = f.this;
    sp_out.* = f.ret_sp;
    vm.frame_top -= 1;
    return r;
}

pub fn jitGetField(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8) callconv(.c) JitResult {
    const pr = @import("../perf_rules.zig");
    pr.prof_ic_helpers += 1;
    const ic = &f.fp.ics[std.mem.readInt(u32, (pc + 1)[0..4], .little)];
    const v = (sp - 1)[0];
    if (!v.isObject()) pr.prof_ic_prim += 1 else {
        const o = v.asObject();
        if (o.flags.exotic) pr.prof_ic_exotic += 1
        else if (ic.is_accessor) pr.prof_ic_acc += 1
        else if (ic.slot == bc.IC.missing_slot) pr.prof_ic_miss_slot += 1;
    }
    f.pc = pc;
    vm.sp = sp;
    return .{ .bits = (icache.getField(vm, ic, v) catch |e| return errRes(vm, sp, e)).bits, .err = 0 };
}

pub fn jitPutField(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8) callconv(.c) JitResult {
    const ic = &f.fp.ics[std.mem.readInt(u32, (pc + 1)[0..4], .little)];
    f.pc = pc;
    vm.sp = sp;
    icache.putField(vm, ic, (sp - 2)[0], (sp - 1)[0], f.fp.strict) catch |e| return errRes(vm, sp, e);
    return .{ .bits = 0, .err = 0 };
}

pub fn jitDefineField(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8) callconv(.c) JitResult {
    const ic = &f.fp.ics[std.mem.readInt(u32, (pc + 1)[0..4], .little)];
    f.pc = pc;
    vm.sp = sp;
    icache.defineField(vm, ic, (sp - 2)[0].asObject(), (sp - 1)[0]) catch |e| return errRes(vm, sp, e);
    return .{ .bits = 0, .err = 0 };
}

pub fn jitGetGlobal(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8) callconv(.c) JitResult {
    const ic = &f.fp.ics[std.mem.readInt(u32, (pc + 1)[0..4], .little)];
    if (ic.shape == vm.global_lex.shape and ic.holder_shape == vm.global_obj.shape and ic.holder != null and ic.epoch == vm.proto_epoch) {
        const v = ic.holder.?.slots[ic.slot];
        if (!v.isHole()) return .{ .bits = v.bits, .err = 0 };
    }
    f.pc = pc;
    vm.sp = sp;
    return .{ .bits = (icache.getGlobal(vm, ic) catch |e| return errRes(vm, sp, e)).bits, .err = 0 };
}

pub fn jitPutGlobal(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8) callconv(.c) JitResult {
    const ic = &f.fp.ics[std.mem.readInt(u32, (pc + 1)[0..4], .little)];
    const v = (sp - 1)[0];
    if (ic.shape == vm.global_lex.shape and ic.holder_shape == vm.global_obj.shape and ic.holder != null and ic.epoch == vm.proto_epoch and !ic.holder.?.slots[ic.slot].isHole()) {
        ic.holder.?.slots[ic.slot] = v;
        return .{ .bits = 0, .err = 0 };
    }
    f.pc = pc;
    vm.sp = sp;
    icache.putGlobal(vm, ic, v, f.fp.strict) catch |e| return errRes(vm, sp, e);
    return .{ .bits = 0, .err = 0 };
}

pub fn jitGetLength(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8) callconv(.c) JitResult {
    const v = (sp - 1)[0];
    if (v.isObject()) {
        const o = v.asObject();
        if (o.class == .array) return .{ .bits = Value.fromUsize(o.arr_len).bits, .err = 0 };
        if (o.class == .typedarray) return .{ .bits = Value.fromUsize(typed.length(o)).bits, .err = 0 };
        if (o.class == .arguments and (o.shape == vm.args_strict_shape or o.shape == vm.args_sloppy_shape)) return .{ .bits = o.slots[0].bits, .err = 0 };
        if (o.class == .host_exotic and o.shape.count == 0 and o.payload.hooks.get_named == null) if (o.payload.hooks.length_index) |lf| {
            f.pc = pc;
            vm.sp = sp;
            return .{ .bits = Value.fromUsize(lf(vm, o) catch |e| return errRes(vm, sp, e)).bits, .err = 0 };
        };
    } else if (v.isString()) return .{ .bits = Value.fromUsize(v.asString().len16).bits, .err = 0 };
    f.pc = pc;
    vm.sp = sp;
    const ic = &f.fp.ics[std.mem.readInt(u32, (pc + 1)[0..4], .little)];
    return .{ .bits = (icache.getField(vm, ic, v) catch |e| return errRes(vm, sp, e)).bits, .err = 0 };
}

pub fn jitGetElem(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8) callconv(.c) JitResult {
    const t = (sp - 2)[0];
    const k = (sp - 1)[0];
    if (k.isInt() and k.asInt() >= 0) {
        const i: u32 = @bitCast(k.asInt());
        if (t.isObject()) {
            const o = t.asObject();
            if (i < o.elems_len and !o.flags.exotic) {
                const r = o.elems[i];
                if (!r.isHole()) return .{ .bits = r.bits, .err = 0 };
            } else if (o.class == .typedarray) {
                f.pc = pc;
                vm.sp = sp;
                return .{ .bits = (typed.getIndex(vm, o, i) catch |e| return errRes(vm, sp, e)).bits, .err = 0 };
            } else if (o.class == .host_exotic and o.shape.count == 0) if (o.payload.hooks.get_index) |gi| {
                f.pc = pc;
                vm.sp = sp;
                return .{ .bits = ((gi(vm, o, i) catch |e| return errRes(vm, sp, e)) orelse Value.undefined).bits, .err = 0 };
            };
        } else if (t.isString()) {
            const s = t.asString();
            if (i < s.len16 and s.is_ascii and !s.is_rope) return .{ .bits = Value.fromString(vm.char_strs[s.ptr[i]]).bits, .err = 0 };
        }
    } else if (k.isString() and t.isObject()) {
        const s = k.asString();
        const o = t.asObject();
        const pk = if (s.key.bits != 0) s.key else blk: {
            f.pc = pc;
            vm.sp = sp;
            if (str.findExistingKey(vm, s) catch |e| return errRes(vm, sp, e)) |ek| break :blk ek;
            if (s.byte_len <= 64) break :blk str.toKey(vm, s) catch |e| return errRes(vm, sp, e);
            if (icache.noExoticOnChain(o)) return .{ .bits = Value.undefined.bits, .err = 0 };
            return .{ .bits = (icache.getElem(vm, t, k) catch |e| return errRes(vm, sp, e)).bits, .err = 0 };
        };
        if (!pk.isIndex() and !o.flags.exotic and !o.flags.lazy_fn) {
            if (o.class == .array and pk.eql(vm.k.length)) return .{ .bits = Value.fromUsize(o.arr_len).bits, .err = 0 };
            const me = vm.megaSlot(o.shape, pk.bits);
            if (me.shape == o.shape and me.key_bits == pk.bits) {
                if (me.holder) |mh| {
                    if (me.epoch == vm.proto_epoch and mh.shape == me.holder_shape) {
                        const sv = mh.slots[me.slot & ~vm_mod.MegaICEntry.acc_flag];
                        if ((me.slot & vm_mod.MegaICEntry.acc_flag) == 0) return .{ .bits = sv.bits, .err = 0 };
                        f.pc = pc;
                        vm.sp = sp;
                        return .{ .bits = (@import("props.zig").callGetter(vm, sv, t) catch |e| return errRes(vm, sp, e)).bits, .err = 0 };
                    }
                } else if (me.slot == bc.IC.missing_slot) {
                    if (me.epoch == vm.proto_epoch) return .{ .bits = Value.undefined.bits, .err = 0 };
                } else {
                    return .{ .bits = o.slots[me.slot].bits, .err = 0 };
                }
            }
            if (o.shape.find(pk)) |slot| {
                if (!o.shape.flagsAt(slot).accessor) {
                    if (!o.shape.is_dict) me.* = .{ .shape = o.shape, .key_bits = pk.bits, .holder = null, .holder_shape = null, .slot = slot, .epoch = 0 };
                    return .{ .bits = o.slots[slot].bits, .err = 0 };
                }
            } else {
                const is_lazy_key = pk.eql(vm.k.name) or pk.eql(vm.k.length) or pk.eql(vm.k.prototype);
                const recv_lazy = is_lazy_key and (o.class == .closure or o.class == .native or o.shape == vm.fn_root);
                if (!o.shape.is_dict and !recv_lazy) {
                    var cur = o.shape.proto;
                    while (cur) |h| : (cur = h.shape.proto) {
                        if (h.flags.exotic or h.flags.lazy_fn) break;
                        if (h.class == .array and pk.eql(vm.k.length)) break;
                        if (is_lazy_key and (h.class == .closure or h.class == .native or h.shape == vm.fn_root)) break;
                        if (h.shape.find(pk)) |pslot| {
                            if (!h.shape.flagsAt(pslot).accessor) {
                                if (!h.shape.is_dict) me.* = .{ .shape = o.shape, .key_bits = pk.bits, .holder = h, .holder_shape = h.shape, .slot = pslot, .epoch = vm.proto_epoch };
                                return .{ .bits = h.slots[pslot].bits, .err = 0 };
                            }
                            if (!h.shape.is_dict) me.* = .{ .shape = o.shape, .key_bits = pk.bits, .holder = h, .holder_shape = h.shape, .slot = pslot | vm_mod.MegaICEntry.acc_flag, .epoch = vm.proto_epoch };
                            f.pc = pc;
                            vm.sp = sp;
                            return .{ .bits = (@import("props.zig").callGetter(vm, h.slots[pslot], t) catch |e| return errRes(vm, sp, e)).bits, .err = 0 };
                        }
                    } else {
                        me.* = .{ .shape = o.shape, .key_bits = pk.bits, .holder = null, .holder_shape = null, .slot = bc.IC.missing_slot, .epoch = vm.proto_epoch };
                        return .{ .bits = Value.undefined.bits, .err = 0 };
                    }
                }
            }
        }
    } else if (k.isSymbol() and t.isObject()) {
        const o = t.asObject();
        if (!o.flags.exotic) {
            const pk = PropKey.fromSymbol(k.asSymbol());
            if (o.shape.find(pk)) |slot| {
                if (!o.shape.flagsAt(slot).accessor) return .{ .bits = o.slots[slot].bits, .err = 0 };
            } else if (o.shape.proto == null or (o.shape.proto == vm.protos.object and !vm.protos.object.flags.proto_dirty and vm.protos.object.shape.find(pk) == null)) {
                return .{ .bits = Value.undefined.bits, .err = 0 };
            }
        }
    }
    f.pc = pc;
    vm.sp = sp;
    return .{ .bits = (icache.getElem(vm, t, k) catch |e| return errRes(vm, sp, e)).bits, .err = 0 };
}

pub fn jitPutElem(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8) callconv(.c) JitResult {
    const t = (sp - 3)[0];
    const k = (sp - 2)[0];
    const v = (sp - 1)[0];
    if (k.isInt() and k.asInt() >= 0 and t.isObject()) {
        const o = t.asObject();
        const i: u32 = @bitCast(k.asInt());
        if (!o.flags.exotic and !o.flags.elems_frozen) {
            if (i < o.elems_len and !o.elems[i].isHole()) {
                o.elems[i] = v;
                return .{ .bits = 0, .err = 0 };
            }
            if (o.class == .array and i == o.elems_len and i < o.elems_cap and o.shape.proto == vm.protos.array and !vm.protos.array.flags.proto_dirty and !vm.protos.object.flags.proto_dirty and o.flags.extensible and !o.flags.elems_sealed and !o.flags.length_readonly and !o.flags.is_proto) {
                o.elems[i] = v;
                o.elems_len = i + 1;
                if (i >= o.arr_len) o.arr_len = i + 1;
                return .{ .bits = 0, .err = 0 };
            }
        } else if (o.class == .typedarray) {
            f.pc = pc;
            vm.sp = sp;
            typed.setIndex(vm, o, i, v) catch |e| return errRes(vm, sp, e);
            return .{ .bits = 0, .err = 0 };
        }
    } else if (k.isString() and t.isObject()) {
        const s = k.asString();
        const o = t.asObject();
        const pk = if (s.key.bits != 0) s.key else blk: {
            f.pc = pc;
            vm.sp = sp;
            break :blk str.toKey(vm, s) catch |e| return errRes(vm, sp, e);
        };
        if (!pk.isIndex() and !o.flags.exotic and !o.flags.lazy_fn) {
            if (o.shape.find(pk)) |slot| {
                const fl = o.shape.flagsAt(slot);
                if (fl.writable and !fl.accessor) {
                    o.slots[slot] = v;
                    return .{ .bits = 0, .err = 0 };
                }
            } else if (o.flags.extensible and !o.flags.is_proto and o.class == .object and
                (o.shape.proto == null or (o.shape.proto == vm.protos.object and !vm.protos.object.flags.proto_dirty and vm.protos.object.shape.find(pk) == null)))
            {
                if (o.shape.single) |next| {
                    if (next.key.bits == pk.bits and @as(u8, @bitCast(next.flags)) == @as(u8, @bitCast(@import("shape.zig").PropFlags.all)) and next.count - 1 < o.slot_cap) {
                        o.shape = next;
                        o.slots[next.count - 1] = v;
                        return .{ .bits = 0, .err = 0 };
                    }
                }
                f.pc = pc;
                vm.sp = sp;
                @import("props.zig").addProp(vm, o, pk, v, .all) catch |e| return errRes(vm, sp, e);
                return .{ .bits = 0, .err = 0 };
            }
        }
    }
    f.pc = pc;
    vm.sp = sp;
    icache.putElem(vm, t, k, v, f.fp.strict) catch |e| return errRes(vm, sp, e);
    return .{ .bits = 0, .err = 0 };
}

pub fn jitNewObject(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8) callconv(.c) JitResult {
    f.pc = pc;
    vm.sp = sp;
    const o = objmod.newPlain(vm) catch |e| return errRes(vm, sp, e);
    return .{ .bits = o.value().bits, .err = 0 };
}

pub fn jitBinaryOp(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, op_raw: u32) callconv(.c) JitResult {
    const a = (sp - 2)[0];
    const b = (sp - 1)[0];
    const op: Op = @enumFromInt(@as(u8, @intCast(op_raw)));
    if (a.isNumber() and b.isNumber()) {
        switch (op) {
            .add => return .{ .bits = Value.fromDouble(a.asNumber() + b.asNumber()).bits, .err = 0 },
            .sub => return .{ .bits = Value.fromDouble(a.asNumber() - b.asNumber()).bits, .err = 0 },
            .mul => return .{ .bits = Value.fromNumber(a.asNumber() * b.asNumber()).bits, .err = 0 },
            .div => return .{ .bits = Value.fromNumber(a.asNumber() / b.asNumber()).bits, .err = 0 },
            else => {},
        }
    }
    f.pc = pc;
    vm.sp = sp;
    const r = (switch (op) {
        .add => ops.add(vm, a, b),
        .sub => ops.arith(vm, .sub, a, b),
        .mul => ops.arith(vm, .mul, a, b),
        .div => ops.arith(vm, .div, a, b),
        .mod => ops.arith(vm, .mod, a, b),
        else => ops.bitop(vm, op, a, b),
    }) catch |e| return errRes(vm, sp, e);
    return .{ .bits = r.bits, .err = 0 };
}

pub fn jitCompareOp(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, op_raw: u32) callconv(.c) JitResult {
    const a = (sp - 2)[0];
    const b = (sp - 1)[0];
    const op: Op = @enumFromInt(@as(u8, @intCast(op_raw)));
    if (a.isNumber() and b.isNumber()) {
        const x = a.asNumber();
        const y = b.asNumber();
        const r = switch (op) {
            .lt => x < y,
            .le => x <= y,
            .gt => x > y,
            .ge => x >= y,
            .seq, .eq => x == y,
            else => x != y,
        };
        return .{ .bits = Value.fromBool(r).bits, .err = 0 };
    }
    if (op == .seq or op == .sne) {
        if (a.bits == b.bits) return .{ .bits = Value.fromBool(op == .seq).bits, .err = 0 };
        if (a.isString() and b.isString()) {
            const s1 = a.asString();
            const s2 = b.asString();
            if (s1.byte_len != s2.byte_len or s1.len16 != s2.len16 or (s1.is_atom and s2.is_atom)) {
                return .{ .bits = Value.fromBool(op == .sne).bits, .err = 0 };
            }
            if (!s1.is_rope and !s2.is_rope) {
                const eq = std.mem.eql(u8, s1.ptr[0..s1.byte_len], s2.ptr[0..s2.byte_len]);
                return .{ .bits = Value.fromBool(eq == (op == .seq)).bits, .err = 0 };
            }
        } else if (!a.isBigInt() or !b.isBigInt()) {
            return .{ .bits = Value.fromBool(op == .sne).bits, .err = 0 };
        }
    }
    if (op == .eq or op == .ne) {
        if (a.bits == b.bits and !a.isDouble()) return .{ .bits = Value.fromBool(op == .eq).bits, .err = 0 };
        if (a.isNullish() or b.isNullish()) return .{ .bits = Value.fromBool((ops.nullishOrDda(a) and ops.nullishOrDda(b)) == (op == .eq)).bits, .err = 0 };
        if (a.isString() and b.isString()) {
            const s1 = a.asString();
            const s2 = b.asString();
            if (s1.byte_len != s2.byte_len or s1.len16 != s2.len16) return .{ .bits = Value.fromBool(op == .ne).bits, .err = 0 };
            if (s1.key.bits != 0 and s2.key.bits != 0) return .{ .bits = Value.fromBool((s1.key.bits == s2.key.bits) == (op == .eq)).bits, .err = 0 };
            if (!s1.is_rope and !s2.is_rope) {
                const eq = std.mem.eql(u8, s1.ptr[0..s1.byte_len], s2.ptr[0..s2.byte_len]);
                return .{ .bits = Value.fromBool(eq == (op == .eq)).bits, .err = 0 };
            }
        }
    }
    f.pc = pc;
    vm.sp = sp;
    const r = (switch (op) {
        .seq => ops.strictEquals(vm, a, b),
        .sne => if (ops.strictEquals(vm, a, b)) |eq| !eq else |e| e,
        .eq => ops.looseEquals(vm, a, b),
        .ne => if (ops.looseEquals(vm, a, b)) |eq| !eq else |e| e,
        else => ops.compare(vm, op, a, b),
    }) catch |e| return errRes(vm, sp, e);
    return .{ .bits = Value.fromBool(r).bits, .err = 0 };
}

pub fn jitUnaryOp(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, op_raw: u32) callconv(.c) JitResult {
    const a = (sp - 1)[0];
    const op: Op = @enumFromInt(@as(u8, @intCast(op_raw)));
    f.pc = pc;
    vm.sp = sp;
    const r = (if (op == .plus)
        if (@import("conv.zig").toNumber(vm, a)) |n| Value.fromNumber(n) else |e| e
    else
        ops.incDec(vm, a, op == .inc)) catch |e| return errRes(vm, sp, e);
    return .{ .bits = r.bits, .err = 0 };
}

pub fn jitTruthy(bits: u64) callconv(.c) u64 { return @intFromBool(ops.truthy(.{ .bits = bits })); }
pub fn jitTypeOf(vm: *Vm, bits: u64) callconv(.c) u64 { return ops.typeOf(vm, .{ .bits = bits }).bits; }
pub fn jitThrowTdz(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, name_idx: u32) callconv(.c) JitResult {
    f.pc = pc;
    return errRes(vm, sp, slow.throwTdz(vm, f, name_idx));
}
pub fn jitInterrupt(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8) callconv(.c) JitResult {
    f.pc = pc;
    vm.sp = sp;
    calls.interrupt(vm) catch |e| return errRes(vm, sp, e);
    return .{ .bits = 0, .err = 0 };
}
