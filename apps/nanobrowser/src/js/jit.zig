//! Baseline JIT runtime: executable `MAP_JIT` slab allocator on `aarch64-macos`,
//! hot-function compilation dispatch, and C-ABI runtime helpers invoked by emitted
//! native machine code. Other targets compile cleanly with a zero-overhead stub.

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
const props = @import("props.zig");
const ops = @import("ops.zig");
const icache = @import("interp_ic.zig");
const calls = @import("interp_call.zig");
const slow = @import("interp_slow.zig");
const interp = @import("interp.zig");
const iter = @import("iter.zig");
const str = @import("string.zig");
const api = @import("vm_api.zig");
const b_fn = @import("b_function.zig");
const typed = @import("b_typed.zig");
const arm64 = @import("jit_arm64.zig");

pub const enabled = builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos;

pub const JitResult = extern struct { bits: u64, err: u64 };
pub const JitFn = *const fn (vm: *Vm, f: *Frame, bp: [*]Value, sp: [*]Value) callconv(.c) JitResult;

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
    return switch (e) {
        error.Thrown => 1,
        error.Terminated => 2,
        error.OutOfMemory => 3,
    };
}

pub inline fn decodeErr(code: u64) Error {
    return switch (code) {
        2 => error.Terminated,
        3 => error.OutOfMemory,
        else => error.Thrown,
    };
}

inline fn errRes(vm: *Vm, sp: [*]Value, e: Error) JitResult {
    vm.sp = sp;
    return .{ .bits = 0, .err = encodeErr(e) };
}

noinline fn compileSlow(vm: *Vm, fp: *bc.FuncProto) ?JitFn {
    if (arm64.compile(vm, fp)) |jfn| {
        fp.jit_fn = @ptrCast(jfn);
        return jfn;
    }
    fp.jit_disabled = true;
    return null;
}

/// Theorem 58 (`NanoUI.Speedometer3Climb.loop_aware_jit_threshold_and_stack_pool_equiv`):
/// Compiles loop-containing functions on their first call (`threshold = 1`) and
/// loop-free functions on call 2, skipping one-shot module factory closures.
pub inline fn getOrCompile(vm: *Vm, fp: *bc.FuncProto) ?JitFn {
    if (comptime !enabled) return null;
    if (fp.jit_fn) |p| return @ptrCast(@alignCast(p));
    if (fp.jit_disabled) return null;
    fp.hot_count +|= 1;
    const threshold: u16 = if (fp.has_loop and fp.code.len <= 4096) 1 else 2;
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
    const ic = &f.fp.ics[std.mem.readInt(u32, (pc + 1)[0..4], .little)];
    f.pc = pc;
    vm.sp = sp;
    const r = icache.getField(vm, ic, (sp - 1)[0]) catch |e| return errRes(vm, sp, e);
    return .{ .bits = r.bits, .err = 0 };
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
    const r = icache.getGlobal(vm, ic) catch |e| return errRes(vm, sp, e);
    return .{ .bits = r.bits, .err = 0 };
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
    } else if (v.isString()) return .{ .bits = Value.fromUsize(v.asString().len16).bits, .err = 0 };
    f.pc = pc;
    vm.sp = sp;
    const ic = &f.fp.ics[std.mem.readInt(u32, (pc + 1)[0..4], .little)];
    const r = icache.getField(vm, ic, v) catch |e| return errRes(vm, sp, e);
    return .{ .bits = r.bits, .err = 0 };
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
                const r = typed.getIndex(vm, o, i) catch |e| return errRes(vm, sp, e);
                return .{ .bits = r.bits, .err = 0 };
            }
        } else if (t.isString()) {
            const s = t.asString();
            if (i < s.len16 and s.is_ascii and !s.is_rope) {
                return .{ .bits = Value.fromString(vm.char_strs[s.ptr[i]]).bits, .err = 0 };
            }
        }
    }
    f.pc = pc;
    vm.sp = sp;
    const r = icache.getElem(vm, t, k) catch |e| return errRes(vm, sp, e);
    return .{ .bits = r.bits, .err = 0 };
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
    const r = ops.incDec(vm, a, op == .inc) catch |e| return errRes(vm, sp, e);
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

noinline fn handleChildErr(vm: *Vm, caller_sp: [*]Value, child_f: *Frame, err_code: u64) JitResult {
    @branchHint(.cold);
    var err = decodeErr(err_code);
    if (err == error.OutOfMemory) {
        api.throwOutOfMemory(vm);
        err = error.Thrown;
    }
    if (err == error.Thrown) {
        const base = child_f.bp + child_f.fp.nlocals;
        var s = vm.sp;
        while (@intFromPtr(s) > @intFromPtr(base)) {
            s -= 1;
            const v = s[0];
            if (!v.isInternal()) continue;
            if (fr.isCatchMarker(v)) {
                const saved = (s - 1)[0];
                child_f.env = if (saved.isUndefined()) null else @fieldParentPtr("cell", saved.asCell());
                child_f.pc = child_f.fp.code.ptr + fr.catchOffset(v);
                (s - 1)[0] = vm.exception;
                vm.exception = Value.undefined;
                vm.sp = s;
                child_f.is_entry = true;
                const r = interp.run(vm) catch |e| return errRes(vm, caller_sp, e);
                const ret_sp = vm.sp;
                ret_sp[0] = r;
                return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
            }
            if (v.same(fr.iter_marker) or v.same(fr.async_iter_marker)) {
                vm.sp = s + 1;
                iter.closeQuiet(vm, (s - 2)[0]) catch |e| {
                    if (e == error.Terminated) err = e;
                };
                if (err != error.Thrown) break;
            }
        }
    }
    vm.frame_top -= 1;
    return errRes(vm, caller_sp, err);
}

inline fn invokeChildFrame(vm: *Vm, caller_sp: [*]Value, child_f: *Frame) JitResult {
    vm.checkNativeStack() catch |e| {
        vm.frame_top -= 1;
        return errRes(vm, caller_sp, e);
    };
    if (getOrCompile(vm, child_f.fp)) |jfn| {
        const res = jfn(vm, child_f, child_f.bp, vm.sp);
        if (res.err != 0) return handleChildErr(vm, caller_sp, child_f, res.err);
        var r = Value{ .bits = res.bits };
        if (child_f.is_construct and !r.isObject()) r = child_f.this;
        const ret_sp = child_f.ret_sp;
        vm.frame_top -= 1;
        ret_sp[0] = r;
        return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
    }
    child_f.is_entry = true;
    const r = interp.run(vm) catch |e| return errRes(vm, caller_sp, e);
    const ret_sp = vm.sp;
    ret_sp[0] = r;
    return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
}

inline fn pushAndInvokeClosure(vm: *Vm, caller_sp: [*]Value, callee: *Object, args: [*]Value, argc: u32, ret_sp: [*]Value, this: Value) JitResult {
    const child_f = calls.pushClosure(vm, callee, args, argc, ret_sp, Value.undefined, this, false) catch |e| return errRes(vm, caller_sp, e);
    return invokeChildFrame(vm, caller_sp, child_f);
}

/// Theorem 37 (`NanoUI.Speedometer3Perf.single_tier_up_check_per_call`):
/// Executes an entry frame directly via JIT when compiled, falling back to `interp.run`.
pub fn runEntry(vm: *Vm) Error!Value {
    const f = &vm.frames[vm.frame_top - 1];
    if (comptime enabled) {
        const res = invokeChildFrame(vm, f.ret_sp, f);
        if (res.err != 0) return decodeErr(res.err);
        vm.sp = f.ret_sp;
        return f.ret_sp[0];
    }
    return interp.run(vm);
}

noinline fn jitCallNonClosure(vm: *Vm, sp: [*]Value, argc: u32, ret_sp: [*]Value, callee: Value) JitResult {
    if (callee.isObject()) {
        const co = callee.asObject();
        if (co.class == .bound) {
            const b = co.payload.bound;
            if (b.target.class == .closure) {
                if (b.args.len == 0) {
                    return pushAndInvokeClosure(vm, sp, b.target, sp - argc, argc, ret_sp, b.this);
                }
                if (b.args.len + argc <= 64) {
                    const base = sp - argc;
                    const blen: u32 = @intCast(b.args.len);
                    std.mem.copyBackwards(Value, (base + blen)[0..argc], base[0..argc]);
                    @memcpy(base[0..blen], b.args);
                    return pushAndInvokeClosure(vm, sp, b.target, base, blen + argc, ret_sp, b.this);
                }
            }
        } else if (co.class == .native) {
            const nf = co.payload.native.func;
            if (nf == &b_fn.fnCall) {
                const target = ret_sp[0];
                if (target.isObject()) {
                    const to = target.asObject();
                    const sub_this = if (argc > 0) (sp - argc)[0] else Value.undefined;
                    const sub_args = if (argc > 0) sp - argc + 1 else sp;
                    const sub_argc = if (argc > 0) argc - 1 else 0;
                    if (to.class == .closure) {
                        return pushAndInvokeClosure(vm, sp, to, sub_args, sub_argc, ret_sp, sub_this);
                    }
                    if (to.class == .bound and to.payload.bound.args.len == 0 and to.payload.bound.target.class == .closure) {
                        return pushAndInvokeClosure(vm, sp, to.payload.bound.target, sub_args, sub_argc, ret_sp, to.payload.bound.this);
                    }
                }
            } else if (nf == &b_fn.fnApply) {
                const target = ret_sp[0];
                if (target.isObject()) {
                    const to = target.asObject();
                    var closure_target: ?*objmod.Object = null;
                    var sub_this = if (argc > 0) (sp - argc)[0] else Value.undefined;
                    if (to.class == .closure) {
                        closure_target = to;
                    } else if (to.class == .bound and to.payload.bound.args.len == 0 and to.payload.bound.target.class == .closure) {
                        closure_target = to.payload.bound.target;
                        sub_this = to.payload.bound.this;
                    }
                    if (closure_target) |ct| {
                        const arr_val = if (argc > 1) (sp - argc + 1)[0] else Value.undefined;
                        if (arr_val.isNullish()) {
                            return pushAndInvokeClosure(vm, sp, ct, sp, 0, ret_sp, sub_this);
                        }
                        if (arr_val.isObject()) {
                            const ao = arr_val.asObject();
                            const n = ao.elems_len;
                            const is_fast_args = ao.class == .arguments and (ao.shape == vm.args_strict_shape or ao.shape == vm.args_sloppy_shape) and ao.slots[0].bits == Value.fromUsize(n).bits;
                            if (!ao.flags.exotic and !ao.flags.has_sparse and ((ao.class == .array and n == ao.arr_len) or is_fast_args) and n <= 64) {
                                var has_hole = false;
                                for (ao.elems[0..n]) |el| if (el.isHole()) {
                                    has_hole = true;
                                    break;
                                };
                                if (!has_hole) {
                                    const sub_args = sp - argc;
                                    @memcpy(sub_args[0..n], ao.elems[0..n]);
                                    return pushAndInvokeClosure(vm, sp, ct, sub_args, n, ret_sp, sub_this);
                                }
                            }
                        }
                    }
                }
            }
            if (!co.flags.host_class) {
                const r = calls.callNative(vm, co, ret_sp[0], (sp - argc)[0..argc]) catch |e| return errRes(vm, sp, e);
                ret_sp[0] = r;
                return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
            }
        }
    }
    const r = calls.callNonClosure(vm, callee, ret_sp[0], (sp - argc)[0..argc]) catch |e| return errRes(vm, sp, e);
    ret_sp[0] = r;
    return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
}

pub fn jitCall(vm: *Vm, f: *Frame, sp: [*]Value, next_pc: [*]const u8, argc: u32) callconv(.c) JitResult {
    f.pc = next_pc;
    vm.sp = sp;
    const callee = (sp - argc - 1)[0];
    const ret_sp = sp - argc - 2;
    if (callee.isObject() and callee.asObject().class == .closure) {
        return pushAndInvokeClosure(vm, sp, callee.asObject(), sp - argc, argc, ret_sp, ret_sp[0]);
    }
    return jitCallNonClosure(vm, sp, argc, ret_sp, callee);
}

pub fn jitNew(vm: *Vm, f: *Frame, sp: [*]Value, next_pc: [*]const u8, argc: u32) callconv(.c) JitResult {
    f.pc = next_pc;
    vm.sp = sp;
    const callee = (sp - argc - 1)[0];
    const ret_sp = sp - argc - 2;
    if (callee.isObject() and callee.asObject().class == .closure and callee.asObject().flags.constructor) {
        const co = callee.asObject();
        const this = if (co.flags.derived_ctor) Value.hole else (calls.allocThis(vm, co, callee) catch |e| return errRes(vm, sp, e)).value();
        const child_f = calls.pushClosure(vm, co, sp - argc, argc, ret_sp, callee, this, true) catch |e| return errRes(vm, sp, e);
        return invokeChildFrame(vm, sp, child_f);
    }
    const r = calls.construct(vm, callee, (sp - argc)[0..argc], callee) catch |e| return errRes(vm, sp, e);
    ret_sp[0] = r;
    return .{ .bits = @intFromPtr(ret_sp + 1), .err = 0 };
}

pub fn jitApply(vm: *Vm, f: *Frame, sp_in: [*]Value, next_pc: [*]const u8, is_new: u32) callconv(.c) JitResult {
    var sp = sp_in;
    f.pc = next_pc - 1;
    vm.sp = sp;
    const argc = calls.expandArgs(vm, &sp) catch |e| return errRes(vm, sp_in, e);
    const res = if (is_new != 0) jitNew(vm, f, sp, next_pc, argc) else jitCall(vm, f, sp, next_pc, argc);
    if (res.err != 0) vm.sp = sp_in;
    return res;
}

pub fn jitSlowOp(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, op_raw: u32) callconv(.c) JitResult {
    f.pc = pc;
    vm.sp = sp;
    slow.exec(vm, f, @enumFromInt(@as(u8, @intCast(op_raw)))) catch |e| return errRes(vm, sp, e);
    return .{ .bits = @intFromPtr(vm.sp), .err = 0 };
}

/// Executes a branching slow opcode (`opt_chain`, `ctor_ret_check`, `iter_next`, `for_in_next`).
/// Returns `(new_sp | (jumped << 63), err)` so the JIT knows both the updated `sp` and whether the branch was taken.
pub fn jitBranchSlowOp(vm: *Vm, f: *Frame, sp: [*]Value, pc: [*]const u8, op_raw: u32, fallthrough_pc: [*]const u8) callconv(.c) JitResult {
    f.pc = pc;
    vm.sp = sp;
    slow.exec(vm, f, @enumFromInt(@as(u8, @intCast(op_raw)))) catch |e| return errRes(vm, sp, e);
    const jumped: u64 = @intFromBool(f.pc != fallthrough_pc);
    return .{ .bits = @intFromPtr(vm.sp) | (jumped << 63), .err = 0 };
}
