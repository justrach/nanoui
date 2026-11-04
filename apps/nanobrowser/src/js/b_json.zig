//! JSON.parse (with reviver) and JSON.stringify (replacer, indent, toJSON, cycle errors).

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const u = @import("b_util.zig");
const Value = u.Value;
const PropKey = u.PropKey;
const Object = u.Object;
const PropFlags = u.PropFlags;
const objmod = @import("object.zig");
const props = @import("props.zig");
const conv = @import("conv.zig");
const str = @import("string.zig");
const JSString = str.JSString;
const calls = @import("interp_call.zig");
const big = @import("b_bigint.zig");
const arr = @import("b_array.zig");

const Parser = struct {
    vm: *Vm,
    s: []const u8,
    i: usize = 0,
    buf: std.ArrayList(u8) = .empty,

    fn ws(p: *Parser) void {
        while (p.i < p.s.len) : (p.i += 1) {
            switch (p.s[p.i]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn fail(p: *Parser) Error {
        var b: [120]u8 = undefined;
        if (p.i >= p.s.len) return p.vm.throwError(.SyntaxError, "Unexpected end of JSON input");
        const m = std.fmt.bufPrint(&b, "Unexpected token '{c}' in JSON at position {d}", .{ if (p.s[p.i] < 0x80) p.s[p.i] else '?', p.i }) catch "Unexpected token in JSON";
        return p.vm.throwError(.SyntaxError, m);
    }

    fn value(p: *Parser) Error!Value {
        try p.vm.checkNativeStack();
        p.ws();
        if (p.i >= p.s.len) return p.fail();
        switch (p.s[p.i]) {
            '{' => return p.object(),
            '[' => return p.array(),
            '"' => return Value.fromString(try p.string()),
            't' => return p.word("true", Value.true),
            'f' => return p.word("false", Value.false),
            'n' => return p.word("null", Value.null),
            else => return p.number(),
        }
    }

    fn word(p: *Parser, w: []const u8, v: Value) Error!Value {
        if (!std.mem.startsWith(u8, p.s[p.i..], w)) return p.fail();
        p.i += w.len;
        return v;
    }

    fn number(p: *Parser) Error!Value {
        const start = p.i;
        const s = p.s;
        if (p.i < s.len and s[p.i] == '-') p.i += 1;
        if (p.i >= s.len) return p.fail();
        if (s[p.i] == '0') {
            p.i += 1;
        } else if (s[p.i] >= '1' and s[p.i] <= '9') {
            while (p.i < s.len and s[p.i] >= '0' and s[p.i] <= '9') p.i += 1;
        } else return p.fail();
        var simple = true;
        if (p.i < s.len and s[p.i] == '.') {
            simple = false;
            p.i += 1;
            if (p.i >= s.len or !(s[p.i] >= '0' and s[p.i] <= '9')) return p.fail();
            while (p.i < s.len and s[p.i] >= '0' and s[p.i] <= '9') p.i += 1;
        }
        if (p.i < s.len and (s[p.i] | 0x20) == 'e') {
            simple = false;
            p.i += 1;
            if (p.i < s.len and (s[p.i] == '+' or s[p.i] == '-')) p.i += 1;
            if (p.i >= s.len or !(s[p.i] >= '0' and s[p.i] <= '9')) return p.fail();
            while (p.i < s.len and s[p.i] >= '0' and s[p.i] <= '9') p.i += 1;
        }
        const t = s[start..p.i];
        if (simple and t.len <= 9) {
            const n = std.fmt.parseInt(i32, t, 10) catch 0;
            if (n != 0 or t[0] != '-') return Value.fromInt(n);
        }
        const d = std.fmt.parseFloat(f64, t) catch return p.fail();
        return Value.fromNumber(d);
    }

    fn hex4(p: *Parser) Error!u32 {
        if (p.i + 4 > p.s.len) {
            p.i = p.s.len;
            return p.fail();
        }
        var v: u32 = 0;
        for (p.s[p.i..][0..4]) |c| {
            const d = std.fmt.charToDigit(c, 16) catch return p.fail();
            v = v * 16 + d;
        }
        p.i += 4;
        return v;
    }

    fn string(p: *Parser) Error!*JSString {
        const s = p.s;
        p.i += 1;
        const start = p.i;
        // No escapes is the common case.
        while (p.i < s.len) : (p.i += 1) {
            const c = s[p.i];
            if (c == '"') {
                const t = s[start..p.i];
                p.i += 1;
                return if (t.len <= 32) try str.intern(p.vm, t) else try str.fromUtf8(p.vm, t);
            }
            if (c == '\\') break;
            if (c < 0x20) return p.fail();
        }
        p.buf.clearRetainingCapacity();
        const gpa = p.vm.gpa;
        try p.buf.appendSlice(gpa, s[start..p.i]);
        while (true) {
            if (p.i >= s.len) return p.fail();
            const c = s[p.i];
            if (c == '"') {
                p.i += 1;
                break;
            }
            if (c < 0x20) return p.fail();
            if (c != '\\') {
                try p.buf.append(gpa, c);
                p.i += 1;
                continue;
            }
            p.i += 1;
            if (p.i >= s.len) return p.fail();
            const e = s[p.i];
            p.i += 1;
            switch (e) {
                '"', '\\', '/' => try p.buf.append(gpa, e),
                'b' => try p.buf.append(gpa, 8),
                'f' => try p.buf.append(gpa, 12),
                'n' => try p.buf.append(gpa, '\n'),
                'r' => try p.buf.append(gpa, '\r'),
                't' => try p.buf.append(gpa, '\t'),
                'u' => {
                    var cp = try p.hex4();
                    if (cp >= 0xD800 and cp < 0xDC00 and p.i + 6 <= s.len and s[p.i] == '\\' and s[p.i + 1] == 'u') {
                        const save = p.i;
                        p.i += 2;
                        const lo = try p.hex4();
                        if (lo >= 0xDC00 and lo < 0xE000) {
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        } else p.i = save;
                    }
                    var t: [4]u8 = undefined;
                    const n = str.encode(cp, &t);
                    try p.buf.appendSlice(gpa, t[0..n]);
                },
                else => {
                    p.i -= 1;
                    return p.fail();
                },
            }
        }
        return str.fromUtf8(p.vm, p.buf.items);
    }

    fn array(p: *Parser) Error!Value {
        p.i += 1;
        const a = try objmod.newArray(p.vm, &.{});
        p.ws();
        if (p.i < p.s.len and p.s[p.i] == ']') {
            p.i += 1;
            return a.value();
        }
        while (true) {
            try objmod.arrayPush(p.vm, a, try p.value());
            p.ws();
            if (p.i >= p.s.len) return p.fail();
            if (p.s[p.i] == ',') {
                p.i += 1;
                continue;
            }
            if (p.s[p.i] == ']') {
                p.i += 1;
                return a.value();
            }
            return p.fail();
        }
    }

    fn object(p: *Parser) Error!Value {
        p.i += 1;
        const o = try objmod.newPlain(p.vm);
        p.ws();
        if (p.i < p.s.len and p.s[p.i] == '}') {
            p.i += 1;
            return o.value();
        }
        while (true) {
            p.ws();
            if (p.i >= p.s.len or p.s[p.i] != '"') return p.fail();
            const k = try str.toKey(p.vm, try p.string());
            p.ws();
            if (p.i >= p.s.len or p.s[p.i] != ':') return p.fail();
            p.i += 1;
            const v = try p.value();
            try props.defineData(p.vm, o, k, v, PropFlags.all);
            p.ws();
            if (p.i >= p.s.len) return p.fail();
            if (p.s[p.i] == ',') {
                p.i += 1;
                continue;
            }
            if (p.s[p.i] == '}') {
                p.i += 1;
                return o.value();
            }
            return p.fail();
        }
    }
};

fn internalize(vm: *Vm, holder: *Object, key: PropKey, reviver: Value) Error!Value {
    try vm.checkNativeStack();
    const val = try props.get(vm, holder, key);
    if (val.isObject()) {
        const o = val.asObject();
        if (try arr.isArrayValue(vm, val)) {
            const n = try conv.lengthOf(vm, o);
            var i: usize = 0;
            while (i < n) : (i += 1) try reviveElement(vm, o, PropKey.fromIndex(@intCast(i)), reviver);
        } else {
            const keys = try props.ownKeys(vm, o);
            defer vm.gpa.free(keys);
            for (keys) |k| {
                if (k.isSymbol()) continue;
                const own = try props.getOwn(vm, o, k) orelse continue;
                if (own.flags.enumerable) try reviveElement(vm, o, k, reviver);
            }
        }
    }
    return calls.call(vm, reviver, holder.value(), &.{ try str.keyToValue(vm, key), val });
}

fn reviveElement(vm: *Vm, o: *Object, k: PropKey, reviver: Value) Error!void {
    const nv = try internalize(vm, o, k, reviver);
    if (nv.isUndefined()) {
        _ = try props.delete(vm, o, k);
    } else {
        _ = try props.defineOwn(vm, o, k, .{ .value = nv, .writable = true, .enumerable = true, .configurable = true });
    }
}

fn parseFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const text = try (try conv.toStr(vm, u.arg(args, 0))).flat(vm);
    var p = Parser{ .vm = vm, .s = text };
    defer p.buf.deinit(vm.gpa);
    const v = try p.value();
    p.ws();
    if (p.i != text.len) return p.fail();
    const reviver = u.arg(args, 1);
    if (!reviver.isCallable()) return v;
    const root = try objmod.newPlain(vm);
    try props.defineData(vm, root, PropKey.fromAtom(vm.empty), v, PropFlags.all);
    return internalize(vm, root, PropKey.fromAtom(vm.empty), reviver);
}

/// Appends s as a JSON string, escaped; lone surrogates become \uXXXX.
pub fn quote(vm: *Vm, b: *str.Builder, s: *JSString) Error!void {
    const t = try s.flat(vm);
    try b.byte('"');
    var i: usize = 0;
    var run: usize = 0;
    while (i < t.len) {
        const c = t[i];
        var esc: ?[]const u8 = null;
        var lone: ?u32 = null;
        var width: usize = 1;
        switch (c) {
            '"' => esc = "\\\"",
            '\\' => esc = "\\\\",
            8 => esc = "\\b",
            12 => esc = "\\f",
            '\n' => esc = "\\n",
            '\r' => esc = "\\r",
            '\t' => esc = "\\t",
            0...7, 11, 14...0x1F => lone = c,
            0xED => {
                const d = str.decode(t, i);
                width = d.len;
                if (d.cp >= 0xD800 and d.cp < 0xE000) lone = d.cp;
            },
            else => {},
        }
        if (esc != null or lone != null) {
            try b.bytes(t[run..i]);
            if (esc) |e| try b.bytes(e) else try b.print("\\u{x:0>4}", .{lone.?});
            run = i + width;
        }
        i += width;
    }
    try b.bytes(t[run..]);
    try b.byte('"');
}

const Stringifier = struct {
    vm: *Vm,
    b: str.Builder,
    replacer: Value = Value.undefined,
    allow: ?[]PropKey = null,
    gap: []const u8 = "",
    indent: std.ArrayList(u8) = .empty,
    stack: std.ArrayList(*Object) = .empty,

    /// False if the value serializes to nothing (undefined, functions, symbols).
    fn property(s: *Stringifier, holder: ?*Object, key: PropKey, val_in: Value) Error!bool {
        const vm = s.vm;
        var v = val_in;
        if (v.isObject() or v.isBigInt()) {
            const to_json = try props.getV(vm, v, vm.k.toJSON);
            if (to_json.isCallable()) v = try calls.call(vm, to_json, v, &.{try str.keyToValue(vm, key)});
        }
        if (!s.replacer.isUndefined()) {
            const h = holder orelse blk: {
                const w = try objmod.newPlain(vm);
                try props.defineData(vm, w, key, v, PropFlags.all);
                break :blk w;
            };
            v = try calls.call(vm, s.replacer, h.value(), &.{ try str.keyToValue(vm, key), v });
        }
        if (v.isObject()) {
            const o = v.asObject();
            switch (o.class) {
                .number => v = Value.fromNumber(try conv.toNumber(vm, v)),
                .string => v = Value.fromString(try conv.toStr(vm, v)),
                .boolean, .bigint => v = o.payload.value,
                else => {},
            }
        }
        if (v.isNull()) {
            try s.b.bytes("null");
            return true;
        }
        if (v.isBool()) {
            try s.b.bytes(if (v.asBool()) "true" else "false");
            return true;
        }
        if (v.isString()) {
            try quote(vm, &s.b, v.asString());
            return true;
        }
        if (v.isNumber()) {
            const d = v.asNumber();
            if (std.math.isFinite(d)) {
                try s.b.str(try conv.numberToString(vm, d));
            } else try s.b.bytes("null");
            return true;
        }
        if (v.isBigInt()) return vm.throwError(.TypeError, "Do not know how to serialize a BigInt");
        if (v.isObject() and !v.isCallable()) {
            if (try arr.isArrayValue(vm, v)) {
                try s.array(v.asObject());
            } else {
                try s.object(v.asObject());
            }
            return true;
        }
        return false;
    }

    fn enter(s: *Stringifier, o: *Object) Error!void {
        try s.vm.checkNativeStack();
        for (s.stack.items) |x| {
            if (x == o) return s.vm.throwError(.TypeError, "Converting circular structure to JSON");
        }
        try s.stack.append(s.vm.gpa, o);
        try s.indent.appendSlice(s.vm.gpa, s.gap);
    }

    fn leave(s: *Stringifier) void {
        _ = s.stack.pop();
        s.indent.items.len -= s.gap.len;
    }

    fn newline(s: *Stringifier) Error!void {
        if (s.gap.len == 0) return;
        try s.b.byte('\n');
        try s.b.bytes(s.indent.items);
    }

    fn closeLine(s: *Stringifier) Error!void {
        if (s.gap.len == 0) return;
        try s.b.byte('\n');
        try s.b.bytes(s.indent.items[0 .. s.indent.items.len - s.gap.len]);
    }

    fn array(s: *Stringifier, o: *Object) Error!void {
        try s.enter(o);
        defer s.leave();
        const n = try conv.lengthOf(s.vm, o);
        try s.b.byte('[');
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (i != 0) try s.b.byte(',');
            try s.newline();
            const k = PropKey.fromIndex(@intCast(i));
            if (!try s.property(o, k, try props.get(s.vm, o, k))) try s.b.bytes("null");
        }
        if (n != 0) try s.closeLine();
        try s.b.byte(']');
    }

    fn object(s: *Stringifier, o: *Object) Error!void {
        const vm = s.vm;
        try s.enter(o);
        defer s.leave();
        var owned: ?[]PropKey = null;
        defer if (owned) |x| vm.gpa.free(x);
        const keys = s.allow orelse blk: {
            owned = try props.ownKeys(vm, o);
            break :blk owned.?;
        };
        try s.b.byte('{');
        var any = false;
        for (keys) |k| {
            if (k.isSymbol()) continue;
            if (s.allow == null) {
                const own = try props.getOwn(vm, o, k) orelse continue;
                if (!own.flags.enumerable) continue;
            }
            const v = try props.get(vm, o, k);
            const rollback = s.b.buf.items.len;
            if (any) try s.b.byte(',');
            try s.newline();
            try quote(vm, &s.b, (try str.keyToValue(vm, k)).asString());
            try s.b.byte(':');
            if (s.gap.len != 0) try s.b.byte(' ');
            if (try s.property(o, k, v)) {
                any = true;
            } else {
                s.b.buf.items.len = rollback;
            }
        }
        if (any) try s.closeLine();
        try s.b.byte('}');
    }
};

fn stringifyFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
    var s = Stringifier{ .vm = vm, .b = str.Builder.init(vm) };
    defer s.b.deinit();
    defer s.indent.deinit(vm.gpa);
    defer s.stack.deinit(vm.gpa);
    var allow: std.ArrayList(PropKey) = .empty;
    defer allow.deinit(vm.gpa);
    const rep = u.arg(args, 1);
    if (rep.isCallable()) {
        s.replacer = rep;
    } else if (try arr.isArrayValue(vm, rep)) {
        const n = try conv.lengthOf(vm, rep.asObject());
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const v = try props.get(vm, rep.asObject(), PropKey.fromIndex(@intCast(i)));
            var item: ?PropKey = null;
            if (v.isString() or v.isNumber()) {
                item = try conv.toPropKey(vm, Value.fromString(try conv.toStr(vm, v)));
            } else if (v.isObject() and (v.asObject().class == .string or v.asObject().class == .number)) {
                item = try conv.toPropKey(vm, Value.fromString(try conv.toStr(vm, v)));
            }
            if (item) |k| {
                for (allow.items) |x| {
                    if (x.eql(k)) break;
                } else try allow.append(vm.gpa, k);
            }
        }
        s.allow = allow.items;
    }
    var sp = u.arg(args, 2);
    if (sp.isObject()) {
        if (sp.asObject().class == .number) sp = Value.fromNumber(try conv.toNumber(vm, sp));
        if (sp.isObject() and sp.asObject().class == .string) sp = Value.fromString(try conv.toStr(vm, sp));
    }
    var gap_buf: [10]u8 = undefined;
    if (sp.isNumber()) {
        const n: usize = @intFromFloat(@min(@max(try conv.toIntegerOrInf(vm, sp), 0), 10));
        @memset(gap_buf[0..n], ' ');
        s.gap = gap_buf[0..n];
    } else if (sp.isString()) {
        const g = try sp.asString().flat(vm);
        s.gap = g[0..@min(g.len, 10)];
    }
    if (!try s.property(null, PropKey.fromAtom(vm.empty), u.arg(args, 0))) return Value.undefined;
    return Value.fromString(try s.b.finish());
}

pub fn init(vm: *Vm) Error!void {
    const o = try objmod.newPlain(vm);
    try u.data(vm, vm.global_obj, "JSON", o.value());
    try u.toStringTag(vm, o, "JSON");
    try u.method(vm, o, "parse", 2, parseFn);
    try u.method(vm, o, "stringify", 3, stringifyFn);
}
