//! ArrayBuffer, the typed array element access and constructors, and DataView.
//! Prototype methods of %TypedArray% are in b_typed_methods.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const u = @import("b_util.zig");
const Value = u.Value;
const PropKey = u.PropKey;
const Object = u.Object;
const objmod = @import("object.zig");
const props = @import("props.zig");
const conv = @import("conv.zig");
const str = @import("string.zig");
const calls = @import("interp_call.zig");
const iter = @import("iter.zig");
const big = @import("b_bigint.zig");
const methods = @import("b_typed_methods.zig");

pub const Kind = enum(u8) { Int8, Uint8, Uint8Clamped, Int16, Uint16, Int32, Uint32, Float32, Float64, BigInt64, BigUint64 };

pub const kind_names = [_][]const u8{ "Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array", "Int32Array", "Uint32Array", "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array" };

pub fn elemSize(k: Kind) usize {
    return switch (k) {
        .Int8, .Uint8, .Uint8Clamped => 1,
        .Int16, .Uint16 => 2,
        .Int32, .Uint32, .Float32 => 4,
        .Float64, .BigInt64, .BigUint64 => 8,
    };
}

pub const BufferData = struct {
    bytes: []u8,
    detached: bool = false,

    pub fn destroy(b: *BufferData, gpa: Allocator) void {
        gpa.free(b.bytes);
        gpa.destroy(b);
    }
};

/// Shared by typed arrays and DataViews.
pub const TypedData = struct {
    buffer: *Object,
    offset: usize,
    /// Elements for a typed array, bytes for a DataView.
    len: usize,
    kind: Kind,
};

pub fn newBuffer(vm: *Vm, n: usize, proto: *Object) Error!*Object {
    if (n > 1 << 32) return vm.throwError(.RangeError, "Array buffer allocation failed");
    const bytes = try vm.gpa.alloc(u8, n);
    errdefer vm.gpa.free(bytes);
    @memset(bytes, 0);
    const d = try vm.gpa.create(BufferData);
    errdefer vm.gpa.destroy(d);
    d.* = .{ .bytes = bytes };
    const o = try objmod.create(vm, proto, .arraybuffer);
    o.payload = .{ .buffer = d };
    return o;
}

fn newView(vm: *Vm, proto: *Object, class: objmod.Class, buffer: *Object, offset: usize, len: usize, kind: Kind) Error!*Object {
    const d = try vm.gpa.create(TypedData);
    d.* = .{ .buffer = buffer, .offset = offset, .len = len, .kind = kind };
    const made = if (class == .typedarray) objmod.createExotic(vm, proto, class) else objmod.create(vm, proto, class);
    const o = made catch |e| {
        vm.gpa.destroy(d);
        return e;
    };
    o.payload = .{ .typed = d };
    return o;
}

pub fn newTyped(vm: *Vm, kind: Kind, n: usize) Error!*Object {
    const b = try newBuffer(vm, n * elemSize(kind), vm.protos.arraybuffer);
    return newView(vm, vm.protos.typed[@backingInt(kind)], .typedarray, b, 0, n, kind);
}

/// The element count; zero when the buffer is detached.
pub fn length(o: *Object) usize {
    const d = o.payload.typed;
    if (d.buffer.payload.buffer.detached) return 0;
    return d.len;
}

pub fn isValidIndex(o: *Object, i: u32) bool {
    return i < length(o);
}

pub inline fn bytesOf(o: *Object) []u8 {
    const d = o.payload.typed;
    return d.buffer.payload.buffer.bytes[d.offset..];
}

fn readNum(comptime T: type, b: []const u8) T {
    return std.mem.bytesToValue(T, b[0..@sizeOf(T)]);
}

/// Reads element i, which must be in range; reading past the end yields undefined.
pub fn getIndex(vm: *Vm, o: *Object, i: u32) Error!Value {
    if (i >= length(o)) return Value.undefined;
    const d = o.payload.typed;
    const b = bytesOf(o)[i * elemSize(d.kind) ..];
    return switch (d.kind) {
        .Int8 => Value.fromInt(readNum(i8, b)),
        .Uint8, .Uint8Clamped => Value.fromInt(b[0]),
        .Int16 => Value.fromInt(readNum(i16, b)),
        .Uint16 => Value.fromInt(readNum(u16, b)),
        .Int32 => Value.fromInt(readNum(i32, b)),
        .Uint32 => Value.fromUsize(readNum(u32, b)),
        .Float32 => Value.fromNumber(readNum(f32, b)),
        .Float64 => Value.fromNumber(readNum(f64, b)),
        .BigInt64 => big.fromU64(vm, readNum(u64, b), true),
        .BigUint64 => big.fromU64(vm, readNum(u64, b), false),
    };
}

fn clamp8(d: f64) u8 {
    if (!(d > 0)) return 0;
    if (d >= 255) return 255;
    const f = std.math.floor(d);
    const diff = d - f;
    var r: u32 = @intFromFloat(f);
    if (diff > 0.5 or (diff == 0.5 and r & 1 == 1)) r += 1;
    return @intCast(r);
}

fn writeNum(comptime T: type, b: []u8, v: T) void {
    @memcpy(b[0..@sizeOf(T)], std.mem.asBytes(&v));
}

/// Converts then writes; an out-of-range index still runs the conversion, per spec.
pub fn setIndex(vm: *Vm, o: *Object, i: u32, v: Value) Error!void {
    const d = o.payload.typed;
    if (d.kind == .BigInt64 or d.kind == .BigUint64) {
        const x = try big.toU64(vm, try big.toBigInt(vm, v));
        if (i < length(o)) writeNum(u64, bytesOf(o)[i * 8 ..], x);
        return;
    }
    const n = try conv.toNumber(vm, v);
    if (i >= length(o)) return;
    const b = bytesOf(o)[i * elemSize(d.kind) ..];
    switch (d.kind) {
        .Int8 => b[0] = @truncate(@as(u32, @bitCast(conv.doubleToInt32(n)))),
        .Uint8 => b[0] = @truncate(@as(u32, @bitCast(conv.doubleToInt32(n)))),
        .Uint8Clamped => b[0] = clamp8(n),
        .Int16, .Uint16 => writeNum(u16, b, @truncate(@as(u32, @bitCast(conv.doubleToInt32(n))))),
        .Int32, .Uint32 => writeNum(u32, b, @bitCast(conv.doubleToInt32(n))),
        .Float32 => writeNum(f32, b, @floatCast(n)),
        .Float64 => writeNum(f64, b, n),
        else => unreachable,
    }
}

fn arrayBufferCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    if (vm.new_target.isUndefined()) return vm.throwError(.TypeError, "Constructor ArrayBuffer requires 'new'");
    const n = try conv.toIndex(vm, u.arg(args, 0));
    return (try newBuffer(vm, n, try calls.protoFromNewTarget(vm, vm.protos.arraybuffer))).value();
}

fn thisBuffer(vm: *Vm, this: Value) Error!*BufferData {
    if (this.isObject() and this.asObject().class == .arraybuffer) return this.asObject().payload.buffer;
    return vm.throwError(.TypeError, "not an ArrayBuffer");
}

fn bufferByteLength(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const b = try thisBuffer(vm, this);
    return Value.fromUsize(if (b.detached) 0 else b.bytes.len);
}

fn bufferSlice(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const b = try thisBuffer(vm, this);
    const start = try u.relativeIndex(vm, u.arg(args, 0), b.bytes.len, 0);
    const end = try u.relativeIndex(vm, u.arg(args, 1), b.bytes.len, b.bytes.len);
    const n = if (end > start) end - start else 0;
    const out = try newBuffer(vm, n, vm.protos.arraybuffer);
    @memcpy(out.payload.buffer.bytes[0..n], b.bytes[start..][0..n]);
    return out.value();
}

fn isView(_: *Vm, _: Value, args: []const Value) Error!Value {
    const v = u.arg(args, 0);
    return Value.fromBool(v.isObject() and (v.asObject().class == .typedarray or v.asObject().class == .dataview));
}

/// Fills a fresh typed array from any list of values.
fn fromValues(vm: *Vm, kind: Kind, proto: *Object, values: []const Value) Error!*Object {
    const b = try newBuffer(vm, values.len * elemSize(kind), vm.protos.arraybuffer);
    const o = try newView(vm, proto, .typedarray, b, 0, values.len, kind);
    for (values, 0..) |v, i| try setIndex(vm, o, @intCast(i), v);
    return o;
}

fn constructTyped(vm: *Vm, kind: Kind, args: []const Value) Error!Value {
    if (vm.new_target.isUndefined()) return vm.throwError(.TypeError, "Constructor TypedArray requires 'new'");
    const proto = try calls.protoFromNewTarget(vm, vm.protos.typed[@backingInt(kind)]);
    const a0 = u.arg(args, 0);
    const size = elemSize(kind);
    if (!a0.isObject()) {
        const n = try conv.toIndex(vm, a0);
        const b = try newBuffer(vm, n * size, vm.protos.arraybuffer);
        return (try newView(vm, proto, .typedarray, b, 0, n, kind)).value();
    }
    const src = a0.asObject();
    if (src.class == .arraybuffer) {
        const offset = try conv.toIndex(vm, u.arg(args, 1));
        if (offset % size != 0) return vm.throwError(.RangeError, "start offset must be a multiple of the element size");
        const blen = src.payload.buffer.bytes.len;
        var n: usize = undefined;
        if (u.arg(args, 2).isUndefined()) {
            if (blen % size != 0) return vm.throwError(.RangeError, "buffer length must be a multiple of the element size");
            if (offset > blen) return vm.throwError(.RangeError, "Start offset is outside the bounds of the buffer");
            n = (blen - offset) / size;
        } else {
            n = try conv.toIndex(vm, args[2]);
            if (offset + n * size > blen) return vm.throwError(.RangeError, "Invalid typed array length");
        }
        return (try newView(vm, proto, .typedarray, src, offset, n, kind)).value();
    }
    // Another typed array, an iterable, or an array-like.
    var list: std.ArrayList(Value) = .empty;
    defer list.deinit(vm.gpa);
    const Ctx = struct {
        vm: *Vm,
        list: *std.ArrayList(Value),
        fn add(c: @This(), v: Value) Error!void {
            try c.list.append(c.vm.gpa, v);
        }
    };
    const m = try props.get(vm, src, PropKey.fromSymbol(vm.sym.iterator));
    if (m.isNullish()) {
        const n = try conv.lengthOf(vm, src);
        var i: usize = 0;
        while (i < n) : (i += 1) try list.append(vm.gpa, try props.get(vm, src, PropKey.fromIndex(@intCast(i))));
    } else {
        try iter.forEach(vm, a0, Ctx{ .vm = vm, .list = &list }, Ctx.add);
    }
    return (try fromValues(vm, kind, proto, list.items)).value();
}

fn ctorFor(comptime kind: Kind) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, _: Value, args: []const Value) Error!Value {
            return constructTyped(vm, kind, args);
        }
    }.f;
}

fn abstractCtor(vm: *Vm, _: Value, _: []const Value) Error!Value {
    return vm.throwError(.TypeError, "Abstract class TypedArray not directly constructable");
}

fn dataViewCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    if (vm.new_target.isUndefined()) return vm.throwError(.TypeError, "Constructor DataView requires 'new'");
    const b = u.arg(args, 0);
    if (!b.isObject() or b.asObject().class != .arraybuffer) return vm.throwError(.TypeError, "First argument to DataView constructor must be an ArrayBuffer");
    const offset = try conv.toIndex(vm, u.arg(args, 1));
    const blen = b.asObject().payload.buffer.bytes.len;
    if (offset > blen) return vm.throwError(.RangeError, "Start offset is outside the bounds of the buffer");
    const len = if (u.arg(args, 2).isUndefined()) blen - offset else try conv.toIndex(vm, args[2]);
    if (offset + len > blen) return vm.throwError(.RangeError, "Invalid DataView length");
    return (try newView(vm, try calls.protoFromNewTarget(vm, vm.protos.dataview), .dataview, b.asObject(), offset, len, .Uint8)).value();
}

fn thisView(vm: *Vm, this: Value) Error!*TypedData {
    if (this.isObject() and this.asObject().class == .dataview) return this.asObject().payload.typed;
    return vm.throwError(.TypeError, "not a DataView");
}

fn viewAccess(vm: *Vm, this: Value, args: []const Value, size: usize) Error![]u8 {
    const d = try thisView(vm, this);
    const i = try conv.toIndex(vm, u.arg(args, 0));
    if (i + size > d.len) return vm.throwError(.RangeError, "Offset is outside the bounds of the DataView");
    return d.buffer.payload.buffer.bytes[d.offset + i ..][0..size];
}

fn viewGet(comptime T: type) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, args: []const Value) Error!Value {
            const b = try viewAccess(vm, this, args, @sizeOf(T));
            var tmp: [@sizeOf(T)]u8 = undefined;
            @memcpy(&tmp, b);
            const little = @import("ops.zig").truthy(u.arg(args, 1));
            if (!little) std.mem.reverse(u8, &tmp);
            const v = std.mem.bytesToValue(T, &tmp);
            if (T == i64) return big.fromU64(vm, @bitCast(v), true);
            if (T == u64) return big.fromU64(vm, @bitCast(v), false);
            if (@typeInfo(T) == .float) return Value.fromNumber(@floatCast(v));
            return Value.fromNumber(@floatFromInt(v));
        }
    }.f;
}

fn viewSet(comptime T: type) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, args: []const Value) Error!Value {
            _ = try thisView(vm, this);
            var v: T = undefined;
            if (T == i64 or T == u64) {
                v = @bitCast(try big.toU64(vm, try big.toBigInt(vm, u.arg(args, 1))));
            } else if (@typeInfo(T) == .float) {
                v = @floatCast(try conv.toNumber(vm, u.arg(args, 1)));
            } else {
                const x = conv.doubleToInt32(try conv.toNumber(vm, u.arg(args, 1)));
                const bits = @as(u32, @bitCast(x));
                const U = switch (@sizeOf(T)) {
                    1 => u8,
                    2 => u16,
                    else => u32,
                };
                v = @bitCast(@as(U, @truncate(bits)));
            }
            const b = try viewAccess(vm, this, args, @sizeOf(T));
            var tmp: [@sizeOf(T)]u8 = std.mem.toBytes(v);
            if (!@import("ops.zig").truthy(u.arg(args, 2))) std.mem.reverse(u8, &tmp);
            @memcpy(b, &tmp);
            return Value.undefined;
        }
    }.f;
}

fn viewBuffer(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return (try thisView(vm, this)).buffer.value();
}
fn viewByteLength(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return Value.fromUsize((try thisView(vm, this)).len);
}
fn viewByteOffset(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return Value.fromUsize((try thisView(vm, this)).offset);
}

pub fn init(vm: *Vm) Error!void {
    const p = &vm.protos;
    p.arraybuffer = try u.newProto(vm, p.object);
    const ab = try u.ctor(vm, "ArrayBuffer", 1, arrayBufferCtor, p.arraybuffer);
    p.arraybuffer_ctor = ab;
    try u.method(vm, ab, "isView", 1, isView);
    try u.toStringTag(vm, p.arraybuffer, "ArrayBuffer");
    try u.getter(vm, p.arraybuffer, "byteLength", bufferByteLength);
    try u.method(vm, p.arraybuffer, "slice", 2, bufferSlice);

    p.typed_array = try u.newProto(vm, p.object);
    const base = try @import("vm_api.zig").newNative(vm, "TypedArray", 0, abstractCtor);
    base.flags.constructor = true;
    try props.materialize(vm, base);
    try props.addProp(vm, base, vm.k.prototype, p.typed_array.value(), u.PropFlags.readonly);
    try u.data(vm, p.typed_array, "constructor", base.value());
    try methods.init(vm, base);

    inline for (@typeInfo(Kind).@"enum".field_names, 0..) |name, i| {
        const kind = @field(Kind, name);
        const proto = try u.newProto(vm, p.typed_array);
        p.typed[i] = proto;
        const c = try u.ctor(vm, kind_names[i], 3, ctorFor(kind), proto);
        p.typed_ctor[i] = c;
        try props.setProtoRaw(vm, c, base);
        const size = Value.fromUsize(elemSize(kind));
        try u.constant(vm, c, "BYTES_PER_ELEMENT", size);
        try u.constant(vm, proto, "BYTES_PER_ELEMENT", size);
    }

    p.dataview = try u.newProto(vm, p.object);
    _ = try u.ctor(vm, "DataView", 1, dataViewCtor, p.dataview);
    try u.toStringTag(vm, p.dataview, "DataView");
    const dv = p.dataview;
    try u.getter(vm, dv, "buffer", viewBuffer);
    try u.getter(vm, dv, "byteLength", viewByteLength);
    try u.getter(vm, dv, "byteOffset", viewByteOffset);
    try u.method(vm, dv, "getInt8", 1, viewGet(i8));
    try u.method(vm, dv, "getUint8", 1, viewGet(u8));
    try u.method(vm, dv, "getInt16", 1, viewGet(i16));
    try u.method(vm, dv, "getUint16", 1, viewGet(u16));
    try u.method(vm, dv, "getInt32", 1, viewGet(i32));
    try u.method(vm, dv, "getUint32", 1, viewGet(u32));
    try u.method(vm, dv, "getFloat32", 1, viewGet(f32));
    try u.method(vm, dv, "getFloat64", 1, viewGet(f64));
    try u.method(vm, dv, "getBigInt64", 1, viewGet(i64));
    try u.method(vm, dv, "getBigUint64", 1, viewGet(u64));
    try u.method(vm, dv, "setInt8", 2, viewSet(i8));
    try u.method(vm, dv, "setUint8", 2, viewSet(u8));
    try u.method(vm, dv, "setInt16", 2, viewSet(i16));
    try u.method(vm, dv, "setUint16", 2, viewSet(u16));
    try u.method(vm, dv, "setInt32", 2, viewSet(i32));
    try u.method(vm, dv, "setUint32", 2, viewSet(u32));
    try u.method(vm, dv, "setFloat32", 2, viewSet(f32));
    try u.method(vm, dv, "setFloat64", 2, viewSet(f64));
    try u.method(vm, dv, "setBigInt64", 2, viewSet(i64));
    try u.method(vm, dv, "setBigUint64", 2, viewSet(u64));
}
