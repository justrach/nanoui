//! Opcodes that are not hot enough for the dispatch loop. exec reads the operands
//! at f.pc, works on vm.sp, and leaves both pointing at the next state.

const std = @import("std");
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
const heap = @import("heap.zig");
const objmod = @import("object.zig");
const Object = objmod.Object;
const props = @import("props.zig");
const conv = @import("conv.zig");
const ops = @import("ops.zig");
const str = @import("string.zig");
const icache = @import("interp_ic.zig");
const calls = @import("interp_call.zig");
const iter = @import("iter.zig");
const coroutine = @import("coroutine.zig");
const objectops = @import("interp_object.zig");
const module = @import("module.zig");
const shape = @import("shape.zig");

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

/// Raises the dead-zone ReferenceError for a checked read or write.
pub fn throwTdz(vm: *Vm, f: *Frame, name_idx: u32) Error {
    const name = f.fp.constants[name_idx].asString();
    if (name == vm.k.this.atom()) {
        return vm.throwError(.ReferenceError, "Must call super constructor in derived class before accessing 'this' or returning from derived constructor");
    }
    return icache.throwTdzKey(vm, PropKey.fromAtom(name));
}

/// initial_yield, yield and await: save the frame; the value goes to whoever is resuming.
pub fn suspendFrame(vm: *Vm, f: *Frame, op: Op, sp: [*]Value) Error!Value {
    return coroutine.suspendFrame(vm, f, op, sp);
}

fn numericBinary(vm: *Vm, op: Op) Error!void {
    const sp = vm.sp;
    const a = (sp - 2)[0];
    const b = (sp - 1)[0];
    (sp - 2)[0] = switch (op) {
        .mod => try ops.modulo(vm, a, b),
        else => try ops.arith(vm, .pow, a, b),
    };
    vm.sp = sp - 1;
}

/// HasBinding on a `with` object, honouring Symbol.unscopables.
fn withHas(vm: *Vm, w: *Object, key: PropKey) Error!bool {
    if (!try props.has(vm, w, key)) return false;
    const u = try props.get(vm, w, PropKey.fromSymbol(vm.sym.unscopables));
    if (u.isObject()) return !ops.truthy(try props.get(vm, u.asObject(), key));
    return true;
}

fn execWith(vm: *Vm, f: *Frame, op: Op) Error!void {
    const sp = vm.sp;
    const pc = f.pc;
    const key = try str.toKey(vm, f.fp.constants[u32At(pc + 1)].asString());
    const w = (sp - 1)[0].asObject();
    const target = jumpTo(pc + 9, relAt(pc + 5));
    f.pc = pc + 9;
    if (!try withHas(vm, w, key)) {
        vm.sp = sp - 1;
        return;
    }
    f.pc = target;
    switch (op) {
        .with_get => (sp - 1)[0] = try props.get(vm, w, key),
        .with_get_call => {
            sp[0] = try props.get(vm, w, key);
            vm.sp = sp + 1;
        },
        .with_put => {
            if (!try props.set(vm, w, key, (sp - 2)[0]) and f.fp.strict) return props.throwReadonly(vm, key);
            vm.sp = sp - 1;
        },
        else => (sp - 1)[0] = Value.fromBool(try props.delete(vm, w, key)),
    }
}

pub fn exec(vm: *Vm, f: *Frame, op: Op) Error!void {
    var sp = vm.sp;
    const pc = f.pc;
    switch (op) {
        .int32 => {
            sp[0] = Value.fromInt(@bitCast(u32At(pc + 1)));
            vm.sp = sp + 1;
            f.pc = pc + 5;
        },
        .dup2 => {
            sp[0] = (sp - 2)[0];
            sp[1] = (sp - 1)[0];
            vm.sp = sp + 2;
            f.pc = pc + 1;
        },
        .swap => {
            const t = (sp - 1)[0];
            (sp - 1)[0] = (sp - 2)[0];
            (sp - 2)[0] = t;
            f.pc = pc + 1;
        },
        .nip => {
            (sp - 2)[0] = (sp - 1)[0];
            vm.sp = sp - 1;
            f.pc = pc + 1;
        },
        .put_loc_check => {
            const i = u16At(pc + 1);
            if (f.bp[i].isHole()) return throwTdz(vm, f, u32At(pc + 3));
            f.bp[i] = (sp - 1)[0];
            vm.sp = sp - 1;
            f.pc = pc + 7;
        },
        .get_env_check => {
            var e = f.env.?;
            var d = pc[1];
            while (d != 0) : (d -= 1) e = e.parent.?;
            const v = e.slots()[u16At(pc + 2)];
            if (v.isHole()) return throwTdz(vm, f, u32At(pc + 4));
            sp[0] = v;
            vm.sp = sp + 1;
            f.pc = pc + 8;
        },
        .put_env_check => {
            var e = f.env.?;
            var d = pc[1];
            while (d != 0) : (d -= 1) e = e.parent.?;
            const s = &e.slots()[u16At(pc + 2)];
            if (s.isHole()) return throwTdz(vm, f, u32At(pc + 4));
            s.* = (sp - 1)[0];
            vm.sp = sp - 1;
            f.pc = pc + 8;
        },
        .set_hole => {
            f.bp[u16At(pc + 1)] = Value.hole;
            f.pc = pc + 3;
        },
        .get_elem2 => {
            (sp - 1)[0] = try icache.getElem(vm, (sp - 2)[0], (sp - 1)[0]);
            f.pc = pc + 1;
        },
        .to_numeric => {
            const a = (sp - 1)[0];
            if (!a.isNumber()) (sp - 1)[0] = try ops.toNumeric(vm, a);
            f.pc = pc + 1;
        },
        .jump_notnull_keep => {
            if ((sp - 1)[0].isNullish()) {
                vm.sp = sp - 1;
                f.pc = pc + 5;
            } else f.pc = jumpTo(pc + 5, relAt(pc + 1));
        },
        .jump_not_undef => {
            if ((sp - 1)[0].isUndefined()) {
                vm.sp = sp - 1;
                f.pc = pc + 5;
            } else f.pc = jumpTo(pc + 5, relAt(pc + 1));
        },
        .opt_chain => {
            if ((sp - 1)[0].isNullish()) {
                const extra: usize = pc[5];
                (sp - 1 - extra)[0] = Value.undefined;
                vm.sp = sp - extra;
                f.pc = jumpTo(pc + 5, relAt(pc + 1));
            } else f.pc = pc + 6;
        },
        .callee => {
            sp[0] = f.func.value();
            vm.sp = sp + 1;
            f.pc = pc + 1;
        },
        .new_target => {
            sp[0] = f.new_target;
            vm.sp = sp + 1;
            f.pc = pc + 1;
        },
        .home => {
            const x = f.func.extra();
            sp[0] = if (x != null and x.?.home != null) x.?.home.?.value() else Value.undefined;
            vm.sp = sp + 1;
            f.pc = pc + 1;
        },
        .arguments => {
            sp[0] = (try objectops.argumentsObject(vm, f)).value();
            vm.sp = sp + 1;
            f.pc = pc + 1;
        },
        .args_get => {
            const slot = u16At(pc + 1);
            if (f.bp[slot].isHole()) f.bp[slot] = (try objectops.argumentsObject(vm, f)).value();
            sp[0] = f.bp[slot];
            vm.sp = sp + 1;
            f.pc = pc + 3;
        },
        .args_len => {
            const slot = u16At(pc + 1);
            const cur = f.bp[slot];
            sp[0] = if (cur.isHole()) Value.fromUsize(f.argc) else try props.getV(vm, cur, vm.k.length);
            vm.sp = sp + 1;
            f.pc = pc + 3;
        },
        .args_elem => {
            const slot = u16At(pc + 1);
            const idx = (sp - 1)[0];
            if (f.bp[slot].isHole()) {
                if (idx.isInt() and idx.asInt() >= 0) {
                    const i: u32 = @intCast(idx.asInt());
                    if (i < f.argc) {
                        (sp - 1)[0] = f.args[i];
                        f.pc = pc + 3;
                        return;
                    }
                    if (!vm.protos.object.flags.proto_dirty) {
                        (sp - 1)[0] = Value.undefined;
                        f.pc = pc + 3;
                        return;
                    }
                }
                f.bp[slot] = (try objectops.argumentsObject(vm, f)).value();
            }
            (sp - 1)[0] = try icache.getElem(vm, f.bp[slot], idx);
            f.pc = pc + 3;
        },
        .args_apply => {
            const slot = u16At(pc + 1);
            const recv = (sp - 3)[0];
            const fn_val = (sp - 2)[0];
            const this_arg = (sp - 1)[0];
            f.pc = pc + 3;
            if (f.bp[slot].isHole() and fn_val.isObject() and fn_val.asObject().class == .native and fn_val.asObject().payload.native.func == &@import("b_function.zig").fnApply) {
                vm.sp = sp - 3;
                const r = try calls.call(vm, recv, this_arg, f.args[0..f.argc]);
                (sp - 3)[0] = r;
                vm.sp = sp - 2;
                return;
            }
            if (f.bp[slot].isHole()) f.bp[slot] = (try objectops.argumentsObject(vm, f)).value();
            vm.sp = sp - 3;
            const r = try calls.call(vm, fn_val, recv, &.{ this_arg, f.bp[slot] });
            (sp - 3)[0] = r;
            vm.sp = sp - 2;
        },
        .rest => {
            const first = u16At(pc + 1);
            const items = if (f.argc > first) f.args[first..f.argc] else f.args[0..0];
            sp[0] = (try objmod.newArray(vm, items)).value();
            vm.sp = sp + 1;
            f.pc = pc + 3;
        },
        .insert2 => {
            const b = (sp - 1)[0];
            const a = (sp - 2)[0];
            (sp - 2)[0] = b;
            (sp - 1)[0] = a;
            sp[0] = b;
            vm.sp = sp + 1;
            f.pc = pc + 1;
        },
        .insert3 => {
            const c = (sp - 1)[0];
            const b = (sp - 2)[0];
            const a = (sp - 3)[0];
            (sp - 3)[0] = c;
            (sp - 2)[0] = a;
            (sp - 1)[0] = b;
            sp[0] = c;
            vm.sp = sp + 1;
            f.pc = pc + 1;
        },
        .rot3l => {
            const c = (sp - 1)[0];
            const b = (sp - 2)[0];
            const a = (sp - 3)[0];
            (sp - 3)[0] = b;
            (sp - 2)[0] = c;
            (sp - 1)[0] = a;
            f.pc = pc + 1;
        },
        .rot3r => {
            const c = (sp - 1)[0];
            const b = (sp - 2)[0];
            const a = (sp - 3)[0];
            (sp - 3)[0] = c;
            (sp - 2)[0] = a;
            (sp - 1)[0] = b;
            f.pc = pc + 1;
        },
        .push_env => {
            const n = u16At(pc + 1);
            const e = try vm.heap.newEnv(f.env, n);
            @memset(e.slots()[0..n], Value.hole);
            f.env = e;
            f.pc = pc + 3;
        },
        .pop_env => {
            f.env = f.env.?.parent;
            f.pc = pc + 1;
        },
        .clone_env => {
            const old = f.env.?;
            const e = try vm.heap.newEnv(old.parent, old.len);
            @memcpy(e.slots()[0..old.len], old.slots()[0..old.len]);
            f.env = e;
            f.pc = pc + 1;
        },
        .get_global_typeof => {
            sp[0] = try icache.getGlobalOrUndefined(vm, &f.fp.ics[u32At(pc + 1)]);
            vm.sp = sp + 1;
            f.pc = pc + 5;
        },
        .decl_global_var => {
            const name = f.fp.constants[u32At(pc + 1)].asString();
            try icache.declareGlobalVar(vm, try str.toKey(vm, name));
            f.pc = pc + 5;
        },
        .def_global_fn => {
            const name = f.fp.constants[u32At(pc + 1)].asString();
            try icache.defineGlobalFn(vm, try str.toKey(vm, name), (sp - 1)[0]);
            vm.sp = sp - 1;
            f.pc = pc + 5;
        },
        .decl_global_lex => {
            const name = f.fp.constants[u32At(pc + 1)].asString();
            try icache.declareGlobalLex(vm, try str.toKey(vm, name), pc[5] != 0);
            f.pc = pc + 6;
        },
        .init_global_lex => {
            try icache.initGlobalLex(vm, &f.fp.ics[u32At(pc + 1)], (sp - 1)[0]);
            vm.sp = sp - 1;
            f.pc = pc + 5;
        },
        .delete_global => {
            const name = f.fp.constants[u32At(pc + 1)].asString();
            const key = try str.toKey(vm, name);
            sp[0] = Value.fromBool(if (vm.global_lex.shape.find(key) != null) false else try props.delete(vm, vm.global_obj, key));
            vm.sp = sp + 1;
            f.pc = pc + 5;
        },
        .get_import => {
            sp[0] = try module.getImport(vm, f.fp.module.?, u32At(pc + 1));
            vm.sp = sp + 1;
            f.pc = pc + 5;
        },
        .import_meta => {
            sp[0] = try module.importMeta(vm, f.fp.module.?);
            vm.sp = sp + 1;
            f.pc = pc + 1;
        },
        .dynamic_import => {
            (sp - 1)[0] = try module.dynamicImport(vm, f.fp, (sp - 1)[0]);
            f.pc = pc + 1;
        },
        .delete_elem => {
            const t = (sp - 2)[0];
            const key = try conv.toPropKey(vm, (sp - 1)[0]);
            if (t.isNullish()) return vm.throwError(.TypeError, "Cannot convert undefined or null to object");
            const o = try conv.toObject(vm, t);
            const ok = try props.delete(vm, o, key);
            if (!ok and f.fp.strict) {
                var buf: [96]u8 = undefined;
                const name = str.keyText(vm, key, buf[0..32]);
                const m = std.fmt.bufPrint(buf[32..], "Cannot delete property '{s}'", .{name[0..@min(name.len, 24)]}) catch "Cannot delete property";
                return vm.throwError(.TypeError, m);
            }
            (sp - 2)[0] = Value.fromBool(ok);
            vm.sp = sp - 1;
            f.pc = pc + 1;
        },
        .mod => {
            const a = (sp - 2)[0];
            const b = (sp - 1)[0];
            if (a.isInt() and b.isInt() and a.asInt() >= 0 and b.asInt() > 0) {
                (sp - 2)[0] = Value.fromInt(@rem(a.asInt(), b.asInt()));
                vm.sp = sp - 1;
            } else {
                try numericBinary(vm, .mod);
            }
            f.pc = pc + 1;
        },
        .pow => {
            try numericBinary(vm, .pow);
            f.pc = pc + 1;
        },
        .eq, .ne => {
            const r = try ops.looseEquals(vm, (sp - 2)[0], (sp - 1)[0]);
            (sp - 2)[0] = Value.fromBool(r == (op == .eq));
            vm.sp = sp - 1;
            f.pc = pc + 1;
        },
        .neg => {
            (sp - 1)[0] = try ops.negate(vm, (sp - 1)[0]);
            f.pc = pc + 1;
        },
        .plus => {
            (sp - 1)[0] = Value.fromNumber(try conv.toNumber(vm, (sp - 1)[0]));
            f.pc = pc + 1;
        },
        .bit_not => {
            (sp - 1)[0] = try ops.bitNot(vm, (sp - 1)[0]);
            f.pc = pc + 1;
        },
        .typeof_ => {
            (sp - 1)[0] = ops.typeOf(vm, (sp - 1)[0]);
            f.pc = pc + 1;
        },
        .to_propkey => {
            const v = (sp - 1)[0];
            if (!v.isInt() and !v.isString() and !v.isSymbol()) {
                (sp - 1)[0] = try str.keyToValue(vm, try conv.toPropKey(vm, v));
            }
            f.pc = pc + 1;
        },
        .to_str => {
            const v = (sp - 1)[0];
            if (!v.isString()) (sp - 1)[0] = Value.fromString(try conv.toStr(vm, v));
            f.pc = pc + 1;
        },
        .instanceof_ => {
            (sp - 2)[0] = Value.fromBool(try ops.instanceOf(vm, (sp - 2)[0], (sp - 1)[0]));
            vm.sp = sp - 1;
            f.pc = pc + 1;
        },
        .in_ => {
            const r = (sp - 1)[0];
            if (!r.isObject()) return vm.throwError(.TypeError, "Cannot use 'in' operator on a non-object");
            const k = (sp - 2)[0];
            const ro = r.asObject();
            if (k.isString()) {
                const s = k.asString();
                if (try str.findExistingKey(vm, s)) |ek| {
                    (sp - 2)[0] = Value.fromBool(try props.has(vm, ro, ek));
                    vm.sp = sp - 1;
                    f.pc = pc + 1;
                    return;
                }
                if (icache.noExoticOnChain(ro)) {
                    (sp - 2)[0] = Value.false;
                    vm.sp = sp - 1;
                    f.pc = pc + 1;
                    return;
                }
            }
            const key = try conv.toPropKey(vm, k);
            (sp - 2)[0] = Value.fromBool(try props.has(vm, ro, key));
            vm.sp = sp - 1;
            f.pc = pc + 1;
        },
        .throw_ => {
            vm.exception = (sp - 1)[0];
            return error.Thrown;
        },
        .throw_const => {
            const name = f.fp.constants[u32At(pc + 1)].asString();
            if (name == vm.k.this.atom()) return vm.throwError(.TypeError, "Invalid assignment to this");
            return vm.throwError(.TypeError, "Assignment to constant variable.");
        },
        .check_coercible => {
            const v = (sp - 1)[0];
            if (v.isNullish()) {
                return vm.throwError(.TypeError, if (v.isNull()) "Cannot destructure 'null' as it is null." else "Cannot destructure 'undefined' as it is undefined.");
            }
            f.pc = pc + 1;
        },
        .push_try => {
            const rel = relAt(pc + 1);
            const target = jumpTo(pc + 5, rel);
            sp[0] = if (f.env) |e| Value.fromCell(&e.cell) else Value.undefined;
            sp[1] = fr.catchMarker(@intCast(@intFromPtr(target) - @intFromPtr(f.fp.code.ptr)));
            vm.sp = sp + 2;
            f.pc = pc + 5;
        },
        .pop_try => {
            vm.sp = sp - 2;
            f.pc = pc + 1;
        },
        .gosub => {
            const ret: u32 = @intCast(@intFromPtr(pc + 5) - @intFromPtr(f.fp.code.ptr));
            sp[0] = Value.fromInt(@intCast(ret));
            vm.sp = sp + 1;
            f.pc = jumpTo(pc + 5, relAt(pc + 1));
        },
        .ret_sub => {
            const ret: u32 = @intCast((sp - 1)[0].asInt());
            vm.sp = sp - 1;
            f.pc = f.fp.code.ptr + ret;
        },
        .ctor_ret_check => {
            const v = (sp - 1)[0];
            if (v.isObject()) {
                f.pc = jumpTo(pc + 5, relAt(pc + 1));
            } else if (v.isUndefined()) {
                vm.sp = sp - 1;
                f.pc = pc + 5;
            } else {
                return vm.throwError(.TypeError, "Derived constructors may only return object or undefined");
            }
        },
        .to_object => {
            (sp - 1)[0] = (try conv.toObject(vm, (sp - 1)[0])).value();
            f.pc = pc + 1;
        },
        .new_object => {
            sp[0] = (try objmod.newPlain(vm)).value();
            vm.sp = sp + 1;
            f.pc = pc + 1;
        },
        .define_field => {
            const ic = &f.fp.ics[u32At(pc + 1)];
            const o = (sp - 2)[0].asObject();
            const v = (sp - 1)[0];
            if (o.shape == ic.shape and ic.is_transition and ic.slot < o.slot_cap and !o.flags.is_proto) {
                o.shape = ic.holder_shape.?;
                o.slots[ic.slot] = v;
            } else {
                try icache.defineField(vm, ic, o, v);
            }
            vm.sp = sp - 1;
            f.pc = pc + 5;
        },
        .array_from => {
            const n = u32At(pc + 1);
            const arr = try objmod.newArray(vm, (sp - n)[0..n]);
            (sp - n)[0] = arr.value();
            vm.sp = sp - n + 1;
            f.pc = pc + 5;
        },
        .array_append => {
            try objmod.arrayPush(vm, (sp - 2)[0].asObject(), (sp - 1)[0]);
            vm.sp = sp - 1;
            f.pc = pc + 1;
        },
        .closure => {
            sp[0] = (try objectops.makeClosure(vm, f.fp.protos[u32At(pc + 1)], f.env)).value();
            vm.sp = sp + 1;
            f.pc = pc + 5;
        },
        .with_get, .with_get_call, .with_put, .with_delete => try execWith(vm, f, op),
        .nop => f.pc = pc + 1,
        else => return iter.execIter(vm, f, op) catch |e| return e,
    }
}
