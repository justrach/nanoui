//! Date: time arithmetic, the constructor, getters, setters and formatting. Local time
//! comes from the host's offset hook (vm.tz_offset_fn), UTC if there is none. Parsing
//! is in b_date_parse.zig.

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
const calls = @import("interp_call.zig");
const parser = @import("b_date_parse.zig");
const api = @import("vm_api.zig");

pub const ms_per_day: f64 = 86400000;
const nan = std.math.nan(f64);

pub fn daysFromCivil(y0: f64, m: f64, d: f64) f64 {
    // Howard Hinnant's algorithm, in doubles to cover the whole Date range.
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @floor(y / 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @floor((153 * mp + 2) / 5) + d - 1;
    const doe = yoe * 365 + @floor(yoe / 4) - @floor(yoe / 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { year: f64, month: u32, day: u32 };

pub fn civilFromDays(z0: f64) Civil {
    const z = z0 + 719468;
    const era = @floor(z / 146097);
    const doe = z - era * 146097;
    const yoe = @floor((doe - @floor(doe / 1460) + @floor(doe / 36524) - @floor(doe / 146096)) / 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @floor(yoe / 4) - @floor(yoe / 100));
    const mp = @floor((5 * doy + 2) / 153);
    const d = doy - @floor((153 * mp + 2) / 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = if (m <= 2) y + 1 else y, .month = @intFromFloat(m), .day = @intFromFloat(d) };
}

/// MakeDay with month overflow: month is zero-based and may be out of range.
pub fn makeDay(year: f64, month: f64, day: f64) f64 {
    if (!std.math.isFinite(year) or !std.math.isFinite(month) or !std.math.isFinite(day)) return nan;
    const y = @trunc(year);
    const m = @trunc(month);
    const ym = y + @floor(m / 12);
    const mn = @mod(m, 12);
    return daysFromCivil(ym, mn + 1, 1) + @trunc(day) - 1;
}

pub fn makeTime(h: f64, m: f64, s: f64, ms: f64) f64 {
    if (!std.math.isFinite(h) or !std.math.isFinite(m) or !std.math.isFinite(s) or !std.math.isFinite(ms)) return nan;
    return @trunc(h) * 3600000 + @trunc(m) * 60000 + @trunc(s) * 1000 + @trunc(ms);
}

pub fn makeDate(day: f64, time: f64) f64 {
    const r = day * ms_per_day + time;
    return if (std.math.isFinite(r)) r else nan;
}

pub fn timeClip(t: f64) f64 {
    if (!std.math.isFinite(t) or @abs(t) > 8.64e15) return nan;
    return @trunc(t) + 0;
}

/// Minutes east of UTC at this UTC time.
fn offsetMinutes(vm: *Vm, utc_ms: f64) f64 {
    if (vm.tz_offset_fn) |f| return f(utc_ms);
    return 0;
}

pub fn localToUtc(vm: *Vm, t: f64) f64 {
    if (t != t) return t;
    return t - offsetMinutes(vm, t) * 60000;
}

fn utcToLocal(vm: *Vm, t: f64) f64 {
    if (t != t) return t;
    return t + offsetMinutes(vm, t) * 60000;
}

const Fields = struct { year: f64, month: u32, day: u32, hour: u32, min: u32, sec: u32, ms: u32, weekday: u32 };

fn fields(t: f64) Fields {
    const day = @floor(t / ms_per_day);
    const time = t - day * ms_per_day;
    const c = civilFromDays(day);
    const ti: u64 = @intFromFloat(time);
    return .{
        .year = c.year,
        .month = c.month - 1,
        .day = c.day,
        .hour = @intCast(ti / 3600000),
        .min = @intCast(ti / 60000 % 60),
        .sec = @intCast(ti / 1000 % 60),
        .ms = @intCast(ti % 1000),
        .weekday = @intFromFloat(@mod(day + 4, 7)),
    };
}

fn newDate(vm: *Vm, proto: *Object, t: f64) Error!Value {
    const o = try objmod.create(vm, proto, .date);
    o.payload = .{ .number = t };
    return o.value();
}

fn thisTime(vm: *Vm, this: Value) Error!*Object {
    if (this.isObject() and this.asObject().class == .date) return this.asObject();
    return vm.throwError(.TypeError, "this is not a Date object.");
}

const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn appendYear(b: *str.Builder, y: f64) Error!void {
    const v: i64 = @intFromFloat(y);
    if (v < 0) {
        try b.print("-{d:0>6}", .{@as(u64, @intCast(-v))});
    } else {
        try b.print("{d:0>4}", .{@as(u64, @intCast(v))});
    }
}

fn dateString(vm: *Vm, t: f64) Error!Value {
    var b = str.Builder.init(vm);
    defer b.deinit();
    const f = fields(utcToLocal(vm, t));
    try b.print("{s} {s} {d:0>2} ", .{ day_names[f.weekday], month_names[f.month], f.day });
    try appendYear(&b, f.year);
    return Value.fromString(try b.finish());
}

fn appendTime(vm: *Vm, b: *str.Builder, t: f64) Error!void {
    const f = fields(utcToLocal(vm, t));
    try b.print("{d:0>2}:{d:0>2}:{d:0>2} GMT", .{ f.hour, f.min, f.sec });
    const off: i64 = @intFromFloat(offsetMinutes(vm, t));
    const a = @abs(off);
    try b.print("{c}{d:0>2}{d:0>2}", .{ @as(u8, if (off < 0) '-' else '+'), a / 60, a % 60 });
    try b.bytes(if (off == 0) " (Coordinated Universal Time)" else " (Local Time)");
}

fn fullString(vm: *Vm, t: f64) Error!Value {
    if (t != t) return api.newString(vm, "Invalid Date");
    var b = str.Builder.init(vm);
    defer b.deinit();
    try b.str((try dateString(vm, t)).asString());
    try b.byte(' ');
    try appendTime(vm, &b, t);
    return Value.fromString(try b.finish());
}

pub fn isoString(vm: *Vm, t: f64) Error!Value {
    var b = str.Builder.init(vm);
    defer b.deinit();
    const f = fields(t);
    const y: i64 = @intFromFloat(f.year);
    if (y >= 0 and y <= 9999) {
        try b.print("{d:0>4}", .{@as(u64, @intCast(y))});
    } else {
        try b.print("{c}{d:0>6}", .{ @as(u8, if (y < 0) '-' else '+'), @abs(y) });
    }
    try b.print("-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ f.month + 1, f.day, f.hour, f.min, f.sec, f.ms });
    return Value.fromString(try b.finish());
}

fn dateCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    if (vm.new_target.isUndefined()) return fullString(vm, conv.realtimeMs());
    const proto = try calls.protoFromNewTarget(vm, vm.protos.date);
    if (args.len == 0) return newDate(vm, proto, conv.realtimeMs());
    if (args.len == 1) {
        const a = args[0];
        if (a.isObject() and a.asObject().class == .date) return newDate(vm, proto, a.asObject().payload.number);
        const p = try conv.toPrimitive(vm, a, .default);
        if (p.isString()) return newDate(vm, proto, parser.parse(vm, try p.asString().flat(vm)));
        return newDate(vm, proto, timeClip(try conv.toNumber(vm, p)));
    }
    return newDate(vm, proto, timeClip(localToUtc(vm, try fromComponents(vm, args))));
}

fn fromComponents(vm: *Vm, args: []const Value) Error!f64 {
    var c = [_]f64{ nan, 0, 1, 0, 0, 0, 0 };
    for (args[0..@min(args.len, 7)], 0..) |a, i| c[i] = try conv.toNumber(vm, a);
    if (c[0] == c[0]) {
        const yi = @trunc(c[0]);
        if (yi >= 0 and yi <= 99) c[0] = 1900 + yi;
    }
    return makeDate(makeDay(c[0], c[1], c[2]), makeTime(c[3], c[4], c[5], c[6]));
}

fn utcFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(timeClip(try fromComponents(vm, args)));
}
fn nowFn(_: *Vm, _: Value, _: []const Value) Error!Value {
    return Value.fromNumber(conv.realtimeMs());
}
fn parseFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(parser.parse(vm, try (try conv.toStr(vm, u.arg(args, 0))).flat(vm)));
}

const Field = enum { year, month, date, day, hours, minutes, seconds, ms };

fn getter(comptime field: Field, comptime utc: bool) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, _: []const Value) Error!Value {
            const t = (try thisTime(vm, this)).payload.number;
            if (t != t) return Value.nan;
            const x = fields(if (utc) t else utcToLocal(vm, t));
            return switch (field) {
                .year => Value.fromNumber(x.year),
                .month => Value.fromInt(@intCast(x.month)),
                .date => Value.fromInt(@intCast(x.day)),
                .day => Value.fromInt(@intCast(x.weekday)),
                .hours => Value.fromInt(@intCast(x.hour)),
                .minutes => Value.fromInt(@intCast(x.min)),
                .seconds => Value.fromInt(@intCast(x.sec)),
                .ms => Value.fromInt(@intCast(x.ms)),
            };
        }
    }.f;
}

/// setHours(h, m, s, ms) and friends: later components are optional and keep their values.
fn setter(comptime field: Field, comptime utc: bool) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, args: []const Value) Error!Value {
            const o = try thisTime(vm, this);
            var nums: [4]f64 = undefined;
            const nargs = @min(args.len, 4);
            for (args[0..nargs], 0..) |a, i| nums[i] = try conv.toNumber(vm, a);
            if (nargs == 0) {
                nums[0] = nan;
            }
            const count = @max(nargs, 1);
            var t = o.payload.number;
            if (t != t) {
                if (field != .year) return Value.nan;
                t = 0;
            } else if (!utc) t = utcToLocal(vm, t);
            const x = fields(t);
            var c = [_]f64{ x.year, @floatFromInt(x.month), @floatFromInt(x.day), @floatFromInt(x.hour), @floatFromInt(x.min), @floatFromInt(x.sec), @floatFromInt(x.ms) };
            const first: usize = switch (field) {
                .year => 0,
                .month => 1,
                .date => 2,
                .hours => 3,
                .minutes => 4,
                .seconds => 5,
                .ms => 6,
                .day => unreachable,
            };
            const limit: usize = switch (field) {
                .year => 3,
                .month => 2,
                .date => 1,
                .hours => 4,
                .minutes => 3,
                .seconds => 2,
                .ms => 1,
                .day => unreachable,
            };
            for (nums[0..@min(count, limit)], 0..) |n, i| c[first + i] = n;
            const nt = makeDate(makeDay(c[0], c[1], c[2]), makeTime(c[3], c[4], c[5], c[6]));
            o.payload = .{ .number = timeClip(if (utc) nt else localToUtc(vm, nt)) };
            return Value.fromNumber(o.payload.number);
        }
    }.f;
}

fn getTime(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return Value.fromNumber((try thisTime(vm, this)).payload.number);
}
fn setTime(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisTime(vm, this);
    o.payload = .{ .number = timeClip(try conv.toNumber(vm, u.arg(args, 0))) };
    return Value.fromNumber(o.payload.number);
}
fn getTimezoneOffset(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const t = (try thisTime(vm, this)).payload.number;
    if (t != t) return Value.nan;
    return Value.fromNumber(-offsetMinutes(vm, t));
}
fn getYear(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const t = (try thisTime(vm, this)).payload.number;
    if (t != t) return Value.nan;
    return Value.fromNumber(fields(utcToLocal(vm, t)).year - 1900);
}
fn setYear(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const y = try conv.toNumber(vm, u.arg(args, 0));
    if (y != y) {
        (try thisTime(vm, this)).payload = .{ .number = nan };
        return Value.nan;
    }
    const yi = @trunc(y);
    return setter(.year, false)(vm, this, &.{Value.fromNumber(if (yi >= 0 and yi <= 99) 1900 + yi else yi)});
}

fn toStringFn(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return fullString(vm, (try thisTime(vm, this)).payload.number);
}
fn toDateString(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const t = (try thisTime(vm, this)).payload.number;
    if (t != t) return api.newString(vm, "Invalid Date");
    return dateString(vm, t);
}
fn toTimeString(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const t = (try thisTime(vm, this)).payload.number;
    if (t != t) return api.newString(vm, "Invalid Date");
    var b = str.Builder.init(vm);
    defer b.deinit();
    try appendTime(vm, &b, t);
    return Value.fromString(try b.finish());
}
fn toISOString(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const t = (try thisTime(vm, this)).payload.number;
    if (t != t) return vm.throwError(.RangeError, "Invalid time value");
    return isoString(vm, t);
}
fn toUTCString(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const t = (try thisTime(vm, this)).payload.number;
    if (t != t) return api.newString(vm, "Invalid Date");
    var b = str.Builder.init(vm);
    defer b.deinit();
    const f = fields(t);
    try b.print("{s}, {d:0>2} {s} ", .{ day_names[f.weekday], f.day, month_names[f.month] });
    try appendYear(&b, f.year);
    try b.print(" {d:0>2}:{d:0>2}:{d:0>2} GMT", .{ f.hour, f.min, f.sec });
    return Value.fromString(try b.finish());
}
fn toJSON(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const o = try conv.toObject(vm, this);
    const tv = try conv.toPrimitive(vm, o.value(), .number);
    if (tv.isNumber() and !std.math.isFinite(tv.asNumber())) return Value.null;
    const f = try props.get(vm, o, try str.keyFromBytes(vm, "toISOString"));
    return calls.call(vm, f, o.value(), &.{});
}
pub fn localeDate(vm: *Vm, t: f64) Error!Value {
    if (t != t) return api.newString(vm, "Invalid Date");
    const f = fields(utcToLocal(vm, t));
    var b = str.Builder.init(vm);
    defer b.deinit();
    try b.print("{d}/{d}/{d}", .{ f.month + 1, f.day, @as(i64, @intFromFloat(f.year)) });
    return Value.fromString(try b.finish());
}
pub fn localeTime(vm: *Vm, t: f64) Error!Value {
    if (t != t) return api.newString(vm, "Invalid Date");
    const f = fields(utcToLocal(vm, t));
    var b = str.Builder.init(vm);
    defer b.deinit();
    const h = if (f.hour % 12 == 0) 12 else f.hour % 12;
    try b.print("{d}:{d:0>2}:{d:0>2} {s}", .{ h, f.min, f.sec, if (f.hour < 12) "AM" else "PM" });
    return Value.fromString(try b.finish());
}
fn toLocaleDateString(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return localeDate(vm, (try thisTime(vm, this)).payload.number);
}
fn toLocaleTimeString(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return localeTime(vm, (try thisTime(vm, this)).payload.number);
}
pub fn localeBoth(vm: *Vm, t: f64) Error!Value {
    if (t != t) return api.newString(vm, "Invalid Date");
    const a = (try localeDate(vm, t)).asString();
    const b = (try localeTime(vm, t)).asString();
    const sep = try str.fromUtf8(vm, ", ");
    return Value.fromString(try str.concat(vm, try str.concat(vm, a, sep), b));
}
fn toLocaleString(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return localeBoth(vm, (try thisTime(vm, this)).payload.number);
}
fn toPrimitiveFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    if (!this.isObject()) return vm.throwError(.TypeError, "Date.prototype[Symbol.toPrimitive] called on non-object");
    const h = u.arg(args, 0);
    if (!h.isString()) return vm.throwError(.TypeError, "Invalid hint");
    const hb = try h.asString().flat(vm);
    const number = std.mem.eql(u8, hb, "number");
    if (!number and !std.mem.eql(u8, hb, "string") and !std.mem.eql(u8, hb, "default")) return vm.throwError(.TypeError, "Invalid hint");
    const first = if (number) vm.k.valueOf else vm.k.toString;
    const second = if (number) vm.k.toString else vm.k.valueOf;
    for ([_]PropKey{ first, second }) |k| {
        const m = try props.get(vm, this.asObject(), k);
        if (m.isCallable()) {
            const r = try calls.call(vm, m, this, &.{});
            if (!r.isObject()) return r;
        }
    }
    return vm.throwError(.TypeError, "Cannot convert object to primitive value");
}

pub fn init(vm: *Vm) Error!void {
    const p = try u.newProto(vm, vm.protos.object);
    vm.protos.date = p;
    const c = try u.ctor(vm, "Date", 7, dateCtor, p);
    try u.method(vm, c, "UTC", 7, utcFn);
    try u.method(vm, c, "now", 0, nowFn);
    try u.method(vm, c, "parse", 1, parseFn);
    try u.method(vm, p, "getTime", 0, getTime);
    try u.method(vm, p, "valueOf", 0, getTime);
    try u.method(vm, p, "setTime", 1, setTime);
    try u.method(vm, p, "getTimezoneOffset", 0, getTimezoneOffset);
    try u.method(vm, p, "getYear", 0, getYear);
    try u.method(vm, p, "setYear", 1, setYear);
    try u.method(vm, p, "getFullYear", 0, getter(.year, false));
    try u.method(vm, p, "getMonth", 0, getter(.month, false));
    try u.method(vm, p, "getDate", 0, getter(.date, false));
    try u.method(vm, p, "getDay", 0, getter(.day, false));
    try u.method(vm, p, "getHours", 0, getter(.hours, false));
    try u.method(vm, p, "getMinutes", 0, getter(.minutes, false));
    try u.method(vm, p, "getSeconds", 0, getter(.seconds, false));
    try u.method(vm, p, "getMilliseconds", 0, getter(.ms, false));
    try u.method(vm, p, "getUTCFullYear", 0, getter(.year, true));
    try u.method(vm, p, "getUTCMonth", 0, getter(.month, true));
    try u.method(vm, p, "getUTCDate", 0, getter(.date, true));
    try u.method(vm, p, "getUTCDay", 0, getter(.day, true));
    try u.method(vm, p, "getUTCHours", 0, getter(.hours, true));
    try u.method(vm, p, "getUTCMinutes", 0, getter(.minutes, true));
    try u.method(vm, p, "getUTCSeconds", 0, getter(.seconds, true));
    try u.method(vm, p, "getUTCMilliseconds", 0, getter(.ms, true));
    try u.method(vm, p, "setFullYear", 3, setter(.year, false));
    try u.method(vm, p, "setMonth", 2, setter(.month, false));
    try u.method(vm, p, "setDate", 1, setter(.date, false));
    try u.method(vm, p, "setHours", 4, setter(.hours, false));
    try u.method(vm, p, "setMinutes", 3, setter(.minutes, false));
    try u.method(vm, p, "setSeconds", 2, setter(.seconds, false));
    try u.method(vm, p, "setMilliseconds", 1, setter(.ms, false));
    try u.method(vm, p, "setUTCFullYear", 3, setter(.year, true));
    try u.method(vm, p, "setUTCMonth", 2, setter(.month, true));
    try u.method(vm, p, "setUTCDate", 1, setter(.date, true));
    try u.method(vm, p, "setUTCHours", 4, setter(.hours, true));
    try u.method(vm, p, "setUTCMinutes", 3, setter(.minutes, true));
    try u.method(vm, p, "setUTCSeconds", 2, setter(.seconds, true));
    try u.method(vm, p, "setUTCMilliseconds", 1, setter(.ms, true));
    try u.method(vm, p, "toString", 0, toStringFn);
    try u.method(vm, p, "toDateString", 0, toDateString);
    try u.method(vm, p, "toTimeString", 0, toTimeString);
    try u.method(vm, p, "toISOString", 0, toISOString);
    try u.method(vm, p, "toUTCString", 0, toUTCString);
    try u.data(vm, p, "toGMTString", try props.get(vm, p, try str.keyFromBytes(vm, "toUTCString")));
    try u.method(vm, p, "toJSON", 1, toJSON);
    try u.method(vm, p, "toLocaleString", 0, toLocaleString);
    try u.method(vm, p, "toLocaleDateString", 0, toLocaleDateString);
    try u.method(vm, p, "toLocaleTimeString", 0, toLocaleTimeString);
    const tp = try api.newNative(vm, "[Symbol.toPrimitive]", 1, toPrimitiveFn);
    try props.defineData(vm, p, PropKey.fromSymbol(vm.sym.toPrimitive), tp.value(), u.PropFlags.config_only);
}
