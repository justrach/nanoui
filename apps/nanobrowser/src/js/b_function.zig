//! Function: call, apply, bind, toString (the source text), new Function and the
//! hidden GeneratorFunction and AsyncFunction constructors, plus global eval.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const u = @import("b_util.zig");
const Value = u.Value;
const PropKey = u.PropKey;
const Object = u.Object;
const PropFlags = u.PropFlags;
const objmod = @import("object.zig");
const props = @import("props.zig");
const conv = @import("conv.zig");
const ops = @import("ops.zig");
const str = @import("string.zig");
const calls = @import("interp_call.zig");
const api = @import("vm_api.zig");

/// Copies an array-like's elements for call-style use. The caller frees with vm.gpa.
pub fn listFromArrayLike(vm: *Vm, v: Value) Error![]Value {
    if (v.isNullish()) return vm.gpa.alloc(Value, 0);
    if (!v.isObject()) return vm.throwError(.TypeError, "CreateListFromArrayLike called on non-object");
    const o = v.asObject();
    if (o.class == .host_exotic) {
        if (o.payload.hooks.length_index) |li| if (o.payload.hooks.get_index) |gi| {
            const n = try li(vm, o);
            const out = try vm.gpa.alloc(Value, n);
            errdefer vm.gpa.free(out);
            for (out, 0..) |*slot, i| slot.* = (try gi(vm, o, @intCast(i))) orelse try props.get(vm, o, PropKey.fromIndex(@intCast(i)));
            return out;
        };
    }
    const n = try conv.lengthOf(vm, o);
    if (n > 1 << 24) return vm.throwError(.RangeError, "Too many arguments");
    const out = try vm.gpa.alloc(Value, n);
    errdefer vm.gpa.free(out);
    for (out, 0..) |*slot, i| slot.* = try props.get(vm, o, PropKey.fromIndex(@intCast(i)));
    return out;
}

pub fn fnCall(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const rest = if (args.len > 1) args[1..] else args[0..0];
    return calls.call(vm, this, u.arg(args, 0), rest);
}

pub fn fnApply(vm: *Vm, this: Value, args: []const Value) Error!Value {
    if (!this.isCallable()) return vm.throwError(.TypeError, "Function.prototype.apply was called on a non-function");
    const this_arg = u.arg(args, 0);
    const arr_val = u.arg(args, 1);
    if (arr_val.isNullish()) return calls.call(vm, this, this_arg, &.{});
    if (!arr_val.isObject()) return vm.throwError(.TypeError, "CreateListFromArrayLike called on non-object");
    const o = arr_val.asObject();
    var stack_buf: [32]Value = undefined;
    const is_fast_args = o.class == .arguments and (o.shape == vm.args_strict_shape or o.shape == vm.args_sloppy_shape) and o.slots[0].bits == Value.fromUsize(o.elems_len).bits;
    if (!o.flags.exotic and !o.flags.has_sparse and ((o.class == .array and o.elems_len == o.arr_len) or is_fast_args) and o.elems_len <= stack_buf.len) {
        const len = o.elems_len;
        var has_hole = false;
        for (o.elems[0..len]) |el| {
            if (el.isHole()) {
                has_hole = true;
                break;
            }
        }
        if (!has_hole) {
            @memcpy(stack_buf[0..len], o.elems[0..len]);
            return calls.call(vm, this, this_arg, stack_buf[0..len]);
        }
    }
    const n = try conv.lengthOf(vm, o);
    if (n <= stack_buf.len) {
        for (0..n) |i| {
            if (i < o.elems_len and !o.flags.exotic) {
                const el = o.elems[i];
                if (!el.isHole()) {
                    stack_buf[i] = el;
                    continue;
                }
            }
            stack_buf[i] = try props.get(vm, o, PropKey.fromIndex(@intCast(i)));
        }
        return calls.call(vm, this, this_arg, stack_buf[0..n]);
    }
    const list = try listFromArrayLike(vm, arr_val);
    defer vm.gpa.free(list);
    return calls.call(vm, this, this_arg, list);
}

fn fnBind(vm: *Vm, this: Value, args: []const Value) Error!Value {
    if (!this.isCallable()) return vm.throwError(.TypeError, "Bind must be called on a function");
    const target = this.asObject();
    const bound_args: []Value = if (args.len > 1) try vm.gpa.dupe(Value, args[1..]) else &.{};
    errdefer if (bound_args.len > 0) vm.gpa.free(bound_args);
    const data = try vm.gpa.create(objmod.BoundData);
    errdefer vm.gpa.destroy(data);
    data.* = .{ .target = target, .this = u.arg(args, 0), .args = bound_args };
    if (target.flags.lazy_fn and target.shape == vm.fn_root) {
        const o = try objmod.alloc(vm, vm.fn_root, .bound);
        o.payload = .{ .bound = data };
        o.flags.callable = true;
        o.flags.constructor = target.flags.constructor;
        o.flags.lazy_fn = true;
        return o.value();
    }
    const proto = try props.getProto(vm, target);
    const o = try objmod.create(vm, proto, .bound);
    o.payload = .{ .bound = data };
    o.flags.callable = true;
    o.flags.constructor = target.flags.constructor;
    var len: f64 = 0;
    if (try props.hasOwn(vm, target, vm.k.length)) {
        const l = try props.get(vm, target, vm.k.length);
        if (l.isNumber()) {
            const t = try conv.toIntegerOrInf(vm, l);
            len = @max(0, t - @as(f64, @floatFromInt(bound_args.len)));
        }
    }
    try props.addProp(vm, o, vm.k.length, Value.fromNumber(len), PropFlags.config_only);
    const nv = try props.get(vm, target, vm.k.name);
    const prefix = try str.fromUtf8(vm, "bound ");
    const nm = try str.concat(vm, prefix, if (nv.isString()) nv.asString() else vm.empty);
    try props.addProp(vm, o, vm.k.name, Value.fromString(nm), PropFlags.config_only);
    return o.value();
}

fn fnToString(vm: *Vm, this: Value, _: []const Value) Error!Value {
    if (!this.isCallable()) return vm.throwError(.TypeError, "Function.prototype.toString requires that 'this' be a Function");
    const o = this.asObject();
    if (o.class == .closure) {
        const fp = o.payload.fp;
        const text = fp.source.text;
        if (fp.src_end <= text.len and fp.src_end > fp.src_start) return api.newString(vm, text[fp.src_start..fp.src_end]);
    }
    var b = str.Builder.init(vm);
    defer b.deinit();
    try b.bytes("function ");
    if (o.class == .native) try b.str(o.payload.native.name);
    try b.bytes("() { [native code] }");
    return Value.fromString(try b.finish());
}

fn fnHasInstance(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return Value.fromBool(try ops.ordinaryHasInstance(vm, this, u.arg(args, 0)));
}

fn fnProtoCall(_: *Vm, _: Value, _: []const Value) Error!Value {
    return Value.undefined;
}

/// Builds and compiles source of the form new Function gets.
fn dynamicFunction(vm: *Vm, prefix: []const u8, args: []const Value) Error!Value {
    var b = str.Builder.init(vm);
    defer b.deinit();
    try b.byte('(');
    try b.bytes(prefix);
    try b.bytes(" anonymous(");
    if (args.len > 1) {
        for (args[0 .. args.len - 1], 0..) |p, i| {
            if (i != 0) try b.byte(',');
            try b.str(try conv.toStr(vm, p));
        }
    }
    try b.bytes("\n) {\n");
    if (args.len > 0) try b.str(try conv.toStr(vm, args[args.len - 1]));
    try b.bytes("\n})");
    const f = try api.compileScript(vm, b.buf.items, "<anonymous>", .eval);
    return calls.call(vm, f.value(), vm.global_obj.value(), &.{});
}

fn functionCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return dynamicFunction(vm, "function", args);
}
fn generatorFunctionCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return dynamicFunction(vm, "function*", args);
}
fn asyncFunctionCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return dynamicFunction(vm, "async function", args);
}
fn asyncGeneratorFunctionCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return dynamicFunction(vm, "async function*", args);
}

/// Indirect eval semantics: runs in the global scope. Direct eval is the same (documented in js.zig).
fn globalEval(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const x = u.arg(args, 0);
    if (!x.isString()) return x;
    const f = try api.compileScript(vm, try x.asString().flat(vm), "<eval>", .eval);
    return calls.call(vm, f.value(), vm.global_obj.value(), &.{});
}

fn hiddenCtor(vm: *Vm, name: []const u8, f: objmod.NativeFn, proto: *Object) Error!void {
    const c = try api.newNative(vm, name, 1, f);
    c.flags.constructor = true;
    try props.materialize(vm, c);
    try props.addProp(vm, c, vm.k.prototype, proto.value(), PropFlags.readonly);
    try props.defineData(vm, proto, vm.k.constructor, c.value(), PropFlags.config_only);
}

pub fn init(vm: *Vm) Error!void {
    const proto = vm.protos.function;
    try u.method(vm, proto, "call", 1, fnCall);
    try u.method(vm, proto, "apply", 2, fnApply);
    try u.method(vm, proto, "bind", 1, fnBind);
    try u.method(vm, proto, "toString", 0, fnToString);
    const hi = try api.newNative(vm, "[Symbol.hasInstance]", 1, fnHasInstance);
    vm.function_has_instance = hi;
    try props.defineData(vm, proto, PropKey.fromSymbol(vm.sym.hasInstance), hi.value(), PropFlags.readonly);
    _ = try u.ctor(vm, "Function", 1, functionCtor, proto);
    try hiddenCtor(vm, "GeneratorFunction", generatorFunctionCtor, vm.protos.generator_function);
    try hiddenCtor(vm, "AsyncFunction", asyncFunctionCtor, vm.protos.async_function);
    try hiddenCtor(vm, "AsyncGeneratorFunction", asyncGeneratorFunctionCtor, vm.protos.async_generator_function);
    try u.method(vm, vm.global_obj, "eval", 1, globalEval);
}

/// The native behind Function.prototype itself, which is callable and returns undefined.
pub const protoFunction = fnProtoCall;
