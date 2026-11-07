//! Minimal Intl: en-US only, enough that format() gives plausible output and code that
//! touches Intl doesn't crash. NumberFormat groups thousands and honours fraction digits,
//! style currency/percent; DateTimeFormat uses the en-US default; Collator compares by case-folded
//! text. Nothing else about locales is modelled.

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
const api = @import("vm_api.zig");
const date = @import("b_date.zig");
const strings = @import("b_string2.zig");
const ops = @import("ops.zig");
const number_fmt = @import("b_number_fmt.zig");

fn opt(vm: *Vm, options: Value, name: []const u8) Error!Value {
    if (!options.isObject()) return Value.undefined;
    return props.get(vm, options.asObject(), try str.keyFromBytes(vm, name));
}

fn groupInt(b: *str.Builder, digits: []const u8) Error!void {
    for (digits, 0..) |c, i| {
        if (i != 0 and (digits.len - i) % 3 == 0) try b.byte(',');
        try b.byte(c);
    }
}

fn formatNumber(vm: *Vm, d: f64, options: Value) Error!Value {
    if (d != d) return api.newString(vm, "NaN");
    var b = str.Builder.init(vm);
    defer b.deinit();
    var value = d;
    const style_v = try opt(vm, options, "style");
    const style = if (style_v.isString()) try style_v.asString().flat(vm) else "decimal";
    const percent = std.mem.eql(u8, style, "percent");
    const currency = std.mem.eql(u8, style, "currency");
    if (percent) value *= 100;
    var min_frac: f64 = if (currency) 2 else 0;
    var max_frac: f64 = if (currency) 2 else if (percent) 0 else 3;
    const minv = try opt(vm, options, "minimumFractionDigits");
    const maxv = try opt(vm, options, "maximumFractionDigits");
    if (!minv.isUndefined()) {
        min_frac = try conv.toIntegerOrInf(vm, minv);
        max_frac = @max(max_frac, min_frac);
    }
    if (!maxv.isUndefined()) {
        max_frac = try conv.toIntegerOrInf(vm, maxv);
        min_frac = @min(min_frac, max_frac);
    }
    if (max_frac < 0 or max_frac > 100 or min_frac < 0) return vm.throwError(.RangeError, "maximumFractionDigits value is out of range.");
    if (value < 0 or (value == 0 and std.math.signbit(value))) try b.byte('-');
    if (currency) {
        const cv = try opt(vm, options, "currency");
        const cs = if (cv.isString()) try cv.asString().flat(vm) else "USD";
        const symbol = if (std.mem.eql(u8, cs, "USD")) "$" else if (std.mem.eql(u8, cs, "EUR")) "\xE2\x82\xAC" else if (std.mem.eql(u8, cs, "GBP")) "\xC2\xA3" else if (std.mem.eql(u8, cs, "JPY")) "\xC2\xA5" else cs;
        try b.bytes(symbol);
        if (symbol.ptr == cs.ptr) try b.bytes("\xC2\xA0");
    }
    if (std.math.isInf(value)) {
        try b.bytes("\xE2\x88\x9E");
    } else {
        var fb = str.Builder.init(vm);
        defer fb.deinit();
        try number_fmt.fixed(vm, &fb, @abs(value), @intFromFloat(max_frac));
        const s = fb.buf.items;
        const dot = std.mem.indexOfScalar(u8, s, '.') orelse s.len;
        const grouping = try opt(vm, options, "useGrouping");
        if (grouping.isBool() and !grouping.asBool()) {
            try b.bytes(s[0..dot]);
        } else {
            try groupInt(&b, s[0..dot]);
        }
        if (dot < s.len) {
            var frac = s[dot + 1 ..];
            const keep: usize = @intFromFloat(min_frac);
            while (frac.len > keep and frac[frac.len - 1] == '0') frac = frac[0 .. frac.len - 1];
            if (frac.len != 0) {
                try b.byte('.');
                try b.bytes(frac);
            }
        }
    }
    if (percent) try b.byte('%');
    return Value.fromString(try b.finish());
}

/// Number.prototype.toLocaleString.
pub fn numberToLocale(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = if (this.isObject()) try conv.toNumber(vm, this) else if (this.isNumber()) this.asNumber() else return vm.throwError(.TypeError, "not a number");
    return formatNumber(vm, n, u.arg(args, 1));
}

/// Each Intl object stores its options in slot `options`, the only state these stubs keep.
fn optionsOf(vm: *Vm, this: Value) Error!Value {
    if (!this.isObject()) return Value.undefined;
    return props.get(vm, this.asObject(), try str.keyFromBytes(vm, "__options"));
}

fn makeInstance(vm: *Vm, proto: *Object, args: []const Value) Error!Value {
    const o = try objmod.create(vm, proto, .intl);
    try props.addProp(vm, o, try str.keyFromBytes(vm, "__options"), u.arg(args, 1), u.PropFlags.hidden);
    return o.value();
}

fn ctorFor(comptime slot: usize) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, _: Value, args: []const Value) Error!Value {
            return makeInstance(vm, vm.intl_protos[slot], args);
        }
    }.f;
}

fn nfFormatBound(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const p = try conv.toNumber(vm, u.arg(args, 0));
    return formatNumber(vm, p, vm.capture(0));
}
fn nfFormatGet(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return api.newNativeClosure(vm, "", 1, nfFormatBound, &.{try optionsOf(vm, this)});
}
fn dtFormatBound(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const a = u.arg(args, 0);
    var t: f64 = undefined;
    if (a.isUndefined()) {
        t = conv.realtimeMs();
    } else if (a.isObject() and a.asObject().class == .date) {
        t = a.asObject().payload.number;
    } else {
        t = try conv.toNumber(vm, a);
    }
    const options = vm.capture(0);
    const has_time = !(try opt(vm, options, "hour")).isUndefined() or !(try opt(vm, options, "timeStyle")).isUndefined();
    return if (has_time) date.localeBoth(vm, t) else date.localeDate(vm, t);
}
fn dtFormatGet(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return api.newNativeClosure(vm, "", 1, dtFormatBound, &.{try optionsOf(vm, this)});
}
fn collatorBound(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const a = try conv.toStr(vm, u.arg(args, 0));
    const b = try conv.toStr(vm, u.arg(args, 1));
    return Value.fromInt(try strings.collate(vm, a, b));
}
fn collatorCompareGet(vm: *Vm, _: Value, _: []const Value) Error!Value {
    return api.newNativeClosure(vm, "", 2, collatorBound, &.{});
}
fn pluralSelect(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const n = try conv.toNumber(vm, u.arg(args, 0));
    return api.newString(vm, if (n == 1) "one" else "other");
}
fn listFormat(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const list = try @import("b_function.zig").listFromArrayLike(vm, u.arg(args, 0));
    defer vm.gpa.free(list);
    var b = str.Builder.init(vm);
    defer b.deinit();
    for (list, 0..) |v, i| {
        if (i != 0) try b.bytes(if (i + 1 == list.len) (if (list.len == 2) " and " else ", and ") else ", ");
        try b.str(try conv.toStr(vm, v));
    }
    return Value.fromString(try b.finish());
}
fn relFormat(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const n = try conv.toNumber(vm, u.arg(args, 0));
    const unit = try conv.toStr(vm, u.arg(args, 1));
    var b = str.Builder.init(vm);
    defer b.deinit();
    var nb: [64]u8 = undefined;
    const t = conv.formatNumber(@abs(n), &nb);
    if (n >= 0) try b.bytes("in ");
    try b.bytes(t);
    try b.byte(' ');
    try b.str(unit);
    if (@abs(n) != 1) try b.byte('s');
    if (n < 0) try b.bytes(" ago");
    return Value.fromString(try b.finish());
}

fn resolvedOptions(vm: *Vm, _: Value, _: []const Value) Error!Value {
    const o = try objmod.newPlain(vm);
    try u.data(vm, o, "locale", try api.newString(vm, "en-US"));
    try props.defineData(vm, o, try str.keyFromBytes(vm, "locale"), try api.newString(vm, "en-US"), u.PropFlags.all);
    try props.defineData(vm, o, try str.keyFromBytes(vm, "timeZone"), try api.newString(vm, "UTC"), u.PropFlags.all);
    try props.defineData(vm, o, try str.keyFromBytes(vm, "numberingSystem"), try api.newString(vm, "latn"), u.PropFlags.all);
    return o.value();
}

fn supportedLocalesOf(vm: *Vm, _: Value, _: []const Value) Error!Value {
    return (try objmod.newArray(vm, &.{try api.newString(vm, "en-US")})).value();
}

fn getCanonicalLocales(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const a = u.arg(args, 0);
    if (a.isString()) return (try objmod.newArray(vm, &.{a})).value();
    return (try objmod.newArray(vm, &.{})).value();
}

fn install(vm: *Vm, intl: *Object, comptime slot: usize, name: []const u8) Error!*Object {
    const proto = try u.newProto(vm, vm.protos.object);
    vm.intl_protos[slot] = proto;
    const c = try api.newNative(vm, name, 0, ctorFor(slot));
    c.flags.constructor = true;
    try props.materialize(vm, c);
    try props.addProp(vm, c, vm.k.prototype, proto.value(), u.PropFlags.readonly);
    try props.defineData(vm, proto, vm.k.constructor, c.value(), u.PropFlags.hidden);
    try u.data(vm, intl, name, c.value());
    try u.method(vm, c, "supportedLocalesOf", 1, supportedLocalesOf);
    try u.method(vm, proto, "resolvedOptions", 0, resolvedOptions);
    try u.toStringTag(vm, proto, name);
    return proto;
}

pub fn init(vm: *Vm) Error!void {
    const intl = try objmod.newPlain(vm);
    try u.data(vm, vm.global_obj, "Intl", intl.value());
    try u.toStringTag(vm, intl, "Intl");
    try u.method(vm, intl, "getCanonicalLocales", 1, getCanonicalLocales);
    const nf = try install(vm, intl, 0, "NumberFormat");
    try u.getter(vm, nf, "format", nfFormatGet);
    const dt = try install(vm, intl, 1, "DateTimeFormat");
    try u.getter(vm, dt, "format", dtFormatGet);
    const co = try install(vm, intl, 2, "Collator");
    try u.getter(vm, co, "compare", collatorCompareGet);
    const pr = try install(vm, intl, 3, "PluralRules");
    try u.method(vm, pr, "select", 1, pluralSelect);
    const lf = try install(vm, intl, 4, "ListFormat");
    try u.method(vm, lf, "format", 1, listFormat);
    const rt = try install(vm, intl, 5, "RelativeTimeFormat");
    try u.method(vm, rt, "format", 2, relFormat);
}
