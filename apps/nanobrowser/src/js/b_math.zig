//! Math.

const std = @import("std");
const m = std.math;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const u = @import("b_util.zig");
const Value = u.Value;
const objmod = @import("object.zig");
const conv = @import("conv.zig");
const ops = @import("ops.zig");

fn unary(comptime f: fn (f64) f64) objmod.NativeFn {
    return struct {
        fn call(vm: *Vm, _: Value, args: []const Value) Error!Value {
            return Value.fromNumber(f(try conv.toNumber(vm, u.arg(args, 0))));
        }
    }.call;
}

fn jsRound(x: f64) f64 {
    if (x != x or m.isInf(x) or x == 0) return x;
    if (x < 0 and x >= -0.5) return -0.0;
    if (@abs(x) >= 4503599627370496.0) return x;
    return m.floor(x + 0.5);
}
fn jsSign(x: f64) f64 {
    if (x != x or x == 0) return x;
    return if (x > 0) 1 else -1;
}
fn jsAsin(x: f64) f64 {
    return m.asin(x);
}
fn fabs(x: f64) f64 {
    return @abs(x);
}
fn ffloor(x: f64) f64 {
    return @floor(x);
}
fn fceil(x: f64) f64 {
    return @ceil(x);
}
fn ftrunc(x: f64) f64 {
    return @trunc(x);
}
fn fsqrt(x: f64) f64 {
    return @sqrt(x);
}
fn fcbrt(x: f64) f64 {
    return m.cbrt(x);
}
fn fsin(x: f64) f64 {
    return @sin(x);
}
fn fcos(x: f64) f64 {
    return @cos(x);
}
fn ftan(x: f64) f64 {
    return @tan(x);
}
fn facos(x: f64) f64 {
    return m.acos(x);
}
fn fatan(x: f64) f64 {
    return m.atan(x);
}
fn fsinh(x: f64) f64 {
    return m.sinh(x);
}
fn fcosh(x: f64) f64 {
    return m.cosh(x);
}
fn ftanh(x: f64) f64 {
    return m.tanh(x);
}
fn fasinh(x: f64) f64 {
    return m.asinh(x);
}
fn facosh(x: f64) f64 {
    return m.acosh(x);
}
fn fatanh(x: f64) f64 {
    return m.atanh(x);
}
fn fexp(x: f64) f64 {
    return @exp(x);
}
fn fexpm1(x: f64) f64 {
    return m.expm1(x);
}
fn flog(x: f64) f64 {
    if (x < 0) return m.nan(f64);
    return @log(x);
}
fn flog2(x: f64) f64 {
    if (x < 0) return m.nan(f64);
    return @log2(x);
}
fn flog10(x: f64) f64 {
    if (x < 0) return m.nan(f64);
    return @log10(x);
}
fn flog1p(x: f64) f64 {
    return m.log1p(x);
}
fn ffround(x: f64) f64 {
    return @floatCast(@as(f32, @floatCast(x)));
}

fn atan2(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(m.atan2(try conv.toNumber(vm, u.arg(args, 0)), try conv.toNumber(vm, u.arg(args, 1))));
}
fn pow(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(ops.jsPow(try conv.toNumber(vm, u.arg(args, 0)), try conv.toNumber(vm, u.arg(args, 1))));
}
fn maxFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    var r = -m.inf(f64);
    var nan = false;
    for (args) |a| {
        const x = try conv.toNumber(vm, a);
        if (x != x) nan = true;
        if (x > r or (x == 0 and r == 0 and !m.signbit(x))) r = x;
    }
    return if (nan) Value.nan else Value.fromNumber(r);
}
fn minFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    var r = m.inf(f64);
    var nan = false;
    for (args) |a| {
        const x = try conv.toNumber(vm, a);
        if (x != x) nan = true;
        if (x < r or (x == 0 and r == 0 and m.signbit(x))) r = x;
    }
    return if (nan) Value.nan else Value.fromNumber(r);
}
fn hypot(vm: *Vm, _: Value, args: []const Value) Error!Value {
    var inf = false;
    var nan = false;
    var sum: f64 = 0;
    for (args) |a| {
        const x = try conv.toNumber(vm, a);
        if (m.isInf(x)) inf = true;
        if (x != x) nan = true;
        sum += x * x;
    }
    if (inf) return Value.fromDouble(m.inf(f64));
    if (nan) return Value.nan;
    return Value.fromNumber(@sqrt(sum));
}
fn imul(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const a = try conv.toInt32(vm, u.arg(args, 0));
    const b = try conv.toInt32(vm, u.arg(args, 1));
    return Value.fromInt(a *% b);
}
fn clz32(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return Value.fromInt(@clz(try conv.toUint32(vm, u.arg(args, 0))));
}
fn random(vm: *Vm, _: Value, _: []const Value) Error!Value {
    // xorshift64*: fast, and non-cryptographic as Math.random is allowed to be.
    var x = vm.rng;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    vm.rng = x;
    const r = x *% 0x2545F4914F6CDD1D;
    return Value.fromDouble(@as(f64, @floatFromInt(r >> 11)) / 9007199254740992.0);
}

pub fn init(vm: *Vm) Error!void {
    const o = try objmod.newPlain(vm);
    try u.data(vm, vm.global_obj, "Math", o.value());
    try u.toStringTag(vm, o, "Math");
    try u.constant(vm, o, "E", Value.fromDouble(m.e));
    try u.constant(vm, o, "LN10", Value.fromDouble(m.ln10));
    try u.constant(vm, o, "LN2", Value.fromDouble(m.ln2));
    try u.constant(vm, o, "LOG10E", Value.fromDouble(m.log10e));
    try u.constant(vm, o, "LOG2E", Value.fromDouble(m.log2e));
    try u.constant(vm, o, "PI", Value.fromDouble(m.pi));
    try u.constant(vm, o, "SQRT1_2", Value.fromDouble(m.sqrt1_2));
    try u.constant(vm, o, "SQRT2", Value.fromDouble(m.sqrt2));
    try u.method(vm, o, "abs", 1, unary(fabs));
    try u.method(vm, o, "floor", 1, unary(ffloor));
    try u.method(vm, o, "ceil", 1, unary(fceil));
    try u.method(vm, o, "round", 1, unary(jsRound));
    try u.method(vm, o, "trunc", 1, unary(ftrunc));
    try u.method(vm, o, "sign", 1, unary(jsSign));
    try u.method(vm, o, "sqrt", 1, unary(fsqrt));
    try u.method(vm, o, "cbrt", 1, unary(fcbrt));
    try u.method(vm, o, "sin", 1, unary(fsin));
    try u.method(vm, o, "cos", 1, unary(fcos));
    try u.method(vm, o, "tan", 1, unary(ftan));
    try u.method(vm, o, "asin", 1, unary(jsAsin));
    try u.method(vm, o, "acos", 1, unary(facos));
    try u.method(vm, o, "atan", 1, unary(fatan));
    try u.method(vm, o, "sinh", 1, unary(fsinh));
    try u.method(vm, o, "cosh", 1, unary(fcosh));
    try u.method(vm, o, "tanh", 1, unary(ftanh));
    try u.method(vm, o, "asinh", 1, unary(fasinh));
    try u.method(vm, o, "acosh", 1, unary(facosh));
    try u.method(vm, o, "atanh", 1, unary(fatanh));
    try u.method(vm, o, "exp", 1, unary(fexp));
    try u.method(vm, o, "expm1", 1, unary(fexpm1));
    try u.method(vm, o, "log", 1, unary(flog));
    try u.method(vm, o, "log2", 1, unary(flog2));
    try u.method(vm, o, "log10", 1, unary(flog10));
    try u.method(vm, o, "log1p", 1, unary(flog1p));
    try u.method(vm, o, "fround", 1, unary(ffround));
    try u.method(vm, o, "atan2", 2, atan2);
    try u.method(vm, o, "pow", 2, pow);
    try u.method(vm, o, "max", 2, maxFn);
    try u.method(vm, o, "min", 2, minFn);
    try u.method(vm, o, "hypot", 2, hypot);
    try u.method(vm, o, "imul", 2, imul);
    try u.method(vm, o, "clz32", 1, clz32);
    try u.method(vm, o, "random", 0, random);
}
