//! JSON.parse (with V8-style speculative shape-transition key matching and reviver)
//! and JSON object initialization. JSON.stringify lives in `b_json_stringify.zig`.

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
const arr = @import("b_array.zig");
const stringify_mod = @import("b_json_stringify.zig");
pub const quote = stringify_mod.quote;

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
            '"' => return Value.fromString(try p.string(false)),
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

    fn string(p: *Parser, intern_short: bool) Error!*JSString {
        const s = p.s;
        p.i += 1;
        const start = p.i;
        while (p.i < s.len) : (p.i += 1) {
            const c = s[p.i];
            if (c == '"') {
                const t = s[start..p.i];
                p.i += 1;
                return if (intern_short and t.len <= 64) try str.intern(p.vm, t) else try str.fromUtf8(p.vm, t);
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
        return if (intern_short and p.buf.items.len <= 64) str.intern(p.vm, p.buf.items) else str.fromUtf8(p.vm, p.buf.items);
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
            if (o.shape.single) |next| if (next.all_plain_str and next.count < 512) {
                const ks = next.key.atom();
                const klen = ks.byte_len;
                if (ks.is_ascii and !ks.is_rope and p.i + 1 + klen < p.s.len and p.s[p.i + 1 + klen] == '"') {
                    const cand = p.s[p.i + 1 ..][0..klen];
                    const want = ks.ptr[0..klen];
                    var ok = true;
                    for (cand, want) |cb, wb| {
                        if (cb != wb or cb < 0x20 or cb == '"' or cb == '\\') {
                            ok = false;
                            break;
                        }
                    }
                    if (ok) {
                        p.i += klen + 2;
                        p.ws();
                        if (p.i >= p.s.len or p.s[p.i] != ':') return p.fail();
                        p.i += 1;
                        const v = try p.value();
                        const slot = o.shape.count;
                        if (slot >= o.slot_cap) try objmod.growSlots(p.vm, o, slot + 1);
                        o.shape = next;
                        o.slots[slot] = v;
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
            const k = try str.toKey(p.vm, try p.string(true));
            p.ws();
            if (p.i >= p.s.len or p.s[p.i] != ':') return p.fail();
            p.i += 1;
            const v = try p.value();
            if (!k.isIndex() and !o.shape.is_dict and o.shape.count < 512 and o.shape.find(k) == null) {
                try props.addProp(p.vm, o, k, v, PropFlags.all);
            } else {
                try props.defineData(p.vm, o, k, v, PropFlags.all);
            }
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

pub fn init(vm: *Vm) Error!void {
    const o = try objmod.newPlain(vm);
    try u.data(vm, vm.global_obj, "JSON", o.value());
    try u.toStringTag(vm, o, "JSON");
    try u.method(vm, o, "parse", 2, parseFn);
    try u.method(vm, o, "stringify", 3, stringify_mod.stringifyFn);
}
