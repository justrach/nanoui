//! Error and its subclasses: message, cause, and a stack string captured from the
//! frames at construction, in the "at fn (file:line:col)" form consoles expect.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const ErrorKind = vm_mod.ErrorKind;
const u = @import("b_util.zig");
const Value = u.Value;
const PropKey = u.PropKey;
const Object = u.Object;
const PropFlags = u.PropFlags;
const objmod = @import("object.zig");
const props = @import("props.zig");
const conv = @import("conv.zig");
const str = @import("string.zig");
const calls = @import("interp_call.zig");
const iter = @import("iter.zig");

const stack_limit = 16;

fn appendTrace(vm: *Vm, b: *str.Builder) Error!void {
    var i: u32 = vm.frame_top;
    var shown: u32 = 0;
    while (i > 0 and shown < stack_limit) : (shown += 1) {
        i -= 1;
        const f = &vm.frames[i];
        const fp = f.fp;
        var off: u32 = @intCast(@intFromPtr(f.pc) - @intFromPtr(fp.code.ptr));
        if (i + 1 != vm.frame_top and off > 0) off -= 1;
        const pos = fp.posOf(off);
        const lc = try fp.source.lineCol(vm.gpa, pos);
        try b.bytes("\n    at ");
        const name = try fp.name.flat(vm);
        if (name.len != 0) {
            try b.bytes(name);
            try b.bytes(" (");
        }
        try b.bytes(fp.source.name);
        try b.print(":{d}:{d}", .{ lc.line, lc.col });
        if (name.len != 0) try b.byte(')');
    }
}

fn makeStack(vm: *Vm, header: []const u8) Error!Value {
    var b = str.Builder.init(vm);
    defer b.deinit();
    try b.bytes(header);
    try appendTrace(vm, &b);
    return Value.fromString(try b.finish());
}

const kind_names = [_][]const u8{ "Error", "TypeError", "RangeError", "SyntaxError", "ReferenceError", "EvalError", "URIError", "AggregateError" };

/// A new error object, as the engine itself raises them.
pub fn create(vm: *Vm, kind: ErrorKind, msg: []const u8) Error!Value {
    const o = try objmod.create(vm, vm.protos.errors[@backingInt(kind)], .@"error");
    const m = try str.fromUtf8(vm, msg);
    try props.addProp(vm, o, vm.k.message, Value.fromString(m), PropFlags.hidden);
    var b = str.Builder.init(vm);
    defer b.deinit();
    try b.bytes(kind_names[@backingInt(kind)]);
    if (msg.len != 0) {
        try b.bytes(": ");
        try b.bytes(msg);
    }
    try appendTrace(vm, &b);
    try props.addProp(vm, o, vm.k.stack, Value.fromString(try b.finish()), PropFlags.hidden);
    return o.value();
}

/// "Name: message" as Error.prototype.toString makes it.
fn errorHeader(vm: *Vm, o: *Object) Error!*str.JSString {
    const nv = try props.get(vm, o, vm.k.name);
    const name = if (nv.isUndefined()) try str.fromUtf8(vm, "Error") else try conv.toStr(vm, nv);
    const mv = try props.get(vm, o, vm.k.message);
    const msg = if (mv.isUndefined()) vm.empty else try conv.toStr(vm, mv);
    if (msg.byte_len == 0) return name;
    if (name.byte_len == 0) return msg;
    const sep = try str.fromUtf8(vm, ": ");
    return str.concat(vm, try str.concat(vm, name, sep), msg);
}

fn construct(vm: *Vm, kind: ErrorKind, msg: Value, options: Value) Error!Value {
    const proto = try calls.protoFromNewTarget(vm, vm.protos.errors[@backingInt(kind)]);
    const o = try objmod.create(vm, proto, .@"error");
    if (!msg.isUndefined()) {
        const m = try conv.toStr(vm, msg);
        try props.addProp(vm, o, vm.k.message, Value.fromString(m), PropFlags.hidden);
    }
    if (options.isObject() and try props.has(vm, options.asObject(), vm.k.cause)) {
        const c = try props.get(vm, options.asObject(), vm.k.cause);
        try props.addProp(vm, o, vm.k.cause, c, PropFlags.hidden);
    }
    const header = try errorHeader(vm, o);
    try props.addProp(vm, o, vm.k.stack, try makeStack(vm, try header.flat(vm)), PropFlags.hidden);
    return o.value();
}

fn ctorFor(comptime kind: ErrorKind) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, _: Value, args: []const Value) Error!Value {
            return construct(vm, kind, u.arg(args, 0), u.arg(args, 1));
        }
    }.f;
}

fn aggregateCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const e = try construct(vm, .AggregateError, u.arg(args, 1), u.arg(args, 2));
    const list = try objmod.newArray(vm, &.{});
    try iter.appendAll(vm, list, u.arg(args, 0));
    try props.addProp(vm, e.asObject(), vm.k.errors, list.value(), PropFlags.hidden);
    return e;
}

fn toStringFn(vm: *Vm, this: Value, _: []const Value) Error!Value {
    if (!this.isObject()) return vm.throwError(.TypeError, "Error.prototype.toString requires an object");
    return Value.fromString(try errorHeader(vm, this.asObject()));
}

/// V8's Error.captureStackTrace, which libraries call unconditionally when it exists.
fn captureStackTrace(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const t = u.arg(args, 0);
    if (!t.isObject()) return vm.throwError(.TypeError, "Invalid target for captureStackTrace");
    const header = errorHeader(vm, t.asObject()) catch vm.empty;
    try props.defineData(vm, t.asObject(), vm.k.stack, try makeStack(vm, try header.flat(vm)), PropFlags.hidden);
    return Value.undefined;
}

fn installKind(vm: *Vm, comptime kind: ErrorKind, parent_proto: *Object, parent_ctor: ?*Object) Error!*Object {
    const i = @backingInt(kind);
    const proto = try u.newProto(vm, parent_proto);
    vm.protos.errors[i] = proto;
    const arity: u32 = if (kind == .AggregateError) 2 else 1;
    const f = if (kind == .AggregateError) aggregateCtor else ctorFor(kind);
    const c = try u.ctor(vm, kind_names[i], arity, f, proto);
    if (parent_ctor) |pc| try props.setProtoRaw(vm, c, pc);
    try props.defineData(vm, proto, vm.k.name, Value.fromString(try str.intern(vm, kind_names[i])), PropFlags.hidden);
    try props.defineData(vm, proto, vm.k.message, Value.fromString(vm.empty), PropFlags.hidden);
    return c;
}

pub fn init(vm: *Vm) Error!void {
    const base = try installKind(vm, .Error, vm.protos.object, null);
    const proto = vm.protos.errors[0];
    try u.method(vm, proto, "toString", 0, toStringFn);
    try u.method(vm, base, "captureStackTrace", 2, captureStackTrace);
    try u.data(vm, base, "stackTraceLimit", Value.fromInt(stack_limit));
    _ = try installKind(vm, .TypeError, proto, base);
    _ = try installKind(vm, .RangeError, proto, base);
    _ = try installKind(vm, .SyntaxError, proto, base);
    _ = try installKind(vm, .ReferenceError, proto, base);
    _ = try installKind(vm, .EvalError, proto, base);
    _ = try installKind(vm, .URIError, proto, base);
    _ = try installKind(vm, .AggregateError, proto, base);
}
