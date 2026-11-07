//! Abstract type conversions: ToPrimitive, ToNumber, ToString, ToObject, ToPropertyKey
//! and the integer forms, plus number formatting and parsing.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const value = @import("value.zig");
const Value = value.Value;
const PropKey = value.PropKey;
const objmod = @import("object.zig");
const Object = objmod.Object;
const props = @import("props.zig");
const str = @import("string.zig");
const JSString = str.JSString;
const calls = @import("interp_call.zig");
const big = @import("b_bigint.zig");
const lexer = @import("lexer.zig");

/// Nanoseconds from an arbitrary origin, for deadlines.
pub fn monotonicNs() u64 {
    const threaded = std.Io.Threaded.global_single_threaded;
    const ts = std.Io.Clock.now(.awake, threaded.io());
    return @intCast(ts.nanoseconds);
}

pub fn realtimeMs() f64 {
    const threaded = std.Io.Threaded.global_single_threaded;
    const ts = std.Io.Clock.now(.real, threaded.io());
    return @floatFromInt(ts.toMilliseconds());
}

pub fn typeName(v: Value) []const u8 {
    if (v.isUndefined()) return "undefined";
    if (v.isNull()) return "null";
    if (v.isBool()) return "boolean";
    if (v.isNumber()) return "number";
    if (v.isString()) return "string";
    if (v.isSymbol()) return "symbol";
    if (v.isBigInt()) return "bigint";
    return if (v.isCallable()) "function" else "object";
}

pub const Hint = enum { default, number, string };

pub fn toPrimitive(vm: *Vm, v: Value, hint: Hint) Error!Value {
    if (!v.isObject()) return v;
    const o = v.asObject();
    const ex = try props.get(vm, o, PropKey.fromSymbol(vm.sym.toPrimitive));
    if (!ex.isNullish()) {
        if (!ex.isCallable()) return vm.throwError(.TypeError, "Symbol.toPrimitive is not a function");
        const hv: Value = switch (hint) {
            .default => Value.fromString(vm.k.default.atom()),
            .number => Value.fromString(vm.k.number.atom()),
            .string => Value.fromString(vm.k.string.atom()),
        };
        const r = try calls.call(vm, ex, v, &.{hv});
        if (r.isObject()) return vm.throwError(.TypeError, "Cannot convert object to primitive value");
        return r;
    }
    const first = if (hint == .string) vm.k.toString else vm.k.valueOf;
    const second = if (hint == .string) vm.k.valueOf else vm.k.toString;
    for ([_]PropKey{ first, second }) |k| {
        const m = try props.get(vm, o, k);
        if (m.isCallable()) {
            const r = try calls.call(vm, m, v, &.{});
            if (!r.isObject()) return r;
        }
    }
    return vm.throwError(.TypeError, "Cannot convert object to primitive value");
}

pub fn toNumber(vm: *Vm, v: Value) Error!f64 {
    if (v.isInt()) return @floatFromInt(v.asInt());
    if (v.isDouble()) return v.asDouble();
    if (v.isUndefined()) return std.math.nan(f64);
    if (v.isNull()) return 0;
    if (v.isBool()) return if (v.asBool()) 1 else 0;
    if (v.isString()) return stringToNumber(try v.asString().flat(vm));
    if (v.isSymbol()) return vm.throwError(.TypeError, "Cannot convert a Symbol value to a number");
    if (v.isBigInt()) return vm.throwError(.TypeError, "Cannot convert a BigInt value to a number");
    return toNumber(vm, try toPrimitive(vm, v, .number));
}

fn isWs(cp: u32) bool {
    return lexer.isSpaceCp(cp) or lexer.isLineCp(cp);
}

/// Trims JS whitespace from both ends.
pub fn trimJs(s: []const u8, start: bool, end: bool) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    if (start) {
        while (a < b) {
            const d = str.decode(s, a);
            if (!isWs(d.cp)) break;
            a += d.len;
        }
    }
    if (end) {
        while (b > a) {
            var i = b - 1;
            while (i > a and s[i] & 0xC0 == 0x80) i -= 1;
            const d = str.decode(s, i);
            if (!isWs(d.cp)) break;
            b = i;
        }
    }
    return s[a..b];
}

fn radixValue(s: []const u8, radix: u32) f64 {
    if (s.len == 0) return std.math.nan(f64);
    var v: f64 = 0;
    for (s) |c| {
        const d: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'z' => c - 'a' + 10,
            'A'...'Z' => c - 'A' + 10,
            else => return std.math.nan(f64),
        };
        if (d >= radix) return std.math.nan(f64);
        v = v * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(d));
    }
    return v;
}

/// Checks the StrDecimalLiteral grammar; std's parser accepts more than JS does.
pub fn decimalPrefix(s: []const u8) usize {
    var i: usize = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    if (std.mem.startsWith(u8, s[i..], "Infinity")) return i + 8;
    const start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    var digits = i - start;
    if (i < s.len and s[i] == '.') {
        const dot = i;
        i += 1;
        const fs = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        digits += i - fs;
        if (digits == 0) return dot - dot;
    }
    if (digits == 0) return 0;
    if (i < s.len and (s[i] | 0x20) == 'e') {
        var j = i + 1;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
        const es = j;
        while (j < s.len and s[j] >= '0' and s[j] <= '9') j += 1;
        if (j > es) i = j;
    }
    return i;
}

pub fn parseDecimal(s: []const u8) f64 {
    var t = s;
    var neg = false;
    if (t.len != 0 and (t[0] == '+' or t[0] == '-')) {
        neg = t[0] == '-';
        t = t[1..];
    }
    var r: f64 = undefined;
    if (std.mem.eql(u8, t, "Infinity")) {
        r = std.math.inf(f64);
    } else {
        r = std.fmt.parseFloat(f64, t) catch std.math.nan(f64);
    }
    return if (neg) -r else r;
}

pub fn stringToNumber(s0: []const u8) f64 {
    const s = trimJs(s0, true, true);
    if (s.len == 0) return 0;
    if (s.len > 2 and s[0] == '0') {
        const radix: u32 = switch (s[1] | 0x20) {
            'x' => 16,
            'o' => 8,
            'b' => 2,
            else => 0,
        };
        if (radix != 0) return radixValue(s[2..], radix);
    }
    if (decimalPrefix(s) != s.len) return std.math.nan(f64);
    return parseDecimal(s);
}

pub fn toIntegerOrInf(vm: *Vm, v: Value) Error!f64 {
    if (v.isInt()) return @floatFromInt(v.asInt());
    const n = try toNumber(vm, v);
    if (n != n) return 0;
    if (std.math.isInf(n)) return n;
    const t = std.math.trunc(n);
    return if (t == 0) 0 else t;
}

/// ToInt32 of a double: modular wrap per spec.
pub fn doubleToInt32(d: f64) i32 {
    if (d >= -2147483648.0 and d <= 2147483647.0) return @intFromFloat(d);
    if (d != d or std.math.isInf(d)) return 0;
    const m = @mod(std.math.trunc(d), 4294967296.0);
    return @bitCast(@as(u32, @intFromFloat(m)));
}

pub fn toInt32(vm: *Vm, v: Value) Error!i32 {
    if (v.isInt()) return v.asInt();
    return doubleToInt32(try toNumber(vm, v));
}

pub fn toUint32(vm: *Vm, v: Value) Error!u32 {
    return @bitCast(try toInt32(vm, v));
}

pub fn toLength(vm: *Vm, v: Value) Error!usize {
    const n = try toIntegerOrInf(vm, v);
    if (n <= 0) return 0;
    return @intFromFloat(@min(n, 9007199254740991.0));
}

pub fn toIndex(vm: *Vm, v: Value) Error!usize {
    if (v.isUndefined()) return 0;
    const n = try toIntegerOrInf(vm, v);
    if (n < 0 or n > 9007199254740991.0) return vm.throwError(.RangeError, "Invalid index");
    return @intFromFloat(n);
}

/// length of an array-like.
pub fn lengthOf(vm: *Vm, o: *Object) Error!usize {
    if (o.class == .array) return o.arr_len;
    return toLength(vm, try props.get(vm, o, vm.k.length));
}

/// Formats a double per Number::toString (radix 10).
pub fn formatNumber(d: f64, buf: []u8) []const u8 {
    if (d != d) return "NaN";
    if (d == 0) return "0";
    if (std.math.isInf(d)) return if (d > 0) "Infinity" else "-Infinity";
    var w = std.ArrayList(u8).initBuffer(buf);
    var a = @abs(d);
    if (d < 0) w.appendAssumeCapacity('-');
    if (a < 1e21 and a == std.math.trunc(a) and a < 9007199254740992.0) {
        var t: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&t, "{d}", .{@as(u64, @intFromFloat(a))}) catch unreachable;
        w.appendSliceAssumeCapacity(s);
        return w.items;
    }
    a = @abs(d);
    var t: [64]u8 = undefined;
    const sci = std.fmt.float.render(&t, a, .{ .mode = .scientific }) catch unreachable;
    // sci looks like d.ddde[-]x
    const e_at = std.mem.indexOfScalar(u8, sci, 'e').?;
    const exp = std.fmt.parseInt(i32, sci[e_at + 1 ..], 10) catch 0;
    var digits: [32]u8 = undefined;
    var nd: usize = 0;
    for (sci[0..e_at]) |c| {
        if (c != '.') {
            digits[nd] = c;
            nd += 1;
        }
    }
    const n: i32 = exp + 1;
    const k: i32 = @intCast(nd);
    if (k <= n and n <= 21) {
        w.appendSliceAssumeCapacity(digits[0..nd]);
        var i: i32 = 0;
        while (i < n - k) : (i += 1) w.appendAssumeCapacity('0');
    } else if (0 < n and n <= 21) {
        const nu: usize = @intCast(n);
        w.appendSliceAssumeCapacity(digits[0..nu]);
        w.appendAssumeCapacity('.');
        w.appendSliceAssumeCapacity(digits[nu..nd]);
    } else if (-6 < n and n <= 0) {
        w.appendSliceAssumeCapacity("0.");
        var i: i32 = 0;
        while (i < -n) : (i += 1) w.appendAssumeCapacity('0');
        w.appendSliceAssumeCapacity(digits[0..nd]);
    } else {
        w.appendAssumeCapacity(digits[0]);
        if (nd > 1) {
            w.appendAssumeCapacity('.');
            w.appendSliceAssumeCapacity(digits[1..nd]);
        }
        w.appendAssumeCapacity('e');
        w.appendAssumeCapacity(if (n - 1 >= 0) '+' else '-');
        var eb: [8]u8 = undefined;
        const es = std.fmt.bufPrint(&eb, "{d}", .{@abs(n - 1)}) catch unreachable;
        w.appendSliceAssumeCapacity(es);
    }
    return w.items;
}

pub fn numberToString(vm: *Vm, d: f64) Error!*JSString {
    var buf: [64]u8 = undefined;
    return str.fromUtf8(vm, formatNumber(d, &buf));
}

pub fn toStr(vm: *Vm, v: Value) Error!*JSString {
    if (v.isString()) return v.asString();
    if (v.isInt()) {
        var buf: [16]u8 = undefined;
        const i = v.asInt();
        if (i >= 0 and i < 10) return vm.char_strs['0' + @as(usize, @intCast(i))];
        return str.fromUtf8(vm, std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
    }
    if (v.isDouble()) return numberToString(vm, v.asDouble());
    if (v.isUndefined()) return vm.k.undefined.atom();
    if (v.isNull()) return vm.k.null.atom();
    if (v.isBool()) return if (v.asBool()) vm.k.true.atom() else vm.k.false.atom();
    if (v.isSymbol()) return vm.throwError(.TypeError, "Cannot convert a Symbol value to a string");
    if (v.isBigInt()) return big.toStringRadix(vm, v, 10);
    return toStr(vm, try toPrimitive(vm, v, .string));
}

pub fn toPropKey(vm: *Vm, v: Value) Error!PropKey {
    if (v.isInt()) {
        if (v.asInt() >= 0) return PropKey.fromIndex(@intCast(v.asInt()));
    } else if (v.isString()) {
        return str.toKey(vm, v.asString());
    } else if (v.isSymbol()) {
        return PropKey.fromSymbol(v.asSymbol());
    } else if (v.isDouble()) {
        const d = v.asDouble();
        if (d >= 0 and d < 4294967295.0 and d == std.math.trunc(d)) {
            return PropKey.fromIndex(@intFromFloat(d));
        }
    }
    const p = try toPrimitive(vm, v, .string);
    if (p.isSymbol()) return PropKey.fromSymbol(p.asSymbol());
    return str.toKey(vm, try toStr(vm, p));
}

pub fn toObject(vm: *Vm, v: Value) Error!*Object {
    if (v.isObject()) return v.asObject();
    if (v.isNullish()) return vm.throwError(.TypeError, "Cannot convert undefined or null to object");
    const class: objmod.Class = if (v.isString()) .string else if (v.isNumber()) .number else if (v.isBool()) .boolean else if (v.isSymbol()) .symbol else .bigint;
    const proto = switch (class) {
        .string => vm.protos.string,
        .number => vm.protos.number,
        .boolean => vm.protos.boolean,
        .symbol => vm.protos.symbol,
        else => vm.protos.bigint,
    };
    const o = if (class == .string) try objmod.createExotic(vm, proto, class) else try objmod.create(vm, proto, class);
    o.payload = .{ .value = v };
    return o;
}

pub fn sameValue(vm: *Vm, a: Value, b: Value) bool {
    if (a.isNumber() and b.isNumber()) {
        const x = a.asNumber();
        const y = b.asNumber();
        if (x != x and y != y) return true;
        if (x == 0 and y == 0) return std.math.signbit(x) == std.math.signbit(y);
        return x == y;
    }
    return sameValueNonNumber(vm, a, b);
}

pub fn sameValueZero(vm: *Vm, a: Value, b: Value) bool {
    if (a.isNumber() and b.isNumber()) {
        const x = a.asNumber();
        const y = b.asNumber();
        if (x != x and y != y) return true;
        return x == y;
    }
    return sameValueNonNumber(vm, a, b);
}

fn sameValueNonNumber(vm: *Vm, a: Value, b: Value) bool {
    if (a.bits == b.bits) return true;
    if (a.isString() and b.isString()) return str.eql(vm, a.asString(), b.asString()) catch false;
    if (a.isBigInt() and b.isBigInt()) return big.equal(a, b);
    return false;
}
