//! BigInt on top of std.math.big: literals, conversions, arithmetic and bit operations.
//! Negative shifts and bit operations on negatives follow two's complement as JS requires.

const std = @import("std");
const Managed = std.math.big.int.Managed;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const heap = @import("heap.zig");
const u = @import("b_util.zig");
const Value = u.Value;
const Object = u.Object;
const objmod = @import("object.zig");
const conv = @import("conv.zig");
const ops = @import("ops.zig");
const str = @import("string.zig");
const JSString = str.JSString;
const Op = @import("bytecode.zig").Op;

fn alloc(vm: *Vm) Error!*heap.BigInt {
    var m = try Managed.init(vm.gpa);
    errdefer m.deinit();
    const b = try vm.heap.create(heap.BigInt, .bigint);
    b.v = m;
    return b;
}

fn fromI64(vm: *Vm, i: i64) Error!Value {
    const b = try alloc(vm);
    try b.v.set(i);
    return Value.fromBigInt(b);
}

inline fn val(v: Value) *Managed {
    return &v.asBigInt().v;
}

pub fn isZero(v: Value) bool {
    return val(v).eqlZero();
}

pub fn hash(v: Value) u64 {
    const c = val(v).toConst();
    return std.hash.Wyhash.hash(@intFromBool(c.positive), std.mem.sliceAsBytes(c.limbs));
}

pub fn equal(a: Value, b: Value) bool {
    return val(a).order(val(b).*) == .eq;
}

pub const Cmp = enum { lt, eq, gt, undefined };

pub fn order(a: Value, b: Value) Cmp {
    return switch (val(a).order(val(b).*)) {
        .lt => .lt,
        .eq => .eq,
        .gt => .gt,
    };
}

pub fn orderNumber(a: Value, d: f64) Cmp {
    if (d != d) return .undefined;
    if (std.math.isInf(d)) return if (d > 0) .lt else .gt;
    const x = val(a).toFloat(f64, .nearest_even)[0];
    if (x < d) return .lt;
    if (x > d) return .gt;
    return .eq;
}

fn parseDigits(vm: *Vm, s: []const u8) Error!?Value {
    var t = s;
    var neg = false;
    if (t.len != 0 and (t[0] == '-' or t[0] == '+')) {
        neg = t[0] == '-';
        t = t[1..];
    }
    var base: u8 = 10;
    if (t.len > 2 and t[0] == '0') {
        switch (t[1] | 0x20) {
            'x' => base = 16,
            'o' => base = 8,
            'b' => base = 2,
            else => {},
        }
        if (base != 10) {
            if (neg) return null;
            t = t[2..];
        }
    }
    if (t.len == 0) return try fromI64(vm, 0);
    for (t) |c| {
        const d: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        if (d >= base) return null;
    }
    const b = try alloc(vm);
    b.v.setString(base, t) catch return error.OutOfMemory;
    if (neg) b.v.negate();
    return Value.fromBigInt(b);
}

/// StringToBigInt: null if the string is not a valid integer.
pub fn parseString(vm: *Vm, s: []const u8) Error!?Value {
    return parseDigits(vm, conv.trimJs(s, true, true));
}

/// A literal's text, without its `n`.
pub fn fromLiteral(vm: *Vm, s: *JSString) Error!Value {
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(vm.gpa);
    for (try s.flat(vm)) |c| {
        if (c != '_') try clean.append(vm.gpa, c);
    }
    return (try parseDigits(vm, clean.items)) orelse vm.throwError(.SyntaxError, "Invalid BigInt literal");
}

pub fn literalToDecimal(vm: *Vm, s: *JSString) Error!*JSString {
    return toStringRadix(vm, try fromLiteral(vm, s), 10);
}

pub fn toStringRadix(vm: *Vm, v: Value, radix: u8) Error!*JSString {
    const t = val(v).toString(vm.gpa, radix, .lower) catch return error.OutOfMemory;
    defer vm.gpa.free(t);
    return str.fromUtf8(vm, t);
}

pub fn fromNumber(vm: *Vm, d: f64) Error!Value {
    if (d != std.math.trunc(d) or std.math.isInf(d) or d != d) {
        return vm.throwError(.RangeError, "The number cannot be converted to a BigInt because it is not an integer");
    }
    if (@abs(d) < 9007199254740992.0) return fromI64(vm, @intFromFloat(d));
    // Beyond 2^53: mantissa shifted by the exponent.
    const parts = std.math.frexp(@abs(d));
    const mant: u64 = @intFromFloat(std.math.ldexp(parts.significand, 53));
    const shift: usize = @intCast(parts.exponent - 53);
    const b = try alloc(vm);
    var m = try Managed.initSet(vm.gpa, mant);
    defer m.deinit();
    try b.v.shiftLeft(&m, shift);
    if (d < 0) b.v.negate();
    return Value.fromBigInt(b);
}

pub fn toNumber(v: Value) f64 {
    return val(v).toFloat(f64, .nearest_even)[0];
}

/// ToBigInt.
pub fn toBigInt(vm: *Vm, v0: Value) Error!Value {
    const v = try conv.toPrimitive(vm, v0, .number);
    if (v.isBigInt()) return v;
    if (v.isBool()) return fromI64(vm, @intFromBool(v.asBool()));
    if (v.isString()) {
        return (try parseString(vm, try v.asString().flat(vm))) orelse vm.throwError(.SyntaxError, "Cannot convert string to a BigInt");
    }
    return vm.throwError(.TypeError, "Cannot convert value to a BigInt");
}

pub fn arith(vm: *Vm, op: ops.ArithOp, a: Value, b: Value) Error!Value {
    const r = try alloc(vm);
    const x = val(a);
    const y = val(b);
    switch (op) {
        .add => try r.v.add(x, y),
        .sub => try r.v.sub(x, y),
        .mul => try r.v.mul(x, y),
        .div, .mod => {
            if (y.eqlZero()) return vm.throwError(.RangeError, "Division by zero");
            var q = try Managed.init(vm.gpa);
            defer q.deinit();
            var rem = try Managed.init(vm.gpa);
            defer rem.deinit();
            try q.divTrunc(&rem, x, y);
            try r.v.copy((if (op == .div) q else rem).toConst());
        },
        .pow => {
            if (!y.isPositive() and !y.eqlZero()) return vm.throwError(.RangeError, "Exponent must be non-negative");
            const e = y.toInt(u32) catch return vm.throwError(.RangeError, "Maximum BigInt size exceeded");
            try r.v.pow(x, e);
        },
    }
    return Value.fromBigInt(r);
}

/// x as a two's complement with `bits` bits, as an unsigned magnitude.
fn twos(vm: *Vm, x: *const Managed, bits: usize) Error!Managed {
    var out = try Managed.init(vm.gpa);
    errdefer out.deinit();
    try out.truncate(x, .unsigned, bits);
    return out;
}

fn bitWidth(a: *const Managed, b: *const Managed) usize {
    return @max(a.bitCountAbs(), b.bitCountAbs()) + 2;
}

pub fn bitop(vm: *Vm, op: Op, a: Value, b: Value) Error!Value {
    const x = val(a);
    const y = val(b);
    const r = try alloc(vm);
    switch (op) {
        .shl, .sar => {
            const count = y.toInt(i64) catch return vm.throwError(.RangeError, "Maximum BigInt size exceeded");
            const left = (op == .shl) == (count >= 0);
            const n: usize = @intCast(@abs(count));
            if (left) {
                if (n > 1 << 30) return vm.throwError(.RangeError, "Maximum BigInt size exceeded");
                try r.v.shiftLeft(x, n);
            } else if (x.isPositive() or x.eqlZero()) {
                try r.v.shiftRight(x, n);
            } else {
                // Arithmetic shift rounds toward negative infinity.
                var one = try Managed.initSet(vm.gpa, 1);
                defer one.deinit();
                var t = try Managed.init(vm.gpa);
                defer t.deinit();
                try t.add(x, &one);
                t.negate();
                try r.v.shiftRight(&t, n);
                try r.v.add(&r.v, &one);
                r.v.negate();
            }
        },
        .shr => return vm.throwError(.TypeError, "BigInts have no unsigned right shift, use >> instead"),
        else => {
            const w = bitWidth(x, y);
            var ta = try twos(vm, x, w);
            defer ta.deinit();
            var tb = try twos(vm, y, w);
            defer tb.deinit();
            var t = try Managed.init(vm.gpa);
            defer t.deinit();
            switch (op) {
                .bit_and => try t.bitAnd(&ta, &tb),
                .bit_or => try t.bitOr(&ta, &tb),
                else => try t.bitXor(&ta, &tb),
            }
            try r.v.truncate(&t, .signed, w);
        },
    }
    return Value.fromBigInt(r);
}

pub fn negate(vm: *Vm, a: Value) Error!Value {
    const r = try alloc(vm);
    try r.v.copy(val(a).toConst());
    r.v.negate();
    return Value.fromBigInt(r);
}

pub fn bitNot(vm: *Vm, a: Value) Error!Value {
    // ~x == -x - 1.
    const n = try negate(vm, a);
    const r = try alloc(vm);
    var one = try Managed.initSet(vm.gpa, 1);
    defer one.deinit();
    try r.v.sub(val(n), &one);
    return Value.fromBigInt(r);
}

pub fn incDec(vm: *Vm, a: Value, is_inc: bool) Error!Value {
    const r = try alloc(vm);
    var one = try Managed.initSet(vm.gpa, 1);
    defer one.deinit();
    if (is_inc) try r.v.add(val(a), &one) else try r.v.sub(val(a), &one);
    return Value.fromBigInt(r);
}

fn bigintCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    if (!vm.new_target.isUndefined()) return vm.throwError(.TypeError, "BigInt is not a constructor");
    const p = try conv.toPrimitive(vm, u.arg(args, 0), .number);
    if (p.isNumber()) return fromNumber(vm, p.asNumber());
    return toBigInt(vm, p);
}

fn thisBig(vm: *Vm, this: Value) Error!Value {
    if (this.isBigInt()) return this;
    if (this.isObject() and this.asObject().class == .bigint) return this.asObject().payload.value;
    return vm.throwError(.TypeError, "not a BigInt");
}

fn toStringFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const b = try thisBig(vm, this);
    var radix: f64 = 10;
    if (!u.arg(args, 0).isUndefined()) radix = try conv.toIntegerOrInf(vm, args[0]);
    if (radix < 2 or radix > 36) return vm.throwError(.RangeError, "toString() radix must be between 2 and 36");
    return Value.fromString(try toStringRadix(vm, b, @intFromFloat(radix)));
}

fn valueOfFn(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return thisBig(vm, this);
}

fn asN(vm: *Vm, args: []const Value, signed: bool) Error!Value {
    const bits = try conv.toIndex(vm, u.arg(args, 0));
    const b = try toBigInt(vm, u.arg(args, 1));
    const r = try alloc(vm);
    if (bits == 0) return fromI64(vm, 0);
    try r.v.truncate(val(b), if (signed) .signed else .unsigned, bits);
    return Value.fromBigInt(r);
}

fn asIntN(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return asN(vm, args, true);
}
fn asUintN(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return asN(vm, args, false);
}

/// Used by the typed arrays: a 64-bit two's complement read and write.
pub fn fromU64(vm: *Vm, x: u64, signed: bool) Error!Value {
    const b = try alloc(vm);
    if (signed) {
        try b.v.set(@as(i64, @bitCast(x)));
    } else {
        try b.v.set(x);
    }
    return Value.fromBigInt(b);
}

pub fn toU64(vm: *Vm, v: Value) Error!u64 {
    var t = try Managed.init(vm.gpa);
    defer t.deinit();
    try t.truncate(val(v), .unsigned, 64);
    return t.toInt(u64) catch 0;
}

pub fn init(vm: *Vm) Error!void {
    const p = try u.newProto(vm, vm.protos.object);
    vm.protos.bigint = p;
    const c = try u.ctor(vm, "BigInt", 1, bigintCtor, p);
    try u.method(vm, c, "asIntN", 2, asIntN);
    try u.method(vm, c, "asUintN", 2, asUintN);
    try u.toStringTag(vm, p, "BigInt");
    try u.method(vm, p, "toString", 0, toStringFn);
    try u.method(vm, p, "toLocaleString", 0, toStringFn);
    try u.method(vm, p, "valueOf", 0, valueOfFn);
}
