//! The bytecode interpreter's dispatch loop. Only the hot opcodes are here, so its
//! native frame stays small; everything else goes through interp_slow.zig.
//! Bytecode-to-bytecode calls push a Frame and keep looping: they use no native stack.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const value = @import("value.zig");
const Value = value.Value;
const bc = @import("bytecode.zig");
const Op = bc.Op;
const fr = @import("frame.zig");
const Frame = fr.Frame;
const objmod = @import("object.zig");
const Object = objmod.Object;
const heap = @import("heap.zig");
const ops = @import("ops.zig");
const slow = @import("interp_slow.zig");
const icache = @import("interp_ic.zig");
const calls = @import("interp_call.zig");
const unwind = @import("interp_unwind.zig");
const jit = @import("jit.zig");

inline fn u16At(p: [*]const u8) u32 {
    return std.mem.readInt(u16, p[0..2], .little);
}
inline fn u32At(p: [*]const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .little);
}
inline fn relAt(p: [*]const u8) isize {
    return std.mem.readInt(i32, p[0..4], .little);
}
inline fn jumpTo(pc: [*]const u8, rel: isize) [*]const u8 {
    return if (rel >= 0) pc + @as(usize, @intCast(rel)) else pc - @as(usize, @intCast(-rel));
}

/// Unwraps an operation's result; on error, records it so `orelse break :dispatch` unwinds.
inline fn ok(comptime T: type, r: Error!T, err: *Error) ?T {
    return r catch |e| {
        err.* = e;
        return null;
    };
}

inline fn sync(vm: *Vm, f: *Frame, pc: [*]const u8, sp: [*]Value) void {
    f.pc = pc;
    vm.sp = sp;
}

const literals = [_]Value{ Value.undefined, Value.null, Value.true, Value.false, Value.hole };

/// Runs the top frame until it (an entry frame) returns.
pub fn run(vm: *Vm) Error!Value {
    var f: *Frame = &vm.frames[vm.frame_top - 1];
    var pc: [*]const u8 = f.pc;
    var bp: [*]Value = f.bp;
    var sp: [*]Value = vm.sp;
    var argc: u32 = 0;
    var err: Error = error.Thrown;
    loop: while (true) {
        dispatch: {
            if (!f.is_entry and pc == f.fp.code.ptr and f.co == null) {
                if (jit.getOrCompile(vm, f.fp)) |jfn| {
                    const entry = f.is_entry;
                    const r = ok(Value, jit.execFrame(vm, f, jfn, &sp), &err) orelse break :dispatch;
                    if (entry) {
                        vm.sp = sp;
                        return r;
                    }
                    sp[0] = r;
                    sp += 1;
                    f = &vm.frames[vm.frame_top - 1];
                    pc = f.pc;
                    bp = f.bp;
                }
            }
            sw: switch (@as(Op, @fromBackingInt(@intCast(pc[0])))) {
                .undef, .null_, .true_, .false_, .hole => |o| {
                    @import("../perf_rules.zig").prof_interp_ops += 1;
                    sp[0] = literals[@backingInt(o) - @backingInt(Op.undef)];
                    sp += 1;
                    pc += 1;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .int8 => {
                    sp[0] = Value.fromInt(@as(i8, @bitCast(pc[1])));
                    sp += 1;
                    pc += 2;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .constant => {
                    sp[0] = f.fp.constants[u32At(pc + 1)];
                    sp += 1;
                    pc += 5;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .this => {
                    sp[0] = f.this;
                    sp += 1;
                    pc += 1;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .pop => {
                    sp -= 1;
                    pc += 1;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .dup => {
                    sp[0] = (sp - 1)[0];
                    sp += 1;
                    pc += 1;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .get_loc => {
                    sp[0] = bp[u16At(pc + 1)];
                    sp += 1;
                    pc += 3;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .put_loc => {
                    sp -= 1;
                    bp[u16At(pc + 1)] = sp[0];
                    pc += 3;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .set_loc => {
                    bp[u16At(pc + 1)] = (sp - 1)[0];
                    pc += 3;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .get_loc_check => {
                    const v = bp[u16At(pc + 1)];
                    if (v.isHole()) {
                        f.pc = pc;
                        err = slow.throwTdz(vm, f, u32At(pc + 3));
                        break :dispatch;
                    }
                    sp[0] = v;
                    sp += 1;
                    pc += 7;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .get_env => {
                    var e = f.env.?;
                    var d = pc[1];
                    while (d != 0) : (d -= 1) e = e.parent.?;
                    sp[0] = e.slots()[u16At(pc + 2)];
                    sp += 1;
                    pc += 4;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .put_env => {
                    var e = f.env.?;
                    var d = pc[1];
                    while (d != 0) : (d -= 1) e = e.parent.?;
                    sp -= 1;
                    e.slots()[u16At(pc + 2)] = sp[0];
                    pc += 4;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .get_env_check => {
                    var e = f.env.?;
                    var d = pc[1];
                    while (d != 0) : (d -= 1) e = e.parent.?;
                    const v = e.slots()[u16At(pc + 2)];
                    if (v.isHole()) {
                        f.pc = pc;
                        err = slow.throwTdz(vm, f, u32At(pc + 4));
                        break :dispatch;
                    }
                    sp[0] = v;
                    sp += 1;
                    pc += 8;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .get_global => {
                    const ic = &f.fp.ics[u32At(pc + 1)];
                    var v = Value.hole;
                    if (ic.shape == vm.global_lex.shape and ic.holder_shape == vm.global_obj.shape and ic.holder != null and ic.epoch == vm.proto_epoch) {
                        v = ic.holder.?.slots[ic.slot];
                    }
                    if (v.isHole()) {
                        sync(vm, f, pc, sp);
                        v = ok(Value, icache.getGlobal(vm, ic), &err) orelse break :dispatch;
                    }
                    sp[0] = v;
                    sp += 1;
                    pc += 5;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .put_global => {
                    const ic = &f.fp.ics[u32At(pc + 1)];
                    if (ic.shape == vm.global_lex.shape and ic.holder_shape == vm.global_obj.shape and ic.holder != null and ic.epoch == vm.proto_epoch and !ic.holder.?.slots[ic.slot].isHole()) {
                        ic.holder.?.slots[ic.slot] = (sp - 1)[0];
                    } else {
                        sync(vm, f, pc, sp);
                        ok(void, icache.putGlobal(vm, ic, (sp - 1)[0], f.fp.strict), &err) orelse break :dispatch;
                    }
                    pc += 5;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                inline .get_field, .get_field2 => |o| {
                    const ic = &f.fp.ics[u32At(pc + 1)];
                    const v = (sp - 1)[0];
                    var r: Value = undefined;
                    if (v.isObject() and v.asObject().shape == ic.shape and ic.fast_own_data) {
                        r = v.asObject().slots[ic.slot];
                    } else if (v.isObject() and v.asObject().shape == ic.shape and ic.fast_proto_data and ic.epoch == vm.proto_epoch and ic.holder.?.shape == ic.holder_shape) {
                        r = ic.holder.?.slots[ic.slot];
                    } else {
                        sync(vm, f, pc, sp);
                        r = ok(Value, icache.getField(vm, ic, v), &err) orelse break :dispatch;
                    }
                    if (o == .get_field) (sp - 1)[0] = r else {
                        sp[0] = r;
                        sp += 1;
                    }
                    pc += 5;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .put_field => {
                    const ic = &f.fp.ics[u32At(pc + 1)];
                    const t = (sp - 2)[0];
                    const v = (sp - 1)[0];
                    if (t.isObject() and t.asObject().shape == ic.shape and ic.fast_own_data) {
                        t.asObject().slots[ic.slot] = v;
                    } else {
                        sync(vm, f, pc, sp);
                        ok(void, icache.putField(vm, ic, t, v, f.fp.strict), &err) orelse break :dispatch;
                    }
                    (sp - 2)[0] = v;
                    sp -= 1;
                    pc += 5;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .get_length => {
                    const v = (sp - 1)[0];
                    if (v.isObject() and v.asObject().class == .array) {
                        (sp - 1)[0] = Value.fromUsize(v.asObject().arr_len);
                    } else if (v.isString()) {
                        (sp - 1)[0] = Value.fromUsize(v.asString().len16);
                    } else {
                        sync(vm, f, pc, sp);
                        (sp - 1)[0] = ok(Value, icache.getField(vm, &f.fp.ics[u32At(pc + 1)], v), &err) orelse break :dispatch;
                    }
                    pc += 5;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .get_elem => {
                    const t = (sp - 2)[0];
                    const k = (sp - 1)[0];
                    var r = Value.hole;
                    if (k.isInt() and t.isObject()) {
                        const o = t.asObject();
                        const i: u32 = @bitCast(k.asInt());
                        if (i < o.elems_len and !o.flags.exotic) r = o.elems[i];
                    }
                    if (r.isHole()) {
                        sync(vm, f, pc, sp);
                        r = ok(Value, icache.getElem(vm, t, k), &err) orelse break :dispatch;
                    }
                    (sp - 2)[0] = r;
                    sp -= 1;
                    pc += 1;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .put_elem => {
                    const t = (sp - 3)[0];
                    const k = (sp - 2)[0];
                    const v = (sp - 1)[0];
                    put: {
                        if (k.isInt() and t.isObject()) {
                            const o = t.asObject();
                            const i: u32 = @bitCast(k.asInt());
                            if (i < o.elems_len and !o.flags.exotic and !o.flags.elems_frozen and !o.elems[i].isHole()) {
                                o.elems[i] = v;
                                break :put;
                            }
                        }
                        sync(vm, f, pc, sp);
                        ok(void, icache.putElem(vm, t, k, v, f.fp.strict), &err) orelse break :dispatch;
                    }
                    (sp - 3)[0] = v;
                    sp -= 2;
                    pc += 1;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .add => {
                    const a = (sp - 2)[0];
                    const b = (sp - 1)[0];
                    var r: Value = undefined;
                    if (a.isInt() and b.isInt()) {
                        const x = @addWithOverflow(a.asInt(), b.asInt());
                        r = if (x[1] == 0) Value.fromInt(x[0]) else Value.fromDouble(a.asNumber() + b.asNumber());
                    } else if (a.isNumber() and b.isNumber()) {
                        r = Value.fromDouble(a.asNumber() + b.asNumber());
                    } else {
                        sync(vm, f, pc, sp);
                        r = ok(Value, ops.add(vm, a, b), &err) orelse break :dispatch;
                    }
                    (sp - 2)[0] = r;
                    sp -= 1;
                    pc += 1;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .sub => {
                    const a = (sp - 2)[0];
                    const b = (sp - 1)[0];
                    var r: Value = undefined;
                    if (a.isInt() and b.isInt()) {
                        const x = @subWithOverflow(a.asInt(), b.asInt());
                        r = if (x[1] == 0) Value.fromInt(x[0]) else Value.fromDouble(a.asNumber() - b.asNumber());
                    } else if (a.isNumber() and b.isNumber()) {
                        r = Value.fromDouble(a.asNumber() - b.asNumber());
                    } else {
                        sync(vm, f, pc, sp);
                        r = ok(Value, ops.arith(vm, .sub, a, b), &err) orelse break :dispatch;
                    }
                    (sp - 2)[0] = r;
                    sp -= 1;
                    pc += 1;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                inline .mul, .div => |o| {
                    const a = (sp - 2)[0];
                    const b = (sp - 1)[0];
                    var r: Value = undefined;
                    if (a.isNumber() and b.isNumber()) {
                        r = Value.fromNumber(if (o == .mul) a.asNumber() * b.asNumber() else a.asNumber() / b.asNumber());
                    } else {
                        sync(vm, f, pc, sp);
                        r = ok(Value, ops.arith(vm, if (o == .mul) .mul else .div, a, b), &err) orelse break :dispatch;
                    }
                    (sp - 2)[0] = r;
                    sp -= 1;
                    pc += 1;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                inline .bit_and, .bit_or, .bit_xor, .shl, .sar, .shr => |o| {
                    const a = (sp - 2)[0];
                    const b = (sp - 1)[0];
                    var r: Value = undefined;
                    if (a.isInt() and b.isInt()) {
                        const x = a.asInt();
                        const y = b.asInt();
                        const s: u5 = @truncate(@as(u32, @bitCast(y)));
                        r = switch (o) {
                            .bit_and => Value.fromInt(x & y),
                            .bit_or => Value.fromInt(x | y),
                            .bit_xor => Value.fromInt(x ^ y),
                            .shl => Value.fromInt(@bitCast(@as(u32, @bitCast(x)) << s)),
                            .sar => Value.fromInt(x >> s),
                            else => Value.fromUsize(@as(u32, @bitCast(x)) >> s),
                        };
                    } else {
                        sync(vm, f, pc, sp);
                        r = ok(Value, ops.bitop(vm, o, a, b), &err) orelse break :dispatch;
                    }
                    (sp - 2)[0] = r;
                    sp -= 1;
                    pc += 1;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                inline .lt, .le, .gt, .ge => |o| {
                    const a = (sp - 2)[0];
                    const b = (sp - 1)[0];
                    var r: bool = undefined;
                    if (a.isInt() and b.isInt()) {
                        const x = a.asInt();
                        const y = b.asInt();
                        r = switch (o) {
                            .lt => x < y,
                            .le => x <= y,
                            .gt => x > y,
                            else => x >= y,
                        };
                    } else if (a.isNumber() and b.isNumber()) {
                        const x = a.asNumber();
                        const y = b.asNumber();
                        r = switch (o) {
                            .lt => x < y,
                            .le => x <= y,
                            .gt => x > y,
                            else => x >= y,
                        };
                    } else {
                        sync(vm, f, pc, sp);
                        r = ok(bool, ops.compare(vm, o, a, b), &err) orelse break :dispatch;
                    }
                    (sp - 2)[0] = Value.fromBool(r);
                    sp -= 1;
                    pc += 1;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                inline .seq, .sne, .eq, .ne => |o| {
                    const a = (sp - 2)[0];
                    const b = (sp - 1)[0];
                    var r: bool = undefined;
                    if (a.isInt() and b.isInt()) {
                        r = a.bits == b.bits;
                    } else if ((o == .eq or o == .ne) and (a.isNullish() or b.isNullish())) {
                        r = ops.nullishOrDda(a) and ops.nullishOrDda(b);
                    } else {
                        sync(vm, f, pc, sp);
                        r = ok(bool, if (o == .seq or o == .sne) ops.strictEquals(vm, a, b) else ops.looseEquals(vm, a, b), &err) orelse break :dispatch;
                    }
                    (sp - 2)[0] = Value.fromBool(r == (o == .seq or o == .eq));
                    sp -= 1;
                    pc += 1;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .not => {
                    (sp - 1)[0] = Value.fromBool(!ops.truthy((sp - 1)[0]));
                    pc += 1;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                inline .inc, .dec => |o| {
                    const a = (sp - 1)[0];
                    if (a.isInt() and a.asInt() != std.math.maxInt(i32) and a.asInt() != std.math.minInt(i32)) {
                        (sp - 1)[0] = Value.fromInt(if (o == .inc) a.asInt() + 1 else a.asInt() - 1);
                    } else {
                        sync(vm, f, pc, sp);
                        (sp - 1)[0] = ok(Value, ops.incDec(vm, a, o == .inc), &err) orelse break :dispatch;
                    }
                    pc += 1;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .jump => {
                    pc = jumpTo(pc + 5, relAt(pc + 1));
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .loop => {
                    pc = jumpTo(pc + 5, relAt(pc + 1));
                    f.fp.hot_count +|= 1;
                    vm.budget -= 1;
                    if (vm.budget <= 0) {
                        sync(vm, f, pc, sp);
                        ok(void, calls.interrupt(vm), &err) orelse break :dispatch;
                    }
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .jump_false => {
                    sp -= 1;
                    pc = if (ops.truthy(sp[0])) pc + 5 else jumpTo(pc + 5, relAt(pc + 1));
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .jump_true => {
                    sp -= 1;
                    pc = if (ops.truthy(sp[0])) jumpTo(pc + 5, relAt(pc + 1)) else pc + 5;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .jump_false_keep => {
                    if (ops.truthy((sp - 1)[0])) {
                        sp -= 1;
                        pc += 5;
                    } else pc = jumpTo(pc + 5, relAt(pc + 1));
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .jump_true_keep => {
                    if (ops.truthy((sp - 1)[0])) {
                        pc = jumpTo(pc + 5, relAt(pc + 1));
                    } else {
                        sp -= 1;
                        pc += 5;
                    }
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .call => {
                    argc = u16At(pc + 1);
                    pc += 3;
                    continue :sw .do_call;
                },
                .do_call => {
                    const callee = (sp - argc - 1)[0];
                    sync(vm, f, pc, sp);
                    if (callee.isObject() and callee.asObject().class == .closure) {
                        f = ok(*Frame, calls.pushClosure(vm, callee.asObject(), sp - argc, argc, sp - argc - 2, Value.undefined, (sp - argc - 2)[0], false), &err) orelse break :dispatch;
                        pc = f.pc;
                        bp = f.bp;
                        sp = vm.sp;
                        continue :loop;
                    }
                    const r = ok(Value, calls.callNonClosure(vm, callee, (sp - argc - 2)[0], (sp - argc)[0..argc]), &err) orelse break :dispatch;
                    sp -= argc + 1;
                    (sp - 1)[0] = r;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .new_ => {
                    argc = u16At(pc + 1);
                    pc += 3;
                    continue :sw .do_new;
                },
                .do_new => {
                    const callee = (sp - argc - 1)[0];
                    sync(vm, f, pc, sp);
                    if (callee.isObject() and callee.asObject().class == .closure and callee.asObject().flags.constructor) {
                        const co = callee.asObject();
                        const this = if (co.flags.derived_ctor) Value.hole else (ok(*Object, calls.allocThis(vm, co, callee), &err) orelse break :dispatch).value();
                        f = ok(*Frame, calls.pushClosure(vm, co, sp - argc, argc, sp - argc - 2, callee, this, true), &err) orelse break :dispatch;
                        pc = f.pc;
                        bp = f.bp;
                        sp = vm.sp;
                        continue :loop;
                    }
                    const r = ok(Value, calls.construct(vm, callee, (sp - argc)[0..argc], callee), &err) orelse break :dispatch;
                    sp -= argc + 1;
                    (sp - 1)[0] = r;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                inline .apply, .apply_new => |o| {
                    sync(vm, f, pc, sp);
                    argc = ok(u32, calls.expandArgs(vm, &sp), &err) orelse break :dispatch;
                    pc += 1;
                    continue :sw if (o == .apply) .do_call else .do_new;
                },
                inline .ret, .ret_undef => |o| {
                    var r = Value.undefined;
                    if (o == .ret) {
                        sp -= 1;
                        r = sp[0];
                    }
                    if (f.is_construct or f.co != null) {
                        sync(vm, f, pc, sp);
                        r = ok(Value, calls.returnSpecial(vm, f, r), &err) orelse break :dispatch;
                    }
                    const entry = f.is_entry;
                    sp = f.ret_sp;
                    vm.frame_top -= 1;
                    if (entry) {
                        vm.sp = sp;
                        return r;
                    }
                    sp[0] = r;
                    sp += 1;
                    f = &vm.frames[vm.frame_top - 1];
                    pc = f.pc;
                    bp = f.bp;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                .initial_yield, .yield_, .yield_raw, .await_ => |o| {
                    sync(vm, f, pc, sp);
                    const r = ok(Value, slow.suspendFrame(vm, f, o, sp), &err) orelse break :dispatch;
                    const entry = f.is_entry;
                    sp = f.ret_sp;
                    vm.frame_top -= 1;
                    if (entry) {
                        vm.sp = sp;
                        return r;
                    }
                    sp[0] = r;
                    sp += 1;
                    f = &vm.frames[vm.frame_top - 1];
                    pc = f.pc;
                    bp = f.bp;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
                else => |o| {
                    sync(vm, f, pc, sp);
                    ok(void, slow.exec(vm, f, o), &err) orelse break :dispatch;
                    pc = f.pc;
                    sp = vm.sp;
                    continue :sw @fromBackingInt(@intCast(pc[0]));
                },
            }
        }
        // An exception (or termination) unwinds to a handler or leaves this run().
        switch (unwind.unwind(vm, sp, err)) {
            .resume_top => {
                f = &vm.frames[vm.frame_top - 1];
                pc = f.pc;
                bp = f.bp;
                sp = vm.sp;
            },
            .value => |v| return v,
            .err => |e| return e,
        }
    }
}
