//! JSON.stringify (replacer, indent, toJSON, cycle errors) and string quoting.

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

/// Appends s as a JSON string, escaped; lone surrogates become \uXXXX.
pub fn quote(vm: *Vm, b: *str.Builder, s: *JSString) Error!void {
    if (s.is_ascii and !s.is_rope) {
        const fast = s.ptr[0..s.byte_len];
        var clean = true;
        for (fast) |c| {
            if (c < 0x20 or c == '"' or c == '\\') {
                clean = false;
                break;
            }
        }
        if (clean) {
            try b.byte('"');
            try b.bytes(fast);
            try b.byte('"');
            return;
        }
    }
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
        if (v.isObject()) {
            const vo = v.asObject();
            const no_tojson = (!vo.flags.exotic and !vo.flags.lazy_fn and
                ((vo.class == .array and vo.shape == vm.array_root and !vm.protos.array.flags.proto_dirty and !vm.protos.object.flags.proto_dirty) or
                    ((vo.shape.proto == null or (vo.shape.proto == vm.protos.object and !vm.protos.object.flags.proto_dirty)) and vo.shape.find(vm.k.toJSON) == null)));
            if (!no_tojson) {
                const to_json = try props.getV(vm, v, vm.k.toJSON);
                if (to_json.isCallable()) v = try calls.call(vm, to_json, v, &.{try str.keyToValue(vm, key)});
            }
        } else if (v.isBigInt()) {
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
        if (v.isInt()) {
            var ibuf: [16]u8 = undefined;
            try s.b.bytes(std.fmt.bufPrint(&ibuf, "{d}", .{v.asInt()}) catch unreachable);
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
            if (v.asObject().class == .array or try arr.isArrayValue(vm, v)) {
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
        const vm = s.vm;
        const fast_arr = o.class == .array and o.shape == vm.array_root and !o.flags.exotic and !vm.protos.array.flags.proto_dirty and !vm.protos.object.flags.proto_dirty;
        const n: usize = if (fast_arr) o.arr_len else try conv.lengthOf(vm, o);
        try s.b.byte('[');
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (i != 0) try s.b.byte(',');
            try s.newline();
            const k = PropKey.fromIndex(@intCast(i));
            const ev: Value = if (fast_arr and i < o.elems_len and o.shape == vm.array_root)
                (if (o.elems[i].isHole()) Value.undefined else o.elems[i])
            else if (fast_arr and o.shape == vm.array_root and !o.flags.has_sparse)
                Value.undefined
            else
                try props.get(vm, o, k);
            if (!try s.property(o, k, ev)) try s.b.bytes("null");
        }
        if (n != 0) try s.closeLine();
        try s.b.byte(']');
    }

    fn object(s: *Stringifier, o: *Object) Error!void {
        const vm = s.vm;
        try s.enter(o);
        defer s.leave();
        if (s.allow == null and o.shape.all_plain_str and !o.shape.is_dict and !o.flags.exotic and !o.flags.lazy_fn and !o.flags.has_sparse and o.elems_len == 0 and o.class == .object) {
            const init_sh = o.shape;
            const count = init_sh.count;
            try s.b.byte('{');
            var any = false;
            var idx: u32 = 0;
            while (idx < count) : (idx += 1) {
                const k = init_sh.table.entries.items[idx].key;
                const v: Value = if (o.shape == init_sh) o.slots[idx] else blk: {
                    const own = try props.getOwn(vm, o, k) orelse continue;
                    if (!own.flags.enumerable) continue;
                    break :blk try props.get(vm, o, k);
                };
                const rollback = s.b.buf.items.len;
                if (any) try s.b.byte(',');
                try s.newline();
                try quote(vm, &s.b, k.atom());
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
            return;
        }
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

pub fn stringifyFn(vm: *Vm, _: Value, args: []const Value) Error!Value {
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
