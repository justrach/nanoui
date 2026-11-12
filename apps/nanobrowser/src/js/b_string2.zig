//! String methods: case mapping, trimming, padding, repeat, comparison, normalize and
//! the ones that dispatch to regular expressions (match, replace, search, split, ...).

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
const JSString = str.JSString;
const calls = @import("interp_call.zig");
const base = @import("b_string.zig");
const thisStr = base.thisStr;
const unicode = @import("regexp_unicode.zig");
const re = @import("b_regexp.zig");
const resym = @import("b_regexp_sym.zig");

fn caseMap(vm: *Vm, s: *JSString, comptime upper: bool) Error!*JSString {
    const b = try s.flat(vm);
    var changed = false;
    if (s.is_ascii) {
        for (b) |c| {
            if (upper and c >= 'a' and c <= 'z') changed = true;
            if (!upper and c >= 'A' and c <= 'Z') changed = true;
        }
        if (!changed) return s;
        const out = try vm.gpa.alloc(u8, b.len);
        for (b, out) |c, *o| o.* = if (upper) std.ascii.toUpper(c) else std.ascii.toLower(c);
        return str.adopt(vm, out);
    }
    var sb = str.Builder.init(vm);
    defer sb.deinit();
    var i: usize = 0;
    while (i < b.len) {
        const d = str.decode(b, i);
        i += d.len;
        if (upper and d.cp == 0xDF) {
            try sb.bytes("SS");
        } else if (!upper and d.cp == 0x130) {
            try sb.bytes("i\xCC\x87");
        } else {
            try sb.cp(if (upper) unicode.toUpper(d.cp) else unicode.toLower(d.cp));
        }
    }
    return sb.finish();
}

fn toUpperCase(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return Value.fromString(try caseMap(vm, try thisStr(vm, this), true));
}
fn toLowerCase(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return Value.fromString(try caseMap(vm, try thisStr(vm, this), false));
}

fn trimImpl(vm: *Vm, this: Value, start: bool, end: bool) Error!Value {
    const s = try thisStr(vm, this);
    const b = try s.flat(vm);
    const t = conv.trimJs(b, start, end);
    if (t.len == b.len) return Value.fromString(s);
    return Value.fromString(try str.fromUtf8(vm, t));
}
fn trim(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return trimImpl(vm, this, true, true);
}
fn trimStart(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return trimImpl(vm, this, true, false);
}
fn trimEnd(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return trimImpl(vm, this, false, true);
}

fn padImpl(vm: *Vm, this: Value, args: []const Value, at_start: bool) Error!Value {
    const s = try thisStr(vm, this);
    const target = try conv.toLength(vm, u.arg(args, 0));
    if (target <= s.len16) return Value.fromString(s);
    const filler = if (u.arg(args, 1).isUndefined()) vm.char_strs[' '] else try conv.toStr(vm, args[1]);
    if (filler.len16 == 0) return Value.fromString(s);
    const need = target - s.len16;
    if (target > str.max_length) return vm.throwError(.RangeError, "Invalid string length");
    var pad = str.Builder.init(vm);
    defer pad.deinit();
    var n: usize = 0;
    while (n + filler.len16 <= need) : (n += filler.len16) try pad.str(filler);
    if (n < need) try pad.str(try str.substring(vm, filler, 0, need - n));
    const p = try pad.finish();
    return Value.fromString(if (at_start) try str.concat(vm, p, s) else try str.concat(vm, s, p));
}
fn padStart(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return padImpl(vm, this, args, true);
}
fn padEnd(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return padImpl(vm, this, args, false);
}

fn repeat(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const s = try thisStr(vm, this);
    const n = try conv.toIntegerOrInf(vm, u.arg(args, 0));
    if (n < 0 or std.math.isInf(n)) return vm.throwError(.RangeError, "Invalid count value");
    if (n == 0 or s.byte_len == 0) return Value.fromString(vm.empty);
    const total = n * @as(f64, @floatFromInt(s.byte_len));
    if (total > @as(f64, @floatFromInt(str.max_length))) return vm.throwError(.RangeError, "Invalid string length");
    const b = try s.flat(vm);
    const out = try vm.gpa.alloc(u8, @intFromFloat(total));
    var i: usize = 0;
    while (i < out.len) : (i += b.len) @memcpy(out[i..][0..b.len], b);
    return Value.fromString(try str.adopt(vm, out));
}

/// A rough collation: case-insensitive first, then lowercase before uppercase.
fn localeCompare(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const a = try thisStr(vm, this);
    const b = try conv.toStr(vm, u.arg(args, 0));
    return Value.fromInt(try collate(vm, a, b));
}

pub fn collate(vm: *Vm, a: *JSString, b: *JSString) Error!i32 {
    const la = try caseMap(vm, a, false);
    const lb = try caseMap(vm, b, false);
    switch (try str.compare(vm, la, lb)) {
        .lt => return -1,
        .gt => return 1,
        .eq => {},
    }
    return switch (try str.compare(vm, a, b)) {
        .lt => 1,
        .gt => -1,
        .eq => 0,
    };
}

/// Identity: nothing here decomposes or composes. Ascii is unaffected by normalization anyway.
fn normalize(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const s = try thisStr(vm, this);
    if (!u.arg(args, 0).isUndefined()) {
        const f = try (try conv.toStr(vm, args[0])).flat(vm);
        const ok = std.mem.eql(u8, f, "NFC") or std.mem.eql(u8, f, "NFD") or std.mem.eql(u8, f, "NFKC") or std.mem.eql(u8, f, "NFKD");
        if (!ok) return vm.throwError(.RangeError, "The normalization form should be one of NFC, NFD, NFKC, NFKD.");
    }
    return Value.fromString(s);
}

fn isWellFormed(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return Value.fromBool(!(try thisStr(vm, this)).has_lone);
}

fn toWellFormed(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const s = try thisStr(vm, this);
    if (!s.has_lone) return Value.fromString(s);
    const us = try s.units(vm);
    const out = try vm.gpa.dupe(u16, us);
    defer vm.gpa.free(out);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const c = out[i];
        if (c >= 0xD800 and c < 0xDC00 and i + 1 < out.len and out[i + 1] >= 0xDC00 and out[i + 1] < 0xE000) {
            i += 1;
        } else if (c >= 0xD800 and c < 0xE000) {
            out[i] = 0xFFFD;
        }
    }
    return Value.fromString(try str.fromUtf16(vm, out));
}

/// Calls arg[Symbol.xxx](this, ...) when the argument provides that method.
fn dispatch(vm: *Vm, this: Value, arg: Value, sym: *str.Symbol, extra: ?Value) Error!?Value {
    if (arg.isNullish()) return null;
    if (!arg.isObject()) return null;
    const m = try props.getV(vm, arg, PropKey.fromSymbol(sym));
    if (m.isNullish()) return null;
    if (extra) |e| return try calls.call(vm, m, arg, &.{ this, e });
    return try calls.call(vm, m, arg, &.{this});
}

fn checkThis(vm: *Vm, this: Value) Error!void {
    if (this.isNullish()) return vm.throwError(.TypeError, "String.prototype method called on null or undefined");
}

fn matchFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    try checkThis(vm, this);
    const a0 = u.arg(args, 0);
    if (a0.isObject() and re.isFastRegExp(vm, a0.asObject())) return resym.matchFn(vm, a0, &.{this});
    if (try dispatch(vm, this, a0, vm.sym.match, null)) |r| return r;
    const s = try thisStr(vm, this);
    const pat = if (a0.isUndefined()) vm.empty else try conv.toStr(vm, a0);
    const rx = try re.create(vm, pat, vm.empty, vm.protos.regexp);
    if (!vm.protos.regexp.flags.proto_dirty) return resym.matchFn(vm, rx, &.{Value.fromString(s)});
    const m = try props.get(vm, rx.asObject(), PropKey.fromSymbol(vm.sym.match));
    return calls.call(vm, m, rx, &.{Value.fromString(s)});
}

fn matchAllFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    try checkThis(vm, this);
    const a0 = u.arg(args, 0);
    if (a0.isObject() and a0.asObject().class == .regexp) {
        const ro = a0.asObject();
        const is_g = if (re.isFastRegExp(vm, ro)) ro.payload.regexp.prog.flags.global else std.mem.indexOfScalar(u8, try (try conv.toStr(vm, try props.get(vm, ro, vm.k.flags))).flat(vm), 'g') != null;
        if (!is_g) return vm.throwError(.TypeError, "String.prototype.matchAll called with a non-global RegExp argument");
    }
    if (try dispatch(vm, this, a0, vm.sym.matchAll, null)) |r| return r;
    const s = try thisStr(vm, this);
    const pat = if (a0.isUndefined()) vm.empty else try conv.toStr(vm, a0);
    const rx = try re.create(vm, pat, vm.char_strs['g'], vm.protos.regexp);
    const m = try props.get(vm, rx.asObject(), PropKey.fromSymbol(vm.sym.matchAll));
    return calls.call(vm, m, rx, &.{Value.fromString(s)});
}

fn searchFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    try checkThis(vm, this);
    const a0 = u.arg(args, 0);
    if (a0.isObject() and re.isFastRegExp(vm, a0.asObject())) return resym.searchFn(vm, a0, &.{this});
    if (try dispatch(vm, this, a0, vm.sym.search, null)) |r| return r;
    const s = try thisStr(vm, this);
    const pat = if (a0.isUndefined()) vm.empty else try conv.toStr(vm, a0);
    const rx = try re.create(vm, pat, vm.empty, vm.protos.regexp);
    if (!vm.protos.regexp.flags.proto_dirty) return resym.searchFn(vm, rx, &.{Value.fromString(s)});
    const m = try props.get(vm, rx.asObject(), PropKey.fromSymbol(vm.sym.search));
    return calls.call(vm, m, rx, &.{Value.fromString(s)});
}

fn replaceOnce(vm: *Vm, s: *JSString, pat: *JSString, rv: Value, all: bool) Error!Value {
    const functional = rv.isCallable();
    const template = if (functional) vm.empty else try conv.toStr(vm, rv);
    const has_dollar = if (functional) false else std.mem.indexOfScalar(u8, try template.flat(vm), '$') != null;
    var b = str.Builder.init(vm);
    defer b.deinit();
    var next: usize = 0;
    var from: usize = 0;
    var any = false;
    while (try base.indexOfFrom(vm, s, pat, from)) |pos| {
        any = true;
        if (pos > next) try b.sub(s, next, pos);
        if (functional) {
            const r = try calls.call(vm, rv, Value.undefined, &.{ Value.fromString(pat), Value.fromUsize(pos), Value.fromString(s) });
            try b.str(try conv.toStr(vm, r));
        } else if (!has_dollar) {
            try b.str(template);
        } else {
            try resym.getSubstitution(vm, &b, pat, s, pos, &.{}, Value.undefined, template);
        }
        next = pos + pat.len16;
        from = if (pat.len16 == 0) pos + 1 else next;
        if (!all or from > s.len16) break;
    }
    if (!any) return Value.fromString(s);
    if (next < s.len16) try b.sub(s, next, s.len16);
    return Value.fromString(try b.finish());
}

fn replaceFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    try checkThis(vm, this);
    const a0 = u.arg(args, 0);
    const a1 = u.arg(args, 1);
    if (a0.isObject() and re.isFastRegExp(vm, a0.asObject())) return resym.replaceFn(vm, a0, &.{ this, a1 });
    if (try dispatch(vm, this, a0, vm.sym.replace, a1)) |r| return r;
    return replaceOnce(vm, try thisStr(vm, this), try conv.toStr(vm, a0), a1, false);
}

fn replaceAll(vm: *Vm, this: Value, args: []const Value) Error!Value {
    try checkThis(vm, this);
    const a0 = u.arg(args, 0);
    const a1 = u.arg(args, 1);
    if (a0.isObject() and a0.asObject().class == .regexp) {
        const ro = a0.asObject();
        if (re.isFastRegExp(vm, ro)) {
            if (!ro.payload.regexp.prog.flags.global) return vm.throwError(.TypeError, "replaceAll must be called with a global RegExp");
            return resym.replaceFn(vm, a0, &.{ this, a1 });
        }
        const is_g = std.mem.indexOfScalar(u8, try (try conv.toStr(vm, try props.get(vm, ro, vm.k.flags))).flat(vm), 'g') != null;
        if (!is_g) return vm.throwError(.TypeError, "replaceAll must be called with a global RegExp");
    }
    if (try dispatch(vm, this, a0, vm.sym.replace, a1)) |r| return r;
    return replaceOnce(vm, try thisStr(vm, this), try conv.toStr(vm, a0), a1, true);
}

fn splitFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    try checkThis(vm, this);
    const a0 = u.arg(args, 0);
    const a1 = u.arg(args, 1);
    if (a0.isObject() and re.isFastRegExp(vm, a0.asObject())) return resym.splitFn(vm, a0, &.{ this, a1 });
    if (try dispatch(vm, this, a0, vm.sym.split, a1)) |r| return r;
    const s = try thisStr(vm, this);
    const lim: u32 = if (u.arg(args, 1).isUndefined()) 0xFFFF_FFFF else try conv.toUint32(vm, args[1]);
    const sep_v = u.arg(args, 0);
    const out = try objmod.newArray(vm, &.{});
    const sep = try conv.toStr(vm, sep_v);
    if (lim == 0) return out.value();
    if (sep_v.isUndefined()) {
        try objmod.arrayPush(vm, out, Value.fromString(s));
        return out.value();
    }
    if (sep.len16 == 0) {
        var i: usize = 0;
        const n = @min(s.len16, lim);
        while (i < n) : (i += 1) try objmod.arrayPush(vm, out, Value.fromString(try str.substring(vm, s, i, i + 1)));
        return out.value();
    }
    var start: usize = 0;
    while (try base.indexOfFrom(vm, s, sep, start)) |pos| {
        try objmod.arrayPush(vm, out, Value.fromString(try str.substring(vm, s, start, pos)));
        if (out.arr_len == lim) return out.value();
        start = pos + sep.len16;
    }
    try objmod.arrayPush(vm, out, Value.fromString(try str.substring(vm, s, start, s.len16)));
    return out.value();
}

fn htmlWrap(vm: *Vm, this: Value, comptime tag: []const u8) Error!Value {
    var b = str.Builder.init(vm);
    defer b.deinit();
    try b.bytes("<" ++ tag ++ ">");
    try b.str(try thisStr(vm, this));
    try b.bytes("</" ++ tag ++ ">");
    return Value.fromString(try b.finish());
}
fn bold(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return htmlWrap(vm, this, "b");
}
fn italics(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return htmlWrap(vm, this, "i");
}

pub fn init(vm: *Vm, p: *Object) Error!void {
    try u.method(vm, p, "toUpperCase", 0, toUpperCase);
    try u.method(vm, p, "toLowerCase", 0, toLowerCase);
    try u.method(vm, p, "toLocaleUpperCase", 0, toUpperCase);
    try u.method(vm, p, "toLocaleLowerCase", 0, toLowerCase);
    try u.method(vm, p, "trim", 0, trim);
    try u.method(vm, p, "trimStart", 0, trimStart);
    try u.method(vm, p, "trimEnd", 0, trimEnd);
    try u.data(vm, p, "trimLeft", try props.get(vm, p, try str.keyFromBytes(vm, "trimStart")));
    try u.data(vm, p, "trimRight", try props.get(vm, p, try str.keyFromBytes(vm, "trimEnd")));
    try u.method(vm, p, "padStart", 1, padStart);
    try u.method(vm, p, "padEnd", 1, padEnd);
    try u.method(vm, p, "repeat", 1, repeat);
    try u.method(vm, p, "localeCompare", 1, localeCompare);
    try u.method(vm, p, "normalize", 0, normalize);
    try u.method(vm, p, "isWellFormed", 0, isWellFormed);
    try u.method(vm, p, "toWellFormed", 0, toWellFormed);
    try u.method(vm, p, "match", 1, matchFn);
    try u.method(vm, p, "matchAll", 1, matchAllFn);
    try u.method(vm, p, "search", 1, searchFn);
    try u.method(vm, p, "replace", 2, replaceFn);
    try u.method(vm, p, "replaceAll", 2, replaceAll);
    try u.method(vm, p, "split", 2, splitFn);
    try u.method(vm, p, "bold", 0, bold);
    try u.method(vm, p, "italics", 0, italics);
}
