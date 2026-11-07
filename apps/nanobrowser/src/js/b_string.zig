//! String: the constructor and statics, and the prototype methods that search or take
//! substrings. Case, trimming, padding and the regexp-related methods are in b_string2.zig.

const std = @import("std");
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
const JSString = str.JSString;
const calls = @import("interp_call.zig");
const coroutine = @import("coroutine.zig");
const b2 = @import("b_string2.zig");

/// RequireObjectCoercible then ToString, for `this`.
pub fn thisStr(vm: *Vm, this: Value) Error!*JSString {
    if (this.isString()) return this.asString();
    if (this.isNullish()) return vm.throwError(.TypeError, "String.prototype method called on null or undefined");
    return conv.toStr(vm, this);
}

fn stringCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    var s: *JSString = vm.empty;
    if (args.len > 0) {
        if (vm.new_target.isUndefined() and args[0].isSymbol()) {
            var b = str.Builder.init(vm);
            defer b.deinit();
            try b.bytes("Symbol(");
            if (args[0].asSymbol().description) |d| try b.str(d);
            try b.byte(')');
            return Value.fromString(try b.finish());
        }
        s = try conv.toStr(vm, args[0]);
    }
    if (vm.new_target.isUndefined()) return Value.fromString(s);
    const o = try objmod.createExotic(vm, try calls.protoFromNewTarget(vm, vm.protos.string), .string);
    o.payload = .{ .value = Value.fromString(s) };
    return o.value();
}

fn fromCharCode(vm: *Vm, _: Value, args: []const Value) Error!Value {
    if (args.len == 1) {
        const n: u16 = @truncate(try conv.toUint32(vm, args[0]));
        return Value.fromString(try str.fromCodeUnit(vm, n));
    }
    const buf = try vm.gpa.alloc(u16, args.len);
    defer vm.gpa.free(buf);
    for (args, buf) |a, *o| o.* = @truncate(try conv.toUint32(vm, a));
    return Value.fromString(try str.fromUtf16(vm, buf));
}

fn fromCodePoint(vm: *Vm, _: Value, args: []const Value) Error!Value {
    var list: std.ArrayList(u16) = .empty;
    defer list.deinit(vm.gpa);
    for (args) |a| {
        const n = try conv.toNumber(vm, a);
        if (n != std.math.trunc(n) or n < 0 or n > 0x10FFFF) return vm.throwError(.RangeError, "Invalid code point");
        const cp: u32 = @intFromFloat(n);
        if (cp >= 0x10000) {
            try list.append(vm.gpa, @intCast(0xD800 + ((cp - 0x10000) >> 10)));
            try list.append(vm.gpa, @intCast(0xDC00 + ((cp - 0x10000) & 0x3FF)));
        } else try list.append(vm.gpa, @intCast(cp));
    }
    return Value.fromString(try str.fromUtf16(vm, list.items));
}

fn rawFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const cooked = try conv.toObject(vm, u.arg(args, 0));
    const raw = try conv.toObject(vm, try props.get(vm, cooked, vm.k.raw));
    const n = try conv.lengthOf(vm, raw);
    var b = str.Builder.init(vm);
    defer b.deinit();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try b.str(try conv.toStr(vm, try props.get(vm, raw, PropKey.fromIndex(@intCast(i)))));
        if (i + 1 < n and i + 1 < args.len) try b.str(try conv.toStr(vm, args[i + 1]));
    }
    return Value.fromString(try b.finish());
}

fn thisStringValue(vm: *Vm, this: Value) Error!Value {
    if (this.isString()) return this;
    if (this.isObject() and this.asObject().class == .string) return this.asObject().payload.value;
    return vm.throwError(.TypeError, "String.prototype.valueOf requires that 'this' be a String");
}

fn toStringFn(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return thisStringValue(vm, this);
}

fn atFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const s = try thisStr(vm, this);
    const n: f64 = @floatFromInt(s.len16);
    var i = try conv.toIntegerOrInf(vm, u.arg(args, 0));
    if (i < 0) i += n;
    if (i < 0 or i >= n) return Value.undefined;
    return Value.fromString(try str.fromCodeUnit(vm, try s.unitAt(vm, @intFromFloat(i))));
}

fn charAt(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const s = try thisStr(vm, this);
    const i = try conv.toIntegerOrInf(vm, u.arg(args, 0));
    if (i < 0 or i >= @as(f64, @floatFromInt(s.len16))) return Value.fromString(vm.empty);
    return Value.fromString(try str.fromCodeUnit(vm, try s.unitAt(vm, @intFromFloat(i))));
}

fn charCodeAt(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const s = try thisStr(vm, this);
    const i = try conv.toIntegerOrInf(vm, u.arg(args, 0));
    if (i < 0 or i >= @as(f64, @floatFromInt(s.len16))) return Value.nan;
    return Value.fromInt(try s.unitAt(vm, @intFromFloat(i)));
}

fn codePointAt(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const s = try thisStr(vm, this);
    const f = try conv.toIntegerOrInf(vm, u.arg(args, 0));
    if (f < 0 or f >= @as(f64, @floatFromInt(s.len16))) return Value.undefined;
    const i: usize = @intFromFloat(f);
    const c: u32 = try s.unitAt(vm, i);
    if (c >= 0xD800 and c < 0xDC00 and i + 1 < s.len16) {
        const d: u32 = try s.unitAt(vm, i + 1);
        if (d >= 0xDC00 and d < 0xE000) return Value.fromInt(@intCast(0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00)));
    }
    return Value.fromInt(@intCast(c));
}

fn concat(vm: *Vm, this: Value, args: []const Value) Error!Value {
    var s = try thisStr(vm, this);
    for (args) |a| s = try str.concat(vm, s, try conv.toStr(vm, a));
    return Value.fromString(s);
}

/// The first index of pat in s at or after from; both in UTF-16 units.
pub fn indexOfFrom(vm: *Vm, s: *JSString, pat: *JSString, from: usize) Error!?usize {
    if (from + pat.len16 > s.len16) return null;
    if (s.is_ascii) {
        if (!pat.is_ascii) return null;
        return std.mem.indexOfPos(u8, try s.flat(vm), from, try pat.flat(vm));
    }
    const hay = try s.units(vm);
    const needle = try str.toUnits(vm, pat);
    defer needle.deinit(vm);
    return std.mem.indexOfPos(u16, hay, from, needle.items);
}

fn lastIndexOfBefore(vm: *Vm, s: *JSString, pat: *JSString, from: usize) Error!?usize {
    if (pat.len16 > s.len16) return null;
    const start = @min(from, s.len16 - pat.len16);
    if (s.is_ascii) {
        if (!pat.is_ascii) return null;
        return std.mem.lastIndexOf(u8, (try s.flat(vm))[0 .. start + pat.len16], try pat.flat(vm));
    }
    const hay = try s.units(vm);
    const needle = try str.toUnits(vm, pat);
    defer needle.deinit(vm);
    return std.mem.lastIndexOf(u16, hay[0 .. start + pat.len16], needle.items);
}

fn clampPos(vm: *Vm, v: Value, len: usize) Error!usize {
    const n = try conv.toIntegerOrInf(vm, v);
    if (n <= 0) return 0;
    const f: f64 = @floatFromInt(len);
    return if (n >= f) len else @intFromFloat(n);
}

fn indexOf(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const s = try thisStr(vm, this);
    const pat = try conv.toStr(vm, u.arg(args, 0));
    const from = try clampPos(vm, u.arg(args, 1), s.len16);
    if (try indexOfFrom(vm, s, pat, from)) |i| return Value.fromUsize(i);
    return Value.fromInt(-1);
}

fn lastIndexOf(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const s = try thisStr(vm, this);
    const pat = try conv.toStr(vm, u.arg(args, 0));
    const nv = try conv.toNumber(vm, u.arg(args, 1));
    const from: usize = if (nv != nv) s.len16 else try clampPos(vm, Value.fromNumber(nv), s.len16);
    if (try lastIndexOfBefore(vm, s, pat, from)) |i| return Value.fromUsize(i);
    return Value.fromInt(-1);
}

fn notRegExp(vm: *Vm, v: Value, name: []const u8) Error!void {
    if (!v.isObject()) return;
    const m = try props.get(vm, v.asObject(), PropKey.fromSymbol(vm.sym.match));
    const is_re = if (m.isUndefined()) v.asObject().class == .regexp else @import("ops.zig").truthy(m);
    if (is_re) {
        var b: [96]u8 = undefined;
        const t = std.fmt.bufPrint(&b, "First argument to String.prototype.{s} must not be a regular expression", .{name}) catch "Argument must not be a regular expression";
        return vm.throwError(.TypeError, t);
    }
}

fn includes(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const s = try thisStr(vm, this);
    try notRegExp(vm, u.arg(args, 0), "includes");
    const pat = try conv.toStr(vm, u.arg(args, 0));
    const from = try clampPos(vm, u.arg(args, 1), s.len16);
    return Value.fromBool(try indexOfFrom(vm, s, pat, from) != null);
}

fn rangeEqual(vm: *Vm, s: *JSString, at: usize, pat: *JSString) Error!bool {
    if (at + pat.len16 > s.len16) return false;
    if (s.is_ascii and pat.is_ascii) return std.mem.eql(u8, (try s.flat(vm))[at..][0..pat.len16], try pat.flat(vm));
    const a = try str.toUnits(vm, s);
    defer a.deinit(vm);
    const b = try str.toUnits(vm, pat);
    defer b.deinit(vm);
    return std.mem.eql(u16, a.items[at..][0..b.items.len], b.items);
}

fn startsWith(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const s = try thisStr(vm, this);
    try notRegExp(vm, u.arg(args, 0), "startsWith");
    const pat = try conv.toStr(vm, u.arg(args, 0));
    return Value.fromBool(try rangeEqual(vm, s, try clampPos(vm, u.arg(args, 1), s.len16), pat));
}

fn endsWith(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const s = try thisStr(vm, this);
    try notRegExp(vm, u.arg(args, 0), "endsWith");
    const pat = try conv.toStr(vm, u.arg(args, 0));
    const end = if (u.arg(args, 1).isUndefined()) s.len16 else try clampPos(vm, args[1], s.len16);
    if (pat.len16 > end) return Value.false;
    return Value.fromBool(try rangeEqual(vm, s, end - pat.len16, pat));
}

fn slice(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const s = try thisStr(vm, this);
    const a = try u.relativeIndex(vm, u.arg(args, 0), s.len16, 0);
    const b = try u.relativeIndex(vm, u.arg(args, 1), s.len16, s.len16);
    return Value.fromString(try str.substring(vm, s, a, b));
}

fn substring(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const s = try thisStr(vm, this);
    const a = try clampPos(vm, u.arg(args, 0), s.len16);
    const b = if (u.arg(args, 1).isUndefined()) s.len16 else try clampPos(vm, args[1], s.len16);
    return Value.fromString(try str.substring(vm, s, @min(a, b), @max(a, b)));
}

fn substr(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const s = try thisStr(vm, this);
    const a = try u.relativeIndex(vm, u.arg(args, 0), s.len16, 0);
    const n = if (u.arg(args, 1).isUndefined()) @as(f64, @floatFromInt(s.len16)) else try conv.toIntegerOrInf(vm, args[1]);
    if (n <= 0) return Value.fromString(vm.empty);
    const end = @min(@as(f64, @floatFromInt(a)) + n, @as(f64, @floatFromInt(s.len16)));
    return Value.fromString(try str.substring(vm, s, a, @intFromFloat(end)));
}

fn stringIterator(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const s = try thisStr(vm, this);
    const data = try vm.gpa.create(objmod.IterData);
    data.* = .{ .target = Value.fromString(s) };
    const o = objmod.create(vm, vm.protos.string_iter, .string_iter) catch |e| {
        vm.gpa.destroy(data);
        return e;
    };
    o.payload = .{ .iter = data };
    return o.value();
}

fn stringIterNext(vm: *Vm, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().class != .string_iter) return vm.throwError(.TypeError, "next method called on incompatible receiver");
    const it = this.asObject().payload.iter;
    const s = it.target.asString();
    if (it.index >= s.len16) return coroutine.iterResult(vm, Value.undefined, true);
    const i = it.index;
    const c = try s.unitAt(vm, i);
    var n: usize = 1;
    if (c >= 0xD800 and c < 0xDC00 and i + 1 < s.len16) {
        const d = try s.unitAt(vm, i + 1);
        if (d >= 0xDC00 and d < 0xE000) n = 2;
    }
    it.index += n;
    return coroutine.iterResult(vm, Value.fromString(try str.substring(vm, s, i, i + n)), false);
}

pub fn init(vm: *Vm) Error!void {
    const p = vm.protos.string;
    const c = try u.ctor(vm, "String", 1, stringCtor, p);
    try u.method(vm, c, "fromCharCode", 1, fromCharCode);
    try u.method(vm, c, "fromCodePoint", 1, fromCodePoint);
    try u.method(vm, c, "raw", 1, rawFn);
    try u.method(vm, p, "toString", 0, toStringFn);
    try u.method(vm, p, "valueOf", 0, toStringFn);
    try u.method(vm, p, "at", 1, atFn);
    try u.method(vm, p, "charAt", 1, charAt);
    try u.method(vm, p, "charCodeAt", 1, charCodeAt);
    try u.method(vm, p, "codePointAt", 1, codePointAt);
    try u.method(vm, p, "concat", 1, concat);
    try u.method(vm, p, "indexOf", 1, indexOf);
    try u.method(vm, p, "lastIndexOf", 1, lastIndexOf);
    try u.method(vm, p, "includes", 1, includes);
    try u.method(vm, p, "startsWith", 1, startsWith);
    try u.method(vm, p, "endsWith", 1, endsWith);
    try u.method(vm, p, "slice", 2, slice);
    try u.method(vm, p, "substring", 2, substring);
    try u.method(vm, p, "substr", 2, substr);
    try u.symMethod(vm, p, vm.sym.iterator, "[Symbol.iterator]", 0, stringIterator);
    const ip = try u.newProto(vm, vm.protos.iterator);
    vm.protos.string_iter = ip;
    try u.method(vm, ip, "next", 0, stringIterNext);
    try u.toStringTag(vm, ip, "String Iterator");
    try b2.init(vm, p);
}
