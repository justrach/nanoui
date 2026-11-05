//! Operators' slow paths: string and BigInt addition, arithmetic with conversions,
//! comparison, equality, typeof and instanceof.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const value = @import("value.zig");
const Value = value.Value;
const PropKey = value.PropKey;
const Op = @import("bytecode.zig").Op;
const props = @import("props.zig");
const conv = @import("conv.zig");
const str = @import("string.zig");
const big = @import("b_bigint.zig");
const calls = @import("interp_call.zig");

pub inline fn truthy(v: Value) bool {
    if (v.isBool()) return v.asBool();
    if (v.isInt()) return v.asInt() != 0;
    if (v.isObject()) return !v.asObject().flags.html_dda;
    if (v.isNullish()) return false;
    if (v.isDouble()) {
        const d = v.asDouble();
        return d == d and d != 0;
    }
    if (v.isString()) return v.asString().byte_len != 0;
    if (v.isBigInt()) return !big.isZero(v);
    return true;
}

pub fn add(vm: *Vm, a0: Value, b0: Value) Error!Value {
    if (a0.isString() and b0.isString()) return Value.fromString(try str.concat(vm, a0.asString(), b0.asString()));
    const a = try conv.toPrimitive(vm, a0, .default);
    const b = try conv.toPrimitive(vm, b0, .default);
    if (a.isString() or b.isString()) {
        const x = try conv.toStr(vm, a);
        const y = try conv.toStr(vm, b);
        return Value.fromString(try str.concat(vm, x, y));
    }
    return arith(vm, .add, a, b);
}

pub const ArithOp = enum { add, sub, mul, div, mod, pow };

pub fn toNumeric(vm: *Vm, v: Value) Error!Value {
    const p = try conv.toPrimitive(vm, v, .number);
    if (p.isBigInt()) return p;
    return Value.fromNumber(try conv.toNumber(vm, p));
}

pub fn fmod(x: f64, y: f64) f64 {
    if (y == 0 or std.math.isInf(x) or x != x or y != y) return std.math.nan(f64);
    if (std.math.isInf(y)) return x;
    if (x == 0) return x;
    const r = @rem(x, y);
    if (r == 0 and std.math.signbit(x)) return -0.0;
    return r;
}

pub fn jsPow(x: f64, y: f64) f64 {
    if (y != y) return y;
    if (y == 0) return 1;
    if ((x == 1 or x == -1) and std.math.isInf(y)) return std.math.nan(f64);
    return std.math.pow(f64, x, y);
}

pub fn arith(vm: *Vm, op: ArithOp, a0: Value, b0: Value) Error!Value {
    const a = try toNumeric(vm, a0);
    const b = try toNumeric(vm, b0);
    if (a.isBigInt() or b.isBigInt()) {
        if (!(a.isBigInt() and b.isBigInt())) return vm.throwError(.TypeError, "Cannot mix BigInt and other types, use explicit conversions");
        return big.arith(vm, op, a, b);
    }
    const x = a.asNumber();
    const y = b.asNumber();
    return Value.fromNumber(switch (op) {
        .add => x + y,
        .sub => x - y,
        .mul => x * y,
        .div => x / y,
        .mod => fmod(x, y),
        .pow => jsPow(x, y),
    });
}

pub fn modulo(vm: *Vm, a: Value, b: Value) Error!Value {
    return arith(vm, .mod, a, b);
}

pub fn bitop(vm: *Vm, op: Op, a0: Value, b0: Value) Error!Value {
    const a = try toNumeric(vm, a0);
    const b = try toNumeric(vm, b0);
    if (a.isBigInt() or b.isBigInt()) {
        if (!(a.isBigInt() and b.isBigInt())) return vm.throwError(.TypeError, "Cannot mix BigInt and other types, use explicit conversions");
        return big.bitop(vm, op, a, b);
    }
    const x = try conv.toInt32(vm, a);
    const y = try conv.toInt32(vm, b);
    const s: u5 = @truncate(@as(u32, @bitCast(y)));
    return switch (op) {
        .bit_and => Value.fromInt(x & y),
        .bit_or => Value.fromInt(x | y),
        .bit_xor => Value.fromInt(x ^ y),
        .shl => Value.fromInt(@bitCast(@as(u32, @bitCast(x)) << s)),
        .sar => Value.fromInt(x >> s),
        else => Value.fromUsize(@as(u32, @bitCast(x)) >> s),
    };
}

pub fn bitNot(vm: *Vm, a0: Value) Error!Value {
    const a = try toNumeric(vm, a0);
    if (a.isBigInt()) return big.bitNot(vm, a);
    return Value.fromInt(~try conv.toInt32(vm, a));
}

pub fn negate(vm: *Vm, a0: Value) Error!Value {
    const a = try toNumeric(vm, a0);
    if (a.isBigInt()) return big.negate(vm, a);
    if (a.isInt() and a.asInt() != 0 and a.asInt() != std.math.minInt(i32)) return Value.fromInt(-a.asInt());
    return Value.fromNumber(-a.asNumber());
}

pub fn incDec(vm: *Vm, a0: Value, is_inc: bool) Error!Value {
    const a = try toNumeric(vm, a0);
    if (a.isBigInt()) return big.incDec(vm, a, is_inc);
    return Value.fromNumber(a.asNumber() + (if (is_inc) @as(f64, 1) else -1));
}

const Cmp = big.Cmp;

fn order(a: f64, b: f64) Cmp {
    if (a != a or b != b) return .undefined;
    if (a < b) return .lt;
    if (a > b) return .gt;
    return .eq;
}

fn comparePrimitive(vm: *Vm, a: Value, b: Value) Error!Cmp {
    if (a.isString() and b.isString()) {
        return switch (try str.compare(vm, a.asString(), b.asString())) {
            .lt => .lt,
            .gt => .gt,
            .eq => .eq,
        };
    }
    if (a.isBigInt() and b.isString()) {
        const y = big.parseString(vm, try b.asString().flat(vm)) catch |e| return e;
        if (y == null) return .undefined;
        return big.order(a, y.?);
    }
    if (a.isString() and b.isBigInt()) {
        const x = big.parseString(vm, try a.asString().flat(vm)) catch |e| return e;
        if (x == null) return .undefined;
        return big.order(x.?, b);
    }
    const x = if (a.isBigInt()) a else Value.fromDouble(try conv.toNumber(vm, a));
    const y = if (b.isBigInt()) b else Value.fromDouble(try conv.toNumber(vm, b));
    if (x.isBigInt() and y.isBigInt()) return big.order(x, y);
    if (x.isBigInt()) return big.orderNumber(x, y.asDouble());
    if (y.isBigInt()) {
        return switch (big.orderNumber(y, x.asDouble())) {
            .lt => .gt,
            .gt => .lt,
            else => |c| c,
        };
    }
    return order(x.asDouble(), y.asDouble());
}

pub fn compare(vm: *Vm, op: Op, a0: Value, b0: Value) Error!bool {
    const a = try conv.toPrimitive(vm, a0, .number);
    const b = try conv.toPrimitive(vm, b0, .number);
    const c = try comparePrimitive(vm, a, b);
    return switch (op) {
        .lt => c == .lt,
        .le => c == .lt or c == .eq,
        .gt => c == .gt,
        else => c == .gt or c == .eq,
    };
}

pub fn strictEquals(vm: *Vm, a: Value, b: Value) Error!bool {
    if (a.isNumber() and b.isNumber()) return a.asNumber() == b.asNumber();
    if (a.bits == b.bits) return true;
    if (a.isString() and b.isString()) return str.eql(vm, a.asString(), b.asString());
    if (a.isBigInt() and b.isBigInt()) return big.equal(a, b);
    return false;
}

fn nullishOrDda(v: Value) bool {
    return v.isNullish() or (v.isObject() and v.asObject().flags.html_dda);
}

pub fn looseEquals(vm: *Vm, a: Value, b: Value) Error!bool {
    if (a.isNullish() or b.isNullish()) return nullishOrDda(a) and nullishOrDda(b);
    if (a.isNumber() and b.isNumber()) return a.asNumber() == b.asNumber();
    if (a.isString() and b.isString()) return str.eql(vm, a.asString(), b.asString());
    if (a.isObject() and b.isObject()) return a.bits == b.bits;
    if (a.isBool() and b.isBool()) return a.bits == b.bits;
    if (a.isSymbol() and b.isSymbol()) return a.bits == b.bits;
    if (a.isBigInt() and b.isBigInt()) return big.equal(a, b);
    if (a.isBool()) return looseEquals(vm, Value.fromNumber(if (a.asBool()) 1 else 0), b);
    if (b.isBool()) return looseEquals(vm, a, Value.fromNumber(if (b.asBool()) 1 else 0));
    if (a.isObject()) return looseEquals(vm, try conv.toPrimitive(vm, a, .default), b);
    if (b.isObject()) return looseEquals(vm, a, try conv.toPrimitive(vm, b, .default));
    if (a.isSymbol() or b.isSymbol()) return false;
    if (a.isBigInt() or b.isBigInt()) {
        const bi = if (a.isBigInt()) a else b;
        const other = if (a.isBigInt()) b else a;
        if (other.isString()) {
            const p = try big.parseString(vm, try other.asString().flat(vm));
            return p != null and big.equal(bi, p.?);
        }
        return big.orderNumber(bi, other.asNumber()) == .eq;
    }
    return (try conv.toNumber(vm, a)) == (try conv.toNumber(vm, b));
}

pub fn typeOf(vm: *Vm, v: Value) Value {
    const k = &vm.k;
    const key = if (v.isUndefined())
        k.undefined
    else if (v.isNull())
        k.object
    else if (v.isBool())
        k.boolean
    else if (v.isNumber())
        k.number
    else if (v.isString())
        k.string
    else if (v.isSymbol())
        k.symbol
    else if (v.isBigInt())
        k.bigint
    else if (v.isCallable())
        k.function
    else if (v.isObject() and v.asObject().flags.html_dda)
        k.undefined
    else
        k.object;
    return Value.fromString(key.atom());
}

pub fn ordinaryHasInstance(vm: *Vm, c: Value, v: Value) Error!bool {
    if (!c.isCallable()) return false;
    var co = c.asObject();
    while (co.class == .bound) co = co.payload.bound.target;
    if (!v.isObject()) return false;
    const p = try props.get(vm, co, vm.k.prototype);
    if (!p.isObject()) return vm.throwError(.TypeError, "Function has non-object prototype in instanceof check");
    var o = try props.getProto(vm, v.asObject());
    while (o) |x| : (o = try props.getProto(vm, x)) {
        if (x == p.asObject()) return true;
    }
    return false;
}

pub fn instanceOf(vm: *Vm, v: Value, c: Value) Error!bool {
    if (!c.isObject()) return vm.throwError(.TypeError, "Right-hand side of 'instanceof' is not callable");
    const m = try props.get(vm, c.asObject(), PropKey.fromSymbol(vm.sym.hasInstance));
    if (!m.isNullish()) {
        // The default Function.prototype[Symbol.hasInstance] needs no call.
        if (m.isObject() and m.asObject() == vm.function_has_instance) return ordinaryHasInstance(vm, c, v);
        return truthy(try calls.call(vm, m, c, &.{v}));
    }
    if (!c.isCallable()) return vm.throwError(.TypeError, "Right-hand side of 'instanceof' is not callable");
    return ordinaryHasInstance(vm, c, v);
}
