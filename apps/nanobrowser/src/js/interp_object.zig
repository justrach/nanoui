//! Opcodes that build things: objects, arrays, closures, classes, private members,
//! and the super forms.

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
const str = @import("string.zig");
const shape = @import("shape.zig");
const PropFlags = shape.PropFlags;
const icache = @import("interp_ic.zig");
const calls = @import("interp_call.zig");
const iter = @import("iter.zig");
const regexp = @import("b_regexp.zig");

inline fn u16At(p: [*]const u8) u32 {
    return std.mem.readInt(u16, p[0..2], .little);
}
inline fn u32At(p: [*]const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .little);
}

pub fn argumentsObject(vm: *Vm, f: *Frame) Error!*Object {
    const sh = if (f.fp.strict) vm.args_strict_shape else vm.args_sloppy_shape;
    const a = try objmod.alloc(vm, sh, .arguments);
    const n = f.argc;
    if (n != 0) {
        if (n <= objmod.inline_slots - 3) {
            a.slot_cap = 3;
            a.elems = @as([*]Value, &a.inline_store) + 3;
            a.elems_cap = objmod.inline_slots - 3;
        } else {
            try objmod.growElems(vm, a, n);
        }
        @memcpy(a.elems[0..n], f.args[0..n]);
        a.elems_len = n;
    }
    a.arr_len = n;
    a.slots[0] = Value.fromUsize(n);
    a.slots[1] = vm.protos.array_values.value();
    if (!f.fp.strict) a.slots[2] = f.func.value();
    return a;
}

/// A new closure over env; its name, length and prototype appear on first use.
pub fn makeClosure(vm: *Vm, fp: *bc.FuncProto, env: ?*heap.Env) Error!*Object {
    const proto_shape = if (fp.is_generator)
        try shape.rootFor(vm, if (fp.is_async) vm.protos.async_generator_function else vm.protos.generator_function)
    else if (fp.is_async)
        try shape.rootFor(vm, vm.protos.async_function)
    else
        vm.fn_root;
    const o = try objmod.alloc(vm, proto_shape, .closure);
    o.payload = .{ .fp = fp };
    o.env = env;
    o.flags.callable = true;
    o.flags.lazy_fn = true;
    o.flags.constructor = fp.has_prototype and !fp.is_generator;
    if (fp.needs_home) {
        const x = try vm.gpa.create(objmod.FnExtra);
        x.* = .{};
        o.host = x;
    }
    return o;
}

/// SetFunctionName for names only known at run time; accessors get their prefix.
fn setFunctionName(vm: *Vm, fnv: Value, key: PropKey, prefix: []const u8) Error!void {
    if (!fnv.isObject()) return;
    var b = str.Builder.init(vm);
    defer b.deinit();
    try b.bytes(prefix);
    if (key.isSymbol()) {
        if (key.symbol().description) |d| {
            if (key.symbol().is_private) {
                try b.str(d);
            } else {
                try b.byte('[');
                try b.str(d);
                try b.byte(']');
            }
        }
    } else {
        try b.str((try str.keyToValue(vm, key)).asString());
    }
    try props.defineData(vm, fnv.asObject(), vm.k.name, Value.fromString(try b.finish()), PropFlags.config_only);
}

fn setHome(vm: *Vm, fnv: Value, home: *Object) Error!void {
    const o = fnv.asObject();
    if (o.class != .closure) return;
    if (!o.payload.fp.needs_home) return;
    if (o.extra()) |x| {
        x.home = home;
    } else {
        const x = try vm.gpa.create(objmod.FnExtra);
        x.* = .{ .home = home };
        o.host = x;
    }
}

pub fn defineMethod(vm: *Vm, target: *Object, key: PropKey, fnv: Value, flags: u8) Error!void {
    const kind = flags & 3;
    const enumerable = flags & 4 != 0;
    try setHome(vm, fnv, target);
    const fp = fnv.asObject().payload.fp;
    if (kind == 1) {
        try setFunctionName(vm, fnv, key, "get ");
        try props.defineAccessorMerge(vm, target, key, fnv, null, enumerable);
    } else if (kind == 2) {
        try setFunctionName(vm, fnv, key, "set ");
        try props.defineAccessorMerge(vm, target, key, null, fnv, enumerable);
    } else {
        if (fp.name.byte_len == 0) try setFunctionName(vm, fnv, key, "");
        try props.defineData(vm, target, key, fnv, if (enumerable) PropFlags.all else PropFlags.hidden);
    }
}

fn privateKey(v: Value) PropKey {
    return PropKey.fromSymbol(v.asSymbol());
}

fn privateError(vm: *Vm, action: []const u8, key: PropKey) Error {
    var b: [160]u8 = undefined;
    const name = key.symbol().description.?.flat(vm) catch "#private";
    const m = std.fmt.bufPrint(&b, "Cannot {s} private member {s} from an object whose class did not declare it", .{ action, name[0..@min(name.len, 40)] }) catch "Cannot access private member";
    return vm.throwError(.TypeError, m);
}

fn getPrivate(vm: *Vm, t: Value, key: PropKey) Error!Value {
    if (!t.isObject()) return privateError(vm, "read", key);
    const o = t.asObject();
    const s = o.shape.find(key) orelse return privateError(vm, "read", key);
    if (o.shape.flagsAt(s).accessor) {
        const a: *heap.Accessor = @fieldParentPtr("cell", o.slots[s].asCell());
        if (a.get.isUndefined()) return vm.throwError(.TypeError, "'#accessor' was defined without a getter");
        return calls.call(vm, a.get, t, &.{});
    }
    return o.slots[s];
}

fn putPrivate(vm: *Vm, t: Value, key: PropKey, v: Value) Error!void {
    if (!t.isObject()) return privateError(vm, "write", key);
    const o = t.asObject();
    const s = o.shape.find(key) orelse return privateError(vm, "write", key);
    const f = o.shape.flagsAt(s);
    if (f.accessor) {
        const a: *heap.Accessor = @fieldParentPtr("cell", o.slots[s].asCell());
        if (a.set.isUndefined()) return vm.throwError(.TypeError, "'#accessor' was defined without a setter");
        _ = try calls.call(vm, a.set, t, &.{v});
        return;
    }
    if (!f.writable) return vm.throwError(.TypeError, "Private method is not writable");
    o.slots[s] = v;
}

fn definePrivateMethod(vm: *Vm, o: *Object, key: PropKey, fnv: Value, kind: u8) Error!void {
    try setHome(vm, fnv, o);
    const f = PropFlags{ .writable = false, .enumerable = false, .configurable = false };
    if (kind == 0) {
        if (o.shape.find(key) != null) return vm.throwError(.TypeError, "Cannot initialize private method twice on the same object");
        try props.addProp(vm, o, key, fnv, f);
        return;
    }
    if (o.shape.find(key)) |s| {
        const a: *heap.Accessor = @fieldParentPtr("cell", o.slots[s].asCell());
        const na = try vm.heap.newAccessor(if (kind == 1) fnv else a.get, if (kind == 2) fnv else a.set);
        o.slots[s] = Value.fromCell(&na.cell);
        return;
    }
    const na = try vm.heap.newAccessor(if (kind == 1) fnv else Value.undefined, if (kind == 2) fnv else Value.undefined);
    try props.addProp(vm, o, key, Value.fromCell(&na.cell), .{ .writable = false, .enumerable = false, .configurable = false, .accessor = true });
}

fn makeClass(vm: *Vm, f: *Frame, fp: *bc.FuncProto, has_parent: bool, parent: Value) Error!struct { ctor: *Object, proto: *Object } {
    var proto_parent: ?*Object = vm.protos.object;
    var ctor_parent: *Object = vm.protos.function;
    if (has_parent) {
        if (parent.isNull()) {
            proto_parent = null;
        } else {
            if (!parent.isConstructor()) return vm.throwError(.TypeError, "Class extends value is not a constructor or null");
            const pp = try props.getV(vm, parent, vm.k.prototype);
            if (pp.isObject()) {
                proto_parent = pp.asObject();
            } else if (pp.isNull()) {
                proto_parent = null;
            } else {
                return vm.throwError(.TypeError, "Class extends value does not have valid prototype property");
            }
            ctor_parent = parent.asObject();
        }
    }
    const proto = try objmod.create(vm, proto_parent, .object);
    const ctor = try objmod.alloc(vm, try shape.rootFor(vm, ctor_parent), .closure);
    ctor.payload = .{ .fp = fp };
    ctor.env = f.env;
    ctor.flags.callable = true;
    ctor.flags.constructor = true;
    ctor.flags.class_ctor = true;
    ctor.flags.derived_ctor = fp.is_derived;
    const x = try vm.gpa.create(objmod.FnExtra);
    x.* = .{ .home = proto, .inst_shape = try shape.rootFor(vm, proto) };
    ctor.host = x;
    try props.addProp(vm, ctor, vm.k.length, Value.fromUsize(fp.length), PropFlags.config_only);
    try props.addProp(vm, ctor, vm.k.name, Value.fromString(fp.name), PropFlags.config_only);
    try props.addProp(vm, ctor, vm.k.prototype, proto.value(), PropFlags.readonly);
    try props.addProp(vm, proto, vm.k.constructor, ctor.value(), PropFlags.hidden);
    return .{ .ctor = ctor, .proto = proto };
}

/// Runs a class's field initializers on a new instance, if it has any.
pub fn runFields(vm: *Vm, this: Value, func: Value) Error!void {
    const x = func.asObject().extra() orelse return;
    if (x.fields.isUndefined()) return;
    _ = try calls.call(vm, x.fields, this, &.{});
}

pub fn copyDataProps(vm: *Vm, target: *Object, src: Value, excluded: []const Value) Error!void {
    if (src.isNullish()) return;
    if (src.isObject()) {
        const from = src.asObject();
        if (from.shape.all_plain_str and !from.flags.exotic and !from.flags.lazy_fn and from.elems_len == 0 and from.class == .object) {
            if (excluded.len == 0 and target.shape == vm.object_root and target.elems_len == 0 and !target.flags.is_proto and from.shape.proto == vm.protos.object) {
                const n = from.shape.count;
                if (n > target.slot_cap) try objmod.growSlots(vm, target, n);
                @memcpy(target.slots[0..n], from.slots[0..n]);
                target.shape = from.shape;
                return;
            }
            if (excluded.len == 0) {
                for (from.shape.entries(), 0..) |e, slot| {
                    try props.defineData(vm, target, e.key, from.slots[slot], PropFlags.all);
                }
                return;
            }
        }
    }
    const from = try conv.toObject(vm, src);
    const keys = try props.ownKeys(vm, from);
    defer vm.gpa.free(keys);
    outer: for (keys) |k| {
        for (excluded) |ex| {
            if ((try conv.toPropKey(vm, ex)).eql(k)) continue :outer;
        }
        const own = try props.getOwn(vm, from, k) orelse continue;
        if (!own.flags.enumerable) continue;
        const v = try props.get(vm, from, k);
        try props.defineData(vm, target, k, v, PropFlags.all);
    }
}

pub fn exec(vm: *Vm, f: *Frame, op: Op) Error!void {
    const sp = vm.sp;
    const pc = f.pc;
    switch (op) {
        .super_get => {
            const home = (sp - 2)[0];
            const key = try conv.toPropKey(vm, (sp - 1)[0]);
            if (!home.isObject()) return vm.throwError(.SyntaxError, "'super' keyword unexpected here");
            const proto = try props.getProto(vm, home.asObject());
            (sp - 3)[0] = if (proto) |p| try props.getR(vm, p, key, (sp - 3)[0]) else Value.undefined;
            vm.sp = sp - 2;
            f.pc = pc + 1;
        },
        .super_put => {
            const home = (sp - 3)[0];
            const key = try conv.toPropKey(vm, (sp - 2)[0]);
            const v = (sp - 1)[0];
            if (!home.isObject()) return vm.throwError(.SyntaxError, "'super' keyword unexpected here");
            const proto = try props.getProto(vm, home.asObject());
            if (proto) |p| {
                if (!try props.setR(vm, p, key, v, (sp - 4)[0]) and f.fp.strict) return props.throwReadonly(vm, key);
            }
            (sp - 4)[0] = v;
            vm.sp = sp - 3;
            f.pc = pc + 1;
        },
        .define_field => {
            const ic = &f.fp.ics[u32At(pc + 1)];
            try icache.defineField(vm, ic, (sp - 2)[0].asObject(), (sp - 1)[0]);
            vm.sp = sp - 1;
            f.pc = pc + 5;
        },
        .define_elem => {
            const key = try conv.toPropKey(vm, (sp - 2)[0]);
            try props.defineData(vm, (sp - 3)[0].asObject(), key, (sp - 1)[0], PropFlags.all);
            vm.sp = sp - 2;
            f.pc = pc + 1;
        },
        .define_method => {
            const key = try conv.toPropKey(vm, (sp - 2)[0]);
            try defineMethod(vm, (sp - 3)[0].asObject(), key, (sp - 1)[0], pc[1]);
            vm.sp = sp - 2;
            f.pc = pc + 2;
        },
        .set_proto => {
            const v = (sp - 1)[0];
            if (v.isObject()) {
                try props.setProtoRaw(vm, (sp - 2)[0].asObject(), v.asObject());
            } else if (v.isNull()) {
                try props.setProtoRaw(vm, (sp - 2)[0].asObject(), null);
            }
            vm.sp = sp - 1;
            f.pc = pc + 1;
        },
        .set_fn_name => {
            try setFunctionName(vm, (sp - 1)[0], try conv.toPropKey(vm, (sp - 2)[0]), "");
            f.pc = pc + 1;
        },
        .home_set => {
            try setHome(vm, (sp - 1)[0], (sp - 2)[0].asObject());
            f.pc = pc + 1;
        },
        .get_private => {
            (sp - 2)[0] = try getPrivate(vm, (sp - 2)[0], privateKey((sp - 1)[0]));
            vm.sp = sp - 1;
            f.pc = pc + 1;
        },
        .put_private => {
            const v = (sp - 1)[0];
            try putPrivate(vm, (sp - 3)[0], privateKey((sp - 2)[0]), v);
            (sp - 3)[0] = v;
            vm.sp = sp - 2;
            f.pc = pc + 1;
        },
        .define_private => {
            const key = privateKey((sp - 2)[0]);
            const o = (sp - 3)[0].asObject();
            if (o.shape.find(key) != null) return vm.throwError(.TypeError, "Cannot initialize private field twice on the same object");
            try props.addProp(vm, o, key, (sp - 1)[0], .{ .enumerable = false, .configurable = false });
            vm.sp = sp - 2;
            f.pc = pc + 1;
        },
        .define_private_method => {
            try definePrivateMethod(vm, (sp - 3)[0].asObject(), privateKey((sp - 2)[0]), (sp - 1)[0], pc[1]);
            vm.sp = sp - 2;
            f.pc = pc + 2;
        },
        .has_private => {
            const r = (sp - 1)[0];
            if (!r.isObject()) return vm.throwError(.TypeError, "Cannot use 'in' operator to search for a private field in a non-object");
            (sp - 2)[0] = Value.fromBool(r.asObject().shape.find(privateKey((sp - 2)[0])) != null);
            vm.sp = sp - 1;
            f.pc = pc + 1;
        },
        .new_private => {
            const s = try str.newSymbol(vm, f.fp.constants[u32At(pc + 1)].asString());
            s.is_private = true;
            sp[0] = Value.fromSymbol(s);
            vm.sp = sp + 1;
            f.pc = pc + 5;
        },
        .new_object => {
            sp[0] = (try objmod.newPlain(vm)).value();
            vm.sp = sp + 1;
            f.pc = pc + 1;
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
        .array_spread => {
            try iter.appendAll(vm, (sp - 2)[0].asObject(), (sp - 1)[0]);
            vm.sp = sp - 1;
            f.pc = pc + 1;
        },
        .object_spread => {
            try copyDataProps(vm, (sp - 2)[0].asObject(), (sp - 1)[0], &.{});
            vm.sp = sp - 1;
            f.pc = pc + 1;
        },
        .object_rest => {
            const n = u16At(pc + 1);
            const rest = try objmod.newPlain(vm);
            try copyDataProps(vm, rest, (sp - n - 1)[0], (sp - n)[0..n]);
            (sp - n - 1)[0] = rest.value();
            vm.sp = sp - n;
            f.pc = pc + 3;
        },
        .closure => {
            sp[0] = (try makeClosure(vm, f.fp.protos[u32At(pc + 1)], f.env)).value();
            vm.sp = sp + 1;
            f.pc = pc + 5;
        },
        .new_regexp => {
            const pattern = f.fp.constants[u32At(pc + 1)].asString();
            const flags = f.fp.constants[u32At(pc + 5)].asString();
            sp[0] = try regexp.create(vm, pattern, flags, vm.protos.regexp);
            vm.sp = sp + 1;
            f.pc = pc + 9;
        },
        .make_class => {
            const has_parent = pc[5] != 0;
            const parent = if (has_parent) (sp - 1)[0] else Value.undefined;
            const r = try makeClass(vm, f, f.fp.protos[u32At(pc + 1)], has_parent, parent);
            const at = if (has_parent) sp - 1 else sp;
            at[0] = r.ctor.value();
            at[1] = r.proto.value();
            vm.sp = at + 2;
            f.pc = pc + 6;
        },
        .set_fields => {
            const fnv = (sp - 1)[0];
            try setHome(vm, fnv, (sp - 2)[0].asObject());
            (sp - 3)[0].asObject().extra().?.fields = fnv;
            vm.sp = sp - 1;
            f.pc = pc + 1;
        },
        .run_static => {
            const fnv = (sp - 1)[0];
            const ctor = (sp - 3)[0];
            try setHome(vm, fnv, ctor.asObject());
            f.pc = pc + 1;
            _ = try calls.call(vm, fnv, ctor, &.{});
            vm.sp = sp - 1;
        },
        .run_fields => {
            const this = (sp - 2)[0];
            const func = (sp - 1)[0];
            f.pc = pc + 1;
            try runFields(vm, this, func);
            vm.sp = sp - 2;
        },
        .get_super_ctor => {
            const func = (sp - 1)[0].asObject();
            const parent = try props.getProto(vm, func);
            const pv = if (parent) |p| p.value() else Value.null;
            if (!pv.isConstructor()) return vm.throwError(.TypeError, "Super constructor is not a constructor");
            (sp - 1)[0] = pv;
            f.pc = pc + 1;
        },
        .super_call => {
            const n = u16At(pc + 1);
            const args = (sp - n)[0..n];
            f.pc = pc + 3;
            const r = try calls.construct(vm, (sp - n - 1)[0], args, (sp - n - 2)[0]);
            (sp - n - 2)[0] = r;
            vm.sp = sp - n - 1;
        },
        .super_apply => {
            const arr = (sp - 1)[0].asObject();
            f.pc = pc + 1;
            const r = try calls.construct(vm, (sp - 2)[0], arr.elems[0..arr.elems_len], (sp - 3)[0]);
            (sp - 3)[0] = r;
            vm.sp = sp - 2;
        },
        .super_forward => {
            const func = f.func;
            const parent = try props.getProto(vm, func);
            const pv = if (parent) |p| p.value() else Value.null;
            if (!pv.isConstructor()) return vm.throwError(.TypeError, "Super constructor is not a constructor");
            f.pc = pc + 1;
            const r = try calls.construct(vm, pv, f.args[0..f.argc], f.new_target);
            try runFields(vm, r, func.value());
            sp[0] = r;
            vm.sp = sp + 1;
        },
        .check_super_once => {
            if (!(sp - 1)[0].isHole()) return vm.throwError(.ReferenceError, "Super constructor may only be called once");
            vm.sp = sp - 1;
            f.pc = pc + 1;
        },
        else => {
            var b: [64]u8 = undefined;
            const m = std.fmt.bufPrint(&b, "Internal: bad opcode {s}", .{@tagName(op)}) catch "Internal: bad opcode";
            return vm.throwError(.SyntaxError, m);
        },
    }
}
