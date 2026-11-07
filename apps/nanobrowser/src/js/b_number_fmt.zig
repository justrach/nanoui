//! Exact decimal rounding for toFixed, toExponential and toPrecision. The spec picks the
//! integer closest to the exact binary value (ties go up), which takes arbitrary precision.

const std = @import("std");
const Managed = std.math.big.int.Managed;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const str = @import("string.zig");

const Parts = struct { mant: u64, exp: i32 };

fn decompose(x: f64) Parts {
    const bits: u64 = @bitCast(x);
    const raw_exp: i32 = @intCast((bits >> 52) & 0x7FF);
    const frac = bits & ((@as(u64, 1) << 52) - 1);
    if (raw_exp == 0) return .{ .mant = frac, .exp = -1074 };
    return .{ .mant = frac | (@as(u64, 1) << 52), .exp = raw_exp - 1075 };
}

/// round(x * 10^k) as decimal digits, for non-negative finite x. The caller frees the result.
pub fn scaledDigits(vm: *Vm, x: f64, k: i32) Error![]u8 {
    const gpa = vm.gpa;
    const p = decompose(x);
    var num = try Managed.initSet(gpa, p.mant);
    defer num.deinit();
    var den = try Managed.initSet(gpa, 1);
    defer den.deinit();
    var ten = try Managed.initSet(gpa, 10);
    defer ten.deinit();
    var scale = try Managed.init(gpa);
    defer scale.deinit();
    try scale.pow(&ten, @intCast(@abs(k)));
    if (k >= 0) {
        try num.mul(&num, &scale);
    } else {
        try den.mul(&den, &scale);
    }
    if (p.exp >= 0) {
        try num.shiftLeft(&num, @intCast(p.exp));
    } else {
        try den.shiftLeft(&den, @intCast(-p.exp));
    }
    var q = try Managed.init(gpa);
    defer q.deinit();
    var r = try Managed.init(gpa);
    defer r.deinit();
    try q.divTrunc(&r, &num, &den);
    try r.shiftLeft(&r, 1);
    if (r.order(den) != .lt) {
        var one = try Managed.initSet(gpa, 1);
        defer one.deinit();
        try q.add(&q, &one);
    }
    return q.toString(gpa, 10, .lower) catch error.OutOfMemory;
}

/// Digits of non-negative x with this many decimals, into b.
pub fn fixed(vm: *Vm, b: *str.Builder, x: f64, digits: usize) Error!void {
    const s = try scaledDigits(vm, x, @intCast(digits));
    defer vm.gpa.free(s);
    if (digits == 0) return b.bytes(s);
    if (s.len <= digits) {
        try b.bytes("0.");
        var i: usize = s.len;
        while (i < digits) : (i += 1) try b.byte('0');
        return b.bytes(s);
    }
    try b.bytes(s[0 .. s.len - digits]);
    try b.byte('.');
    try b.bytes(s[s.len - digits ..]);
}

pub const Sig = struct { digits: []u8, exp: i32 };

/// x > 0 rounded to p significant digits. The caller frees digits.
pub fn significant(vm: *Vm, x: f64, p: usize) Error!Sig {
    var e: i32 = @intFromFloat(@floor(std.math.log10(x)));
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        const s = try scaledDigits(vm, x, @as(i32, @intCast(p)) - 1 - e);
        if (s.len == p or tries > 3) return .{ .digits = s, .exp = e };
        e += if (s.len > p) 1 else -1;
        vm.gpa.free(s);
    }
}
