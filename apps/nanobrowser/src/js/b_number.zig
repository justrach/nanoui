//! Number, Boolean, Symbol, and the global functions: parseInt, parseFloat, isNaN,
//! isFinite, and the URI encoders.

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
const ops = @import("ops.zig");
const str = @import("string.zig");
const calls = @import("interp_call.zig");
const big = @import("b_bigint.zig");
const api = @import("vm_api.zig");
const fmt = @import("b_number_fmt.zig");

fn numberCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    var n: f64 = 0;
    if (args.len > 0) {
        const p = try ops.toNumeric(vm, args[0]);
        n = if (p.isBigInt()) big.toNumber(p) else p.asNumber();
    }
    const v = Value.fromNumber(n);
    if (vm.new_target.isUndefined()) return v;
    const o = try objmod.create(vm, try calls.protoFromNewTarget(vm, vm.protos.number), .number);
    o.payload = .{ .value = v };
    return o.value();
}

fn thisNum(vm: *Vm, this: Value) Error!f64 {
    if (this.isNumber()) return this.asNumber();
    if (this.isObject() and this.asObject().class == .number) return this.asObject().payload.value.asNumber();
    return vm.throwError(.TypeError, "Number.prototype method requires that 'this' be a Number");
}

fn radixString(vm: *Vm, d: f64, radix: u32) Error!Value {
    if (d != d) return Value.fromString(vm.k.NaN.atom());
    if (std.math.isInf(d)) return Value.fromString(if (d > 0) vm.k.Infinity.atom() else vm.k.@"-Infinity".atom());
    var buf: [1100]u8 = undefined;
    var i: usize = 540;
    var ip = std.math.floor(@abs(d));
    var fp = @abs(d) - ip;
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    const fr: f64 = @floatFromInt(radix);
    var out_int = i;
    if (ip == 0) {
        out_int -= 1;
        buf[out_int] = '0';
    }
    while (ip > 0 and out_int > 1) {
        const m = @mod(ip, fr);
        out_int -= 1;
        buf[out_int] = digits[@intFromFloat(m)];
        ip = std.math.floor(ip / fr);
    }
    if (d < 0) {
        out_int -= 1;
        buf[out_int] = '-';
    }
    if (fp > 0) {
        buf[i] = '.';
        i += 1;
        // Stops once the remaining fraction is below the double's precision at this magnitude.
        var delta = @max(0.5 * (std.math.nextAfter(f64, @abs(d), std.math.inf(f64)) - @abs(d)), std.math.floatTrueMin(f64));
        while (i < 1090) {
            fp *= fr;
            delta *= fr;
            const dg = std.math.floor(fp);
            buf[i] = digits[@intFromFloat(dg)];
            i += 1;
            fp -= dg;
            if (fp < delta) break;
            if (fp > 1 - delta) {
                // Round up, carrying back through the digits written.
                var j = i - 1;
                while (true) {
                    if (buf[j] == '.') break;
                    const v = std.mem.indexOfScalar(u8, digits, buf[j]).? + 1;
                    if (v == radix) {
                        buf[j] = '0';
                        j -= 1;
                    } else {
                        buf[j] = digits[v];
                        break;
                    }
                }
                break;
            }
        }
    }
    return api.newString(vm, buf[out_int..i]);
}

fn numToString(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const d = try thisNum(vm, this);
    var radix: f64 = 10;
    if (!u.arg(args, 0).isUndefined()) radix = try conv.toIntegerOrInf(vm, args[0]);
    if (radix < 2 or radix > 36) return vm.throwError(.RangeError, "toString() radix must be between 2 and 36");
    if (radix == 10) return Value.fromString(try conv.numberToString(vm, d));
    return radixString(vm, d, @intFromFloat(radix));
}

fn numValueOf(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return Value.fromNumber(try thisNum(vm, this));
}

fn toFixed(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const d = try thisNum(vm, this);
    const f = try conv.toIntegerOrInf(vm, u.arg(args, 0));
    if (f < 0 or f > 100) return vm.throwError(.RangeError, "toFixed() digits argument must be between 0 and 100");
    if (d != d or std.math.isInf(d) or @abs(d) >= 1e21) return Value.fromString(try conv.numberToString(vm, d));
    var b = str.Builder.init(vm);
    defer b.deinit();
    if (d < 0) try b.byte('-');
    try fmt.fixed(vm, &b, @abs(d), @intFromFloat(f));
    return Value.fromString(try b.finish());
}

fn appendExponent(b: *str.Builder, e: i32) Error!void {
    try b.byte('e');
    try b.byte(if (e < 0) '-' else '+');
    try b.print("{d}", .{@abs(e)});
}

fn expForm(vm: *Vm, d: f64, digits: usize) Error!Value {
    var b = str.Builder.init(vm);
    defer b.deinit();
    if (d < 0) try b.byte('-');
    if (d == 0) {
        try b.byte('0');
        if (digits > 0) {
            try b.byte('.');
            var i: usize = 0;
            while (i < digits) : (i += 1) try b.byte('0');
        }
        try appendExponent(&b, 0);
        return Value.fromString(try b.finish());
    }
    const s = try fmt.significant(vm, @abs(d), digits + 1);
    defer vm.gpa.free(s.digits);
    try b.byte(s.digits[0]);
    if (digits > 0) {
        try b.byte('.');
        try b.bytes(s.digits[1..]);
    }
    try appendExponent(&b, s.exp);
    return Value.fromString(try b.finish());
}

fn toExponential(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const d = try thisNum(vm, this);
    const f = try conv.toIntegerOrInf(vm, u.arg(args, 0));
    if (d != d or std.math.isInf(d)) return Value.fromString(try conv.numberToString(vm, d));
    if (f < 0 or f > 100) return vm.throwError(.RangeError, "toExponential() argument must be between 0 and 100");
    if (!u.arg(args, 0).isUndefined()) return expForm(vm, d, @intFromFloat(f));
    // No argument: as many digits as the shortest round-trip form has.
    var buf: [64]u8 = undefined;
    const sci = std.fmt.float.render(&buf, @abs(d), .{ .mode = .scientific }) catch return vm.throwError(.RangeError, "digits out of range");
    const e = std.mem.indexOfScalar(u8, sci, 'e') orelse sci.len;
    const count: usize = if (e > 1) e - 2 else 0;
    return expForm(vm, d, count);
}

fn toPrecision(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const d = try thisNum(vm, this);
    if (u.arg(args, 0).isUndefined()) return Value.fromString(try conv.numberToString(vm, d));
    const pf = try conv.toIntegerOrInf(vm, args[0]);
    if (d != d or std.math.isInf(d)) return Value.fromString(try conv.numberToString(vm, d));
    if (pf < 1 or pf > 100) return vm.throwError(.RangeError, "toPrecision() argument must be between 1 and 100");
    const p: usize = @intFromFloat(pf);
    var b = str.Builder.init(vm);
    defer b.deinit();
    if (d == 0) {
        try fmt.fixed(vm, &b, 0, p - 1);
        return Value.fromString(try b.finish());
    }
    const s = try fmt.significant(vm, @abs(d), p);
    defer vm.gpa.free(s.digits);
    if (s.exp < -6 or s.exp >= @as(i32, @intCast(p))) return expForm(vm, d, p - 1);
    if (d < 0) try b.byte('-');
    if (s.exp < 0) {
        try b.bytes("0.");
        var i: i32 = -1;
        while (i > s.exp) : (i -= 1) try b.byte('0');
        try b.bytes(s.digits);
    } else {
        const whole: usize = @intCast(s.exp + 1);
        try b.bytes(s.digits[0..whole]);
        if (whole < s.digits.len) {
            try b.byte('.');
            try b.bytes(s.digits[whole..]);
        }
    }
    return Value.fromString(try b.finish());
}

fn numIsFinite(_: *Vm, _: Value, args: []const Value) Error!Value {
    const v = u.arg(args, 0);
    return Value.fromBool(v.isNumber() and std.math.isFinite(v.asNumber()));
}
fn numIsNaN(_: *Vm, _: Value, args: []const Value) Error!Value {
    const v = u.arg(args, 0);
    return Value.fromBool(v.isDouble() and v.asDouble() != v.asDouble());
}
fn numIsInteger(_: *Vm, _: Value, args: []const Value) Error!Value {
    const v = u.arg(args, 0);
    if (!v.isNumber()) return Value.false;
    const d = v.asNumber();
    return Value.fromBool(std.math.isFinite(d) and d == std.math.trunc(d));
}
fn numIsSafe(_: *Vm, _: Value, args: []const Value) Error!Value {
    const v = u.arg(args, 0);
    if (!v.isNumber()) return Value.false;
    const d = v.asNumber();
    return Value.fromBool(std.math.isFinite(d) and d == std.math.trunc(d) and @abs(d) <= 9007199254740991.0);
}

fn globalIsNaN(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const d = try conv.toNumber(vm, u.arg(args, 0));
    return Value.fromBool(d != d);
}
fn globalIsFinite(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(std.math.isFinite(try conv.toNumber(vm, u.arg(args, 0))));
}

fn parseFloatFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const s = conv.trimJs(try (try conv.toStr(vm, u.arg(args, 0))).flat(vm), true, false);
    const n = conv.decimalPrefix(s);
    if (n == 0) return Value.nan;
    return Value.fromNumber(conv.parseDecimal(s[0..n]));
}

fn parseIntFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    var s = conv.trimJs(try (try conv.toStr(vm, u.arg(args, 0))).flat(vm), true, false);
    var neg = false;
    if (s.len != 0 and (s[0] == '+' or s[0] == '-')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    var r = try conv.toInt32(vm, u.arg(args, 1));
    var strip = true;
    if (r != 0) {
        if (r < 2 or r > 36) return Value.nan;
        if (r != 16) strip = false;
    } else r = 10;
    if (strip and s.len >= 2 and s[0] == '0' and (s[1] | 0x20) == 'x') {
        s = s[2..];
        r = 16;
    }
    const radix: u32 = @intCast(r);
    var v: f64 = 0;
    var n: usize = 0;
    for (s) |c| {
        const d: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'z' => c - 'a' + 10,
            'A'...'Z' => c - 'A' + 10,
            else => break,
        };
        if (d >= radix) break;
        v = v * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(d));
        n += 1;
    }
    if (n == 0) return Value.nan;
    // Long decimal strings lose precision accumulating; parse them exactly.
    if (radix == 10 and n > 15) v = std.fmt.parseFloat(f64, s[0..n]) catch v;
    return Value.fromNumber(if (neg) -v else v);
}

const uri_unreserved = "-_.!~*'()";
const uri_reserved = ";/?:@&=+$,";

fn encodeImpl(vm: *Vm, v: Value, keep: []const u8) Error!Value {
    const b = try (try conv.toStr(vm, v)).flat(vm);
    var out = str.Builder.init(vm);
    defer out.deinit();
    var i: usize = 0;
    while (i < b.len) {
        const c = b[i];
        if (c < 0x80) {
            if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, keep, c) != null) {
                try out.byte(c);
            } else try out.print("%{X:0>2}", .{c});
            i += 1;
            continue;
        }
        const d = str.decode(b, i);
        if (d.cp >= 0xD800 and d.cp < 0xE000) return vm.throwError(.URIError, "URI malformed");
        for (b[i..][0..d.len]) |x| try out.print("%{X:0>2}", .{x});
        i += d.len;
    }
    return Value.fromString(try out.finish());
}

fn hexVal(c: u8) ?u8 {
    return std.fmt.charToDigit(c, 16) catch null;
}

fn decodeImpl(vm: *Vm, v: Value, keep: []const u8) Error!Value {
    const b = try (try conv.toStr(vm, v)).flat(vm);
    var out = str.Builder.init(vm);
    defer out.deinit();
    var i: usize = 0;
    while (i < b.len) {
        const c = b[i];
        if (c != '%') {
            try out.byte(c);
            i += 1;
            continue;
        }
        if (i + 2 >= b.len) return vm.throwError(.URIError, "URI malformed");
        const h = hexVal(b[i + 1]) orelse return vm.throwError(.URIError, "URI malformed");
        const l = hexVal(b[i + 2]) orelse return vm.throwError(.URIError, "URI malformed");
        const first = h * 16 + l;
        if (first < 0x80) {
            if (std.mem.indexOfScalar(u8, keep, first) != null) {
                try out.bytes(b[i..][0..3]);
            } else try out.byte(first);
            i += 3;
            continue;
        }
        const n: usize = if (first >= 0xF0 and first < 0xF5) 4 else if (first >= 0xE0 and first < 0xF0) 3 else if (first >= 0xC2 and first < 0xE0) 2 else return vm.throwError(.URIError, "URI malformed");
        if (i + n * 3 > b.len) return vm.throwError(.URIError, "URI malformed");
        var tmp: [4]u8 = undefined;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const at = i + k * 3;
            if (b[at] != '%') return vm.throwError(.URIError, "URI malformed");
            const x = hexVal(b[at + 1]) orelse return vm.throwError(.URIError, "URI malformed");
            const y = hexVal(b[at + 2]) orelse return vm.throwError(.URIError, "URI malformed");
            tmp[k] = x * 16 + y;
        }
        const d = str.decode(tmp[0..n], 0);
        if (d.len != n or (d.cp >= 0xD800 and d.cp < 0xE000)) return vm.throwError(.URIError, "URI malformed");
        try out.bytes(tmp[0..n]);
        i += n * 3;
    }
    return Value.fromString(try out.finish());
}

fn encodeURIComponent(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return encodeImpl(vm, u.arg(args, 0), uri_unreserved);
}
fn encodeURI(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return encodeImpl(vm, u.arg(args, 0), uri_unreserved ++ uri_reserved ++ "#");
}
fn decodeURIComponent(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return decodeImpl(vm, u.arg(args, 0), "");
}
fn decodeURI(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return decodeImpl(vm, u.arg(args, 0), uri_reserved ++ "#");
}

fn escapeFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const s = try conv.toStr(vm, u.arg(args, 0));
    const us = try str.toUnits(vm, s);
    defer us.deinit(vm);
    var out = str.Builder.init(vm);
    defer out.deinit();
    for (us.items) |c| {
        if (c < 128 and (std.ascii.isAlphanumeric(@intCast(c)) or std.mem.indexOfScalar(u8, "@*_+-./", @intCast(c)) != null)) {
            try out.byte(@intCast(c));
        } else if (c < 256) {
            try out.print("%{X:0>2}", .{c});
        } else try out.print("%u{X:0>4}", .{c});
    }
    return Value.fromString(try out.finish());
}

fn unescapeFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const s = try conv.toStr(vm, u.arg(args, 0));
    const us = try str.toUnits(vm, s);
    defer us.deinit(vm);
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(vm.gpa);
    var i: usize = 0;
    while (i < us.items.len) {
        const c = us.items[i];
        if (c == '%') {
            const rest = us.items[i + 1 ..];
            if (rest.len >= 5 and rest[0] == 'u') {
                var v: u32 = 0;
                var ok = true;
                for (rest[1..5]) |h| {
                    const d = if (h < 128) hexVal(@intCast(h)) else null;
                    if (d == null) {
                        ok = false;
                        break;
                    }
                    v = v * 16 + d.?;
                }
                if (ok) {
                    try out.append(vm.gpa, @intCast(v));
                    i += 6;
                    continue;
                }
            }
            if (rest.len >= 2 and rest[0] < 128 and rest[1] < 128) {
                if (hexVal(@intCast(rest[0]))) |a| {
                    if (hexVal(@intCast(rest[1]))) |b| {
                        try out.append(vm.gpa, a * 16 + b);
                        i += 3;
                        continue;
                    }
                }
            }
        }
        try out.append(vm.gpa, c);
        i += 1;
    }
    return Value.fromString(try str.fromUtf16(vm, out.items));
}

fn booleanCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const b = Value.fromBool(ops.truthy(u.arg(args, 0)));
    if (vm.new_target.isUndefined()) return b;
    const o = try objmod.create(vm, try calls.protoFromNewTarget(vm, vm.protos.boolean), .boolean);
    o.payload = .{ .value = b };
    return o.value();
}

fn thisBool(vm: *Vm, this: Value) Error!Value {
    if (this.isBool()) return this;
    if (this.isObject() and this.asObject().class == .boolean) return this.asObject().payload.value;
    return vm.throwError(.TypeError, "Boolean.prototype method requires that 'this' be a Boolean");
}
fn boolToString(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return Value.fromString(try conv.toStr(vm, try thisBool(vm, this)));
}
fn boolValueOf(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return thisBool(vm, this);
}

fn symbolCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    if (!vm.new_target.isUndefined()) return vm.throwError(.TypeError, "Symbol is not a constructor");
    const d = if (u.arg(args, 0).isUndefined()) null else try conv.toStr(vm, args[0]);
    return Value.fromSymbol(try str.newSymbol(vm, d));
}

fn symbolFor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const s = try conv.toStr(vm, u.arg(args, 0));
    const b = try s.flat(vm);
    if (vm.symbol_registry.get(b)) |x| return Value.fromSymbol(x);
    const sym = try str.newSymbol(vm, s);
    sym.is_registered = true;
    const key = try vm.gpa.dupe(u8, b);
    try vm.symbol_registry.put(vm.gpa, key, sym);
    return Value.fromSymbol(sym);
}

fn symbolKeyFor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const v = u.arg(args, 0);
    if (!v.isSymbol()) return vm.throwError(.TypeError, "Symbol.keyFor requires a symbol");
    if (v.asSymbol().is_registered) return Value.fromString(v.asSymbol().description.?);
    return Value.undefined;
}

fn thisSym(vm: *Vm, this: Value) Error!*str.Symbol {
    if (this.isSymbol()) return this.asSymbol();
    if (this.isObject() and this.asObject().class == .symbol) return this.asObject().payload.value.asSymbol();
    return vm.throwError(.TypeError, "Symbol.prototype method requires that 'this' be a Symbol");
}

fn symToString(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const s = try thisSym(vm, this);
    var b = str.Builder.init(vm);
    defer b.deinit();
    try b.bytes("Symbol(");
    if (s.description) |d| try b.str(d);
    try b.byte(')');
    return Value.fromString(try b.finish());
}
fn symValueOf(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return Value.fromSymbol(try thisSym(vm, this));
}
fn symDescription(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const s = try thisSym(vm, this);
    return if (s.description) |d| Value.fromString(d) else Value.undefined;
}

pub fn init(vm: *Vm) Error!void {
    const g = vm.global_obj;
    const np = vm.protos.number;
    const nc = try u.ctor(vm, "Number", 1, numberCtor, np);
    try u.method(vm, np, "toString", 1, numToString);
    try u.method(vm, np, "toLocaleString", 0, @import("b_intl.zig").numberToLocale);
    try u.method(vm, np, "valueOf", 0, numValueOf);
    try u.method(vm, np, "toFixed", 1, toFixed);
    try u.method(vm, np, "toExponential", 1, toExponential);
    try u.method(vm, np, "toPrecision", 1, toPrecision);
    try u.constant(vm, nc, "MAX_SAFE_INTEGER", Value.fromNumber(9007199254740991.0));
    try u.constant(vm, nc, "MIN_SAFE_INTEGER", Value.fromNumber(-9007199254740991.0));
    try u.constant(vm, nc, "MAX_VALUE", Value.fromDouble(std.math.floatMax(f64)));
    try u.constant(vm, nc, "MIN_VALUE", Value.fromDouble(std.math.floatTrueMin(f64)));
    try u.constant(vm, nc, "EPSILON", Value.fromDouble(std.math.floatEps(f64)));
    try u.constant(vm, nc, "POSITIVE_INFINITY", Value.fromDouble(std.math.inf(f64)));
    try u.constant(vm, nc, "NEGATIVE_INFINITY", Value.fromDouble(-std.math.inf(f64)));
    try u.constant(vm, nc, "NaN", Value.nan);
    try u.method(vm, nc, "isFinite", 1, numIsFinite);
    try u.method(vm, nc, "isNaN", 1, numIsNaN);
    try u.method(vm, nc, "isInteger", 1, numIsInteger);
    try u.method(vm, nc, "isSafeInteger", 1, numIsSafe);
    try u.method(vm, g, "parseFloat", 1, parseFloatFn);
    try u.method(vm, g, "parseInt", 2, parseIntFn);
    try u.data(vm, nc, "parseFloat", try props.get(vm, g, try str.keyFromBytes(vm, "parseFloat")));
    try u.data(vm, nc, "parseInt", try props.get(vm, g, try str.keyFromBytes(vm, "parseInt")));
    try u.method(vm, g, "isNaN", 1, globalIsNaN);
    try u.method(vm, g, "isFinite", 1, globalIsFinite);
    try u.method(vm, g, "encodeURIComponent", 1, encodeURIComponent);
    try u.method(vm, g, "encodeURI", 1, encodeURI);
    try u.method(vm, g, "decodeURIComponent", 1, decodeURIComponent);
    try u.method(vm, g, "decodeURI", 1, decodeURI);
    try u.method(vm, g, "escape", 1, escapeFn);
    try u.method(vm, g, "unescape", 1, unescapeFn);
    try u.constant(vm, g, "NaN", Value.nan);
    try u.constant(vm, g, "Infinity", Value.fromDouble(std.math.inf(f64)));
    try u.constant(vm, g, "undefined", Value.undefined);
    try u.data(vm, g, "globalThis", g.value());

    const bp = vm.protos.boolean;
    _ = try u.ctor(vm, "Boolean", 1, booleanCtor, bp);
    try u.method(vm, bp, "toString", 0, boolToString);
    try u.method(vm, bp, "valueOf", 0, boolValueOf);

    const sp = vm.protos.symbol;
    const sc = try u.ctor(vm, "Symbol", 0, symbolCtor, sp);
    sc.flags.constructor = true;
    try u.method(vm, sc, "for", 1, symbolFor);
    try u.method(vm, sc, "keyFor", 1, symbolKeyFor);
    try u.method(vm, sp, "toString", 0, symToString);
    try u.method(vm, sp, "valueOf", 0, symValueOf);
    try u.symMethod(vm, sp, vm.sym.toPrimitive, "[Symbol.toPrimitive]", 1, symValueOf);
    try u.toStringTag(vm, sp, "Symbol");
    try u.getter(vm, sp, "description", symDescription);
    inline for (@typeInfo(vm_mod.WellKnown).@"struct".field_names) |n| {
        try u.constant(vm, sc, n, Value.fromSymbol(@field(vm.sym, n)));
    }
}
