//! RegExp.prototype[Symbol.match / matchAll / replace / search / split] and GetSubstitution.

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
const coroutine = @import("coroutine.zig");
const re = @import("b_regexp.zig");

fn advance(s: *JSString, i: usize, full_unicode: bool, vm: *Vm) Error!usize {
    if (!full_unicode or s.is_ascii or i + 1 >= s.len16) return i + 1;
    const units = try s.units(vm);
    if (units[i] >= 0xD800 and units[i] < 0xDC00 and units[i + 1] >= 0xDC00 and units[i + 1] < 0xE000) return i + 2;
    return i + 1;
}

fn thisObj(vm: *Vm, this: Value) Error!*Object {
    if (!this.isObject()) return vm.throwError(.TypeError, "RegExp method called on non-object");
    return this.asObject();
}

fn flagsOf(vm: *Vm, o: *Object) Error![]const u8 {
    return (try conv.toStr(vm, try props.get(vm, o, vm.k.flags))).flat(vm);
}

fn hasFlag(f: []const u8, c: u8) bool {
    return std.mem.indexOfScalar(u8, f, c) != null;
}

pub fn matchFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisObj(vm, this);
    const s = try conv.toStr(vm, u.arg(args, 0));
    if (re.hasBuiltinExec(vm, o)) {
        const prog = o.payload.regexp.prog;
        const pf = prog.flags;
        if (!pf.global) return re.builtinExec(vm, o, s);
        const full = pf.unicode or pf.unicode_sets;
        try re.setLastIndex(vm, o, 0);
        const out = try objmod.newArray(vm, &.{});
        const total = prog.ncaps * 2 + prog.nregs;
        var stack_regs: [64]i32 = undefined;
        const regs = if (total <= stack_regs.len) stack_regs[0..total] else try vm.gpa.alloc(i32, total);
        defer if (total > stack_regs.len) vm.gpa.free(regs);
        var pos: usize = 0;
        while (pos <= s.len16) {
            if (!try re.matchAt(vm, prog, s, pos, pf.sticky, regs)) break;
            const a: usize = @intCast(regs[0]);
            const b: usize = @intCast(regs[1]);
            try objmod.arrayPush(vm, out, Value.fromString(try str.substring(vm, s, a, b)));
            pos = if (a == b) try advance(s, b, full, vm) else b;
        }
        try re.setLastIndex(vm, o, 0);
        return if (out.arr_len == 0) Value.null else out.value();
    }
    const f = try flagsOf(vm, o);
    if (!hasFlag(f, 'g')) return re.regExpExec(vm, o, s);
    const full = hasFlag(f, 'u') or hasFlag(f, 'v');
    try props.put(vm, o, vm.k.lastIndex, Value.fromInt(0));
    const out = try objmod.newArray(vm, &.{});
    while (true) {
        const r = try re.regExpExec(vm, o, s);
        if (r.isNull()) return if (out.arr_len == 0) Value.null else out.value();
        const m = try conv.toStr(vm, try props.get(vm, r.asObject(), PropKey.fromIndex(0)));
        try objmod.arrayPush(vm, out, Value.fromString(m));
        if (m.byte_len == 0) {
            const li = try conv.toLength(vm, try props.get(vm, o, vm.k.lastIndex));
            try props.put(vm, o, vm.k.lastIndex, Value.fromUsize(try advance(s, li, full, vm)));
        }
    }
}

fn matchAllFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisObj(vm, this);
    const s = try conv.toStr(vm, u.arg(args, 0));
    const c = try u.speciesConstructor(vm, o, vm.protos.regexp_ctor);
    const fs = try conv.toStr(vm, try props.get(vm, o, vm.k.flags));
    const m = try calls.construct(vm, c, &.{ o.value(), Value.fromString(fs) }, c);
    const li = try conv.toLength(vm, try props.get(vm, o, vm.k.lastIndex));
    try props.put(vm, m.asObject(), vm.k.lastIndex, Value.fromUsize(li));
    const f = try fs.flat(vm);
    const data = try vm.gpa.create(objmod.IterData);
    data.* = .{
        .target = m,
        .aux = Value.fromString(s),
        .kind = @as(u8, @intFromBool(hasFlag(f, 'g'))) | (@as(u8, @intFromBool(hasFlag(f, 'u') or hasFlag(f, 'v'))) << 1),
    };
    const it = objmod.create(vm, vm.protos.regexp_string_iter, .regexp_string_iter) catch |e| {
        vm.gpa.destroy(data);
        return e;
    };
    it.payload = .{ .iter = data };
    return it.value();
}

fn matchAllNext(vm: *Vm, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().class != .regexp_string_iter) return vm.throwError(.TypeError, "next method called on incompatible receiver");
    const it = this.asObject().payload.iter;
    if (it.done) return coroutine.iterResult(vm, Value.undefined, true);
    const o = it.target.asObject();
    const s = it.aux.asString();
    const r = try re.regExpExec(vm, o, s);
    if (r.isNull()) {
        it.done = true;
        return coroutine.iterResult(vm, Value.undefined, true);
    }
    if (it.kind & 1 == 0) {
        it.done = true;
        return coroutine.iterResult(vm, r, false);
    }
    const m = try conv.toStr(vm, try props.get(vm, r.asObject(), PropKey.fromIndex(0)));
    if (m.byte_len == 0) {
        const li = try conv.toLength(vm, try props.get(vm, o, vm.k.lastIndex));
        try props.put(vm, o, vm.k.lastIndex, Value.fromUsize(try advance(s, li, it.kind & 2 != 0, vm)));
    }
    return coroutine.iterResult(vm, r, false);
}

/// Expands $-patterns of a replacement template into b.
pub fn getSubstitution(vm: *Vm, b: *str.Builder, matched: *JSString, s: *JSString, position: usize, captures: []const Value, named: Value, template: *JSString) Error!void {
    const t = try template.flat(vm);
    var i: usize = 0;
    while (i < t.len) {
        const dollar = std.mem.indexOfScalarPos(u8, t, i, '$') orelse {
            try b.bytes(t[i..]);
            break;
        };
        if (dollar > i) try b.bytes(t[i..dollar]);
        if (dollar + 1 >= t.len) {
            try b.byte('$');
            break;
        }
        i = dollar;
        const d = t[i + 1];
        switch (d) {
            '$' => {
                try b.byte('$');
                i += 2;
            },
            '&' => {
                try b.str(matched);
                i += 2;
            },
            '`' => {
                try b.sub(s, 0, position);
                i += 2;
            },
            '\'' => {
                const after = position + matched.len16;
                if (after < s.len16) try b.sub(s, after, s.len16);
                i += 2;
            },
            '0'...'9' => {
                var n: usize = d - '0';
                var used: usize = 2;
                if (i + 2 < t.len and t[i + 2] >= '0' and t[i + 2] <= '9') {
                    const two = n * 10 + (t[i + 2] - '0');
                    if (two >= 1 and two <= captures.len) {
                        n = two;
                        used = 3;
                    }
                }
                if (n >= 1 and n <= captures.len) {
                    const v = captures[n - 1];
                    if (!v.isUndefined()) try b.str(try conv.toStr(vm, v));
                    i += used;
                } else {
                    try b.byte('$');
                    i += 1;
                }
            },
            '<' => {
                if (named.isUndefined()) {
                    try b.byte('$');
                    i += 1;
                } else if (std.mem.indexOfScalarPos(u8, t, i + 2, '>')) |end| {
                    const k = try str.keyFromBytes(vm, t[i + 2 .. end]);
                    const v = try props.getV(vm, named, k);
                    if (!v.isUndefined()) try b.str(try conv.toStr(vm, v));
                    i = end + 1;
                } else {
                    try b.byte('$');
                    i += 1;
                }
            },
            else => {
                try b.byte('$');
                i += 1;
            },
        }
    }
}

pub fn replaceFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisObj(vm, this);
    const s = try conv.toStr(vm, u.arg(args, 0));
    const rv = u.arg(args, 1);
    const functional = rv.isCallable();
    const template = if (functional) vm.empty else try conv.toStr(vm, rv);
    if (re.isFastRegExp(vm, o) and (o.payload.regexp.prog.flags.global or o.slots[0].isInt())) {
        const prog = o.payload.regexp.prog;
        const pf = prog.flags;
        const full = pf.unicode or pf.unicode_sets;
        if (pf.global) o.slots[0] = Value.fromInt(0);
        var pos: usize = if (pf.global) 0 else if (pf.sticky) @intCast(@max(0, o.slots[0].asInt())) else 0;
        const total = prog.ncaps * 2 + prog.nregs;
        var stack_regs: [64]i32 = undefined;
        const regs = if (total <= stack_regs.len) stack_regs[0..total] else try vm.gpa.alloc(i32, total);
        defer if (total > stack_regs.len) vm.gpa.free(regs);
        if (pos > s.len16 or !try re.matchAt(vm, prog, s, pos, pf.sticky, regs)) {
            if (pf.global or pf.sticky) o.slots[0] = Value.fromInt(0);
            return Value.fromString(s);
        }
        if (!functional and prog.names.len == 0) {
            const t_bytes = try template.flat(vm);
            const has_dollar = std.mem.indexOfScalar(u8, t_bytes, '$') != null;
            var b = str.Builder.init(vm);
            defer b.deinit();
            var next: usize = 0;
            const ncap = prog.ncaps - 1;
            var stack_caps: [32]Value = undefined;
            const caps = if (!has_dollar or ncap == 0) stack_caps[0..0] else if (ncap <= stack_caps.len) stack_caps[0..ncap] else try vm.gpa.alloc(Value, ncap);
            defer if (has_dollar and ncap > stack_caps.len) vm.gpa.free(caps);
            while (true) {
                const m_start: usize = @intCast(regs[0]);
                const m_end: usize = @intCast(regs[1]);
                if (m_start >= next) {
                    if (m_start > next) try b.sub(s, next, m_start);
                    if (!has_dollar) {
                        try b.str(template);
                    } else {
                        const matched = try str.substring(vm, s, m_start, m_end);
                        for (caps, 0..) |*c, i| {
                            const ca = regs[(i + 1) * 2];
                            const cb = regs[(i + 1) * 2 + 1];
                            c.* = if (ca < 0 or cb < 0) Value.undefined else Value.fromString(try str.substring(vm, s, @intCast(ca), @intCast(cb)));
                        }
                        try getSubstitution(vm, &b, matched, s, m_start, caps, Value.undefined, template);
                    }
                    next = m_end;
                }
                if (!pf.global) {
                    if (pf.sticky) o.slots[0] = Value.fromUsize(m_end);
                    break;
                }
                pos = if (m_start == m_end) try advance(s, m_end, full, vm) else m_end;
                if (pos > s.len16 or !try re.matchAt(vm, prog, s, pos, pf.sticky, regs)) {
                    o.slots[0] = Value.fromInt(0);
                    break;
                }
            }
            if (next < s.len16) try b.sub(s, next, s.len16);
            return Value.fromString(try b.finish());
        }
    }
    const f = try flagsOf(vm, o);
    const global = hasFlag(f, 'g');
    const full = hasFlag(f, 'u') or hasFlag(f, 'v');
    if (global) try props.put(vm, o, vm.k.lastIndex, Value.fromInt(0));
    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.gpa);
    while (true) {
        const r = try re.regExpExec(vm, o, s);
        if (r.isNull()) break;
        try results.append(vm.gpa, r);
        if (!global) break;
        const m = try conv.toStr(vm, try props.get(vm, r.asObject(), PropKey.fromIndex(0)));
        if (m.byte_len == 0) {
            const li = try conv.toLength(vm, try props.get(vm, o, vm.k.lastIndex));
            try props.put(vm, o, vm.k.lastIndex, Value.fromUsize(try advance(s, li, full, vm)));
        }
    }
    var b = str.Builder.init(vm);
    defer b.deinit();
    var next: usize = 0;
    for (results.items) |rv2| {
        const r = rv2.asObject();
        const ncap = @max(try conv.lengthOf(vm, r), 1) - 1;
        const matched = try conv.toStr(vm, try props.get(vm, r, PropKey.fromIndex(0)));
        const pos_f = try conv.toIntegerOrInf(vm, try props.get(vm, r, vm.k.index));
        const position: usize = @intFromFloat(@max(@min(pos_f, @as(f64, @floatFromInt(s.len16))), 0));
        const caps = try vm.gpa.alloc(Value, ncap);
        defer vm.gpa.free(caps);
        for (caps, 0..) |*c, i| {
            const v = try props.get(vm, r, PropKey.fromIndex(@intCast(i + 1)));
            c.* = if (v.isUndefined()) v else Value.fromString(try conv.toStr(vm, v));
        }
        const named = try props.get(vm, r, vm.k.groups);
        var replacement: *JSString = undefined;
        if (functional) {
            var cb: std.ArrayList(Value) = .empty;
            defer cb.deinit(vm.gpa);
            try cb.append(vm.gpa, Value.fromString(matched));
            try cb.appendSlice(vm.gpa, caps);
            try cb.append(vm.gpa, Value.fromUsize(position));
            try cb.append(vm.gpa, Value.fromString(s));
            if (!named.isUndefined()) try cb.append(vm.gpa, named);
            replacement = try conv.toStr(vm, try calls.call(vm, rv, Value.undefined, cb.items));
        } else {
            var sub = str.Builder.init(vm);
            defer sub.deinit();
            const nv = if (named.isUndefined()) named else (try conv.toObject(vm, named)).value();
            try getSubstitution(vm, &sub, matched, s, position, caps, nv, template);
            replacement = try sub.finish();
        }
        if (position >= next) {
            if (position > next) try b.str(try str.substring(vm, s, next, position));
            try b.str(replacement);
            next = position + matched.len16;
        }
    }
    if (next < s.len16) try b.str(try str.substring(vm, s, next, s.len16));
    return Value.fromString(try b.finish());
}

pub fn searchFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisObj(vm, this);
    const s = try conv.toStr(vm, u.arg(args, 0));
    if (re.hasBuiltinExec(vm, o) and o.slots[0].isInt()) {
        const prog = o.payload.regexp.prog;
        const total = prog.ncaps * 2 + prog.nregs;
        var stack_regs: [64]i32 = undefined;
        const regs = if (total <= stack_regs.len) stack_regs[0..total] else try vm.gpa.alloc(i32, total);
        defer if (total > stack_regs.len) vm.gpa.free(regs);
        if (!try re.matchAt(vm, prog, s, 0, prog.flags.sticky, regs)) return Value.fromInt(-1);
        return Value.fromInt(regs[0]);
    }
    const prev = try props.get(vm, o, vm.k.lastIndex);
    if (!conv.sameValue(vm, prev, Value.fromInt(0))) try props.put(vm, o, vm.k.lastIndex, Value.fromInt(0));
    const r = try re.regExpExec(vm, o, s);
    const cur = try props.get(vm, o, vm.k.lastIndex);
    if (!conv.sameValue(vm, cur, prev)) try props.put(vm, o, vm.k.lastIndex, prev);
    if (r.isNull()) return Value.fromInt(-1);
    return props.get(vm, r.asObject(), vm.k.index);
}

pub fn splitFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisObj(vm, this);
    const s = try conv.toStr(vm, u.arg(args, 0));
    const c = try u.speciesConstructor(vm, o, vm.protos.regexp_ctor);
    if (re.isFastRegExp(vm, o) and c.isObject() and c.asObject() == vm.protos.regexp_ctor) {
        const out = try objmod.newArray(vm, &.{});
        const lim: u32 = if (u.arg(args, 1).isUndefined()) 0xFFFF_FFFF else try conv.toUint32(vm, args[1]);
        if (lim == 0) return out.value();
        const prog = o.payload.regexp.prog;
        const full = prog.flags.unicode or prog.flags.unicode_sets;
        const total = prog.ncaps * 2 + prog.nregs;
        var stack_regs: [64]i32 = undefined;
        const regs = if (total <= stack_regs.len) stack_regs[0..total] else try vm.gpa.alloc(i32, total);
        defer if (total > stack_regs.len) vm.gpa.free(regs);
        const size: usize = s.len16;
        if (size == 0) {
            if (try re.matchAt(vm, prog, s, 0, true, regs)) return out.value();
            try objmod.arrayPush(vm, out, Value.fromString(s));
            return out.value();
        }
        const can_scan = s.is_ascii or !full;
        var p: usize = 0;
        var q: usize = 0;
        while (q < size) {
            if (can_scan) {
                if (!try re.matchAt(vm, prog, s, q, false, regs)) break;
                const match_q: usize = @intCast(regs[0]);
                if (match_q >= size) break;
                q = match_q;
            } else {
                if (!try re.matchAt(vm, prog, s, q, true, regs)) {
                    q = try advance(s, q, full, vm);
                    continue;
                }
            }
            const e: usize = @min(@as(usize, @intCast(regs[1])), size);
            if (e == p) {
                q = try advance(s, q, full, vm);
                continue;
            }
            try objmod.arrayPush(vm, out, Value.fromString(try str.substring(vm, s, p, q)));
            if (out.arr_len == lim) return out.value();
            p = e;
            var i: u32 = 1;
            while (i < prog.ncaps) : (i += 1) {
                const ca = regs[i * 2];
                const cb = regs[i * 2 + 1];
                const cv = if (ca < 0 or cb < 0) Value.undefined else Value.fromString(try str.substring(vm, s, @intCast(ca), @intCast(cb)));
                try objmod.arrayPush(vm, out, cv);
                if (out.arr_len == lim) return out.value();
            }
            q = p;
        }
        try objmod.arrayPush(vm, out, Value.fromString(try str.substring(vm, s, p, size)));
        return out.value();
    }
    const f = try flagsOf(vm, o);
    const full = hasFlag(f, 'u') or hasFlag(f, 'v');
    var nf = str.Builder.init(vm);
    defer nf.deinit();
    try nf.bytes(f);
    if (!hasFlag(f, 'y')) try nf.byte('y');
    const nfs = try nf.finish();
    const splitter = (try calls.construct(vm, c, &.{ o.value(), Value.fromString(nfs) }, c)).asObject();
    const out = try objmod.newArray(vm, &.{});
    const lim: u32 = if (u.arg(args, 1).isUndefined()) 0xFFFF_FFFF else try conv.toUint32(vm, args[1]);
    if (lim == 0) return out.value();
    const size: usize = s.len16;
    if (size == 0) {
        const r = try re.regExpExec(vm, splitter, s);
        if (!r.isNull()) return out.value();
        try objmod.arrayPush(vm, out, Value.fromString(s));
        return out.value();
    }
    var p: usize = 0;
    var q: usize = 0;
    while (q < size) {
        try props.put(vm, splitter, vm.k.lastIndex, Value.fromUsize(q));
        const r = try re.regExpExec(vm, splitter, s);
        if (r.isNull()) {
            q = try advance(s, q, full, vm);
            continue;
        }
        const e_f = try conv.toLength(vm, try props.get(vm, splitter, vm.k.lastIndex));
        const e = @min(e_f, size);
        if (e == p) {
            q = try advance(s, q, full, vm);
            continue;
        }
        try objmod.arrayPush(vm, out, Value.fromString(try str.substring(vm, s, p, q)));
        if (out.arr_len == lim) return out.value();
        p = e;
        const ncap = @max(try conv.lengthOf(vm, r.asObject()), 1) - 1;
        var i: usize = 1;
        while (i <= ncap) : (i += 1) {
            try objmod.arrayPush(vm, out, try props.get(vm, r.asObject(), PropKey.fromIndex(@intCast(i))));
            if (out.arr_len == lim) return out.value();
        }
        q = p;
    }
    try objmod.arrayPush(vm, out, Value.fromString(try str.substring(vm, s, p, size)));
    return out.value();
}

pub fn init(vm: *Vm, p: *Object) Error!void {
    try u.symMethod(vm, p, vm.sym.match, "[Symbol.match]", 1, matchFn);
    try u.symMethod(vm, p, vm.sym.matchAll, "[Symbol.matchAll]", 1, matchAllFn);
    try u.symMethod(vm, p, vm.sym.replace, "[Symbol.replace]", 2, replaceFn);
    try u.symMethod(vm, p, vm.sym.search, "[Symbol.search]", 1, searchFn);
    try u.symMethod(vm, p, vm.sym.split, "[Symbol.split]", 2, splitFn);
    const ip = try u.newProto(vm, vm.protos.iterator);
    vm.protos.regexp_string_iter = ip;
    try u.method(vm, ip, "next", 0, matchAllNext);
    try u.toStringTag(vm, ip, "RegExp String Iterator");
}
