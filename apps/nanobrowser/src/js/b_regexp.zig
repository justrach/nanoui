//! RegExp objects: construction with a compile cache, exec producing the match array,
//! the flag getters, test and toString. The Symbol.* protocol methods are in b_regexp_sym.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const heap = @import("heap.zig");
const u = @import("b_util.zig");
const Value = u.Value;
const PropKey = u.PropKey;
const Object = u.Object;
const PropFlags = u.PropFlags;
const objmod = @import("object.zig");
const shape = @import("shape.zig");
const props = @import("props.zig");
const conv = @import("conv.zig");
const ops = @import("ops.zig");
const str = @import("string.zig");
const JSString = str.JSString;
const calls = @import("interp_call.zig");
const rp = @import("regexp_parse.zig");
const rc = @import("regexp_compile.zig");
const rx = @import("regexp_exec.zig");
const sym = @import("b_regexp_sym.zig");

pub const RegExpData = struct {
    source: *JSString,
    flags: *JSString,
    prog: *rc.Program,

    pub fn trace(d: *RegExpData, m: *heap.Marker) void {
        m.markStr(d.source);
        m.markStr(d.flags);
    }
    pub fn destroy(d: *RegExpData, gpa: Allocator) void {
        d.prog.release(gpa);
        gpa.destroy(d);
    }
};

const cache_max = 512;

/// The compiled program for this pattern and flags, sharing one per distinct source.
fn programFor(vm: *Vm, pattern: *JSString, flags: *JSString) Error!*rc.Program {
    const pb = try pattern.flat(vm);
    const fb = try flags.flat(vm);
    const key_len = pb.len + fb.len + 1;
    var stack_key: [256]u8 = undefined;
    var heap_key: ?[]u8 = null;
    defer if (heap_key) |hk| vm.gpa.free(hk);
    const lookup_key: []u8 = if (key_len <= stack_key.len) stack_key[0..key_len] else blk: {
        const hk = try vm.gpa.alloc(u8, key_len);
        heap_key = hk;
        break :blk hk;
    };
    @memcpy(lookup_key[0..fb.len], fb);
    lookup_key[fb.len] = '/';
    @memcpy(lookup_key[fb.len + 1 .. key_len], pb);
    if (vm.regex_cache.get(lookup_key)) |p| {
        p.refs += 1;
        return p;
    }
    const f = rp.Flags.parse(fb) orelse return vm.throwError(.SyntaxError, "Invalid flags supplied to RegExp constructor");
    var cps: std.ArrayList(u32) = .empty;
    defer cps.deinit(vm.gpa);
    var i: usize = 0;
    while (i < pb.len) {
        const d = str.decode(pb, i);
        i += d.len;
        try cps.append(vm.gpa, d.cp);
    }
    const r = try rc.compile(vm.gpa, cps.items, f);
    const prog = switch (r) {
        .program => |p| p,
        .err => |msg| {
            var b: [300]u8 = undefined;
            const m = std.fmt.bufPrint(&b, "Invalid regular expression: /{s}/: {s}", .{ pb[0..@min(pb.len, 200)], msg }) catch "Invalid regular expression";
            return vm.throwError(.SyntaxError, m);
        },
    };
    errdefer prog.release(vm.gpa);
    if (vm.regex_cache.count() >= cache_max) clearCache(vm);
    const owned_key = if (heap_key) |hk| blk: {
        heap_key = null;
        break :blk hk;
    } else try vm.gpa.dupe(u8, lookup_key);
    errdefer vm.gpa.free(owned_key);
    try vm.regex_cache.put(vm.gpa, owned_key, prog);
    prog.refs += 1;
    return prog;
}

pub fn clearCache(vm: *Vm) void {
    var it = vm.regex_cache.iterator();
    while (it.next()) |e| {
        vm.gpa.free(e.key_ptr.*);
        e.value_ptr.*.release(vm.gpa);
    }
    vm.regex_cache.clearRetainingCapacity();
}

/// A new RegExp object; lastIndex is always its first slot.
pub fn create(vm: *Vm, pattern: *JSString, flags: *JSString, proto: *Object) Error!Value {
    const prog = try programFor(vm, pattern, flags);
    errdefer prog.release(vm.gpa);
    const d = try vm.gpa.create(RegExpData);
    errdefer vm.gpa.destroy(d);
    d.* = .{ .source = pattern, .flags = flags, .prog = prog };
    const sh = if (proto == vm.protos.regexp)
        vm.regexp_shape
    else
        try shape.transition(vm, try shape.rootFor(vm, proto), vm.k.lastIndex, .{ .enumerable = false, .configurable = false });
    const o = try objmod.alloc(vm, sh, .regexp);
    o.payload = .{ .regexp = d };
    o.slots[0] = Value.fromInt(0);
    return o.value();
}

fn regexpCtor(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const pat = u.arg(args, 0);
    const flg = u.arg(args, 1);
    const pat_is_re = pat.isObject() and pat.asObject().class == .regexp;
    if (vm.new_target.isUndefined() and pat_is_re and flg.isUndefined()) {
        const c = try props.get(vm, pat.asObject(), vm.k.constructor);
        if (c.isObject() and c.asObject() == vm.protos.regexp_ctor) return pat;
    }
    var source: *JSString = vm.empty;
    var flags: *JSString = vm.empty;
    if (pat_is_re) {
        const d = pat.asObject().payload.regexp;
        source = d.source;
        flags = if (flg.isUndefined()) d.flags else try conv.toStr(vm, flg);
    } else {
        if (!pat.isUndefined()) source = try conv.toStr(vm, pat);
        if (!flg.isUndefined()) flags = try conv.toStr(vm, flg);
    }
    const proto = if (vm.new_target.isUndefined()) vm.protos.regexp else try calls.protoFromNewTarget(vm, vm.protos.regexp);
    return create(vm, source, flags, proto);
}

fn deadlineTick(ctx: ?*anyopaque) bool {
    const vm: *Vm = @ptrCast(@alignCast(ctx.?));
    const dl = vm.deadline orelse return true;
    return conv.monotonicNs() < dl;
}

/// Runs the program against a string; capture pairs land in regs (from a shared buffer).
pub fn matchAt(vm: *Vm, prog: *const rc.Program, s: *JSString, start: usize, sticky: bool, regs: []i32) Error!bool {
    const tick = rx.Tick{ .ctx = vm, .f = deadlineTick };
    const r = if (s.is_ascii)
        rx.exec(u8, vm.gpa, prog, try s.flat(vm), start, sticky, regs, tick)
    else
        rx.exec(u16, vm.gpa, prog, try s.units(vm), start, sticky, regs, tick);
    return r catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooComplex => return vm.throwError(.RangeError, "Regular expression too complex"),
        error.Interrupted => {
            vm.deadline = null;
            return error.Terminated;
        },
    };
}

pub fn setLastIndex(vm: *Vm, o: *Object, n: usize) Error!void {
    if (o.class == .regexp and o.shape.count >= 1) {
        const flags = o.shape.table.entries.items[0].flags;
        if (flags.writable and !flags.accessor) {
            o.slots[0] = Value.fromUsize(n);
            return;
        }
    }
    try props.put(vm, o, vm.k.lastIndex, Value.fromUsize(n));
}

pub inline fn isFastRegExp(vm: *Vm, o: *Object) bool {
    return o.class == .regexp and !o.shape.is_dict and o.shape.count == 1 and o.shape.proto == vm.protos.regexp and !vm.protos.regexp.flags.proto_dirty;
}

pub fn hasBuiltinExec(vm: *Vm, o: *Object) bool {
    if (isFastRegExp(vm, o)) return true;
    if (o.class != .regexp or o.shape.count != 1 or o.shape.proto != vm.protos.regexp) return false;
    const slot = vm.protos.regexp.shape.find(vm.k.exec) orelse return false;
    const flags = vm.protos.regexp.shape.flagsAt(slot);
    return !flags.accessor and vm.protos.regexp.slots[slot].isObject() and vm.protos.regexp.slots[slot].asObject() == vm.protos.regexp_exec;
}

fn matchIndicesArray(vm: *Vm, regs: []const i32, ncaps: u32, names: []const rp.GroupName) Error!Value {
    const arr = try objmod.newArray(vm, &.{});
    var i: u32 = 0;
    while (i < ncaps) : (i += 1) {
        if (regs[i * 2] < 0 or regs[i * 2 + 1] < 0) {
            try objmod.arrayPush(vm, arr, Value.undefined);
        } else {
            const pair = [_]Value{ Value.fromInt(regs[i * 2]), Value.fromInt(regs[i * 2 + 1]) };
            try objmod.arrayPush(vm, arr, (try objmod.newArray(vm, &pair)).value());
        }
    }
    var groups = Value.undefined;
    if (names.len != 0) {
        const g = try objmod.create(vm, null, .object);
        for (names) |n| {
            const k = try str.keyFromBytes(vm, n.name);
            try props.defineData(vm, g, k, arr.elems[n.index], PropFlags.all);
        }
        groups = g.value();
    }
    try props.addProp(vm, arr, vm.k.groups, groups, PropFlags.all);
    return arr.value();
}

/// Fast boolean match for RegExp.prototype.test without allocating a match Array.
pub fn builtinTest(vm: *Vm, o: *Object, s: *JSString) Error!bool {
    const d = o.payload.regexp;
    const prog = d.prog;
    const f = prog.flags;
    const li: usize = if (o.slots[0].isInt()) @intCast(@max(0, o.slots[0].asInt())) else try conv.toLength(vm, o.slots[0]);
    const uses_last = f.global or f.sticky;
    const start = if (uses_last) li else 0;
    if (start > s.len16) {
        if (uses_last) try setLastIndex(vm, o, 0);
        return false;
    }
    const total = prog.ncaps * 2 + prog.nregs;
    var stack_regs: [64]i32 = undefined;
    const regs = if (total <= stack_regs.len) stack_regs[0..total] else try vm.gpa.alloc(i32, total);
    defer if (total > stack_regs.len) vm.gpa.free(regs);
    if (!try matchAt(vm, prog, s, start, f.sticky, regs)) {
        if (uses_last) try setLastIndex(vm, o, 0);
        return false;
    }
    if (uses_last) try setLastIndex(vm, o, @intCast(regs[1]));
    return true;
}

/// RegExpBuiltinExec: a match array, or null.
pub fn builtinExec(vm: *Vm, o: *Object, s: *JSString) Error!Value {
    const d = o.payload.regexp;
    const prog = d.prog;
    const f = prog.flags;
    const li: usize = if (o.slots[0].isInt()) @intCast(@max(0, o.slots[0].asInt())) else try conv.toLength(vm, o.slots[0]);
    const uses_last = f.global or f.sticky;
    const start = if (uses_last) li else 0;
    if (start > s.len16) {
        if (uses_last) try setLastIndex(vm, o, 0);
        return Value.null;
    }
    const total = prog.ncaps * 2 + prog.nregs;
    var stack_regs: [64]i32 = undefined;
    const regs = if (total <= stack_regs.len) stack_regs[0..total] else try vm.gpa.alloc(i32, total);
    defer if (total > stack_regs.len) vm.gpa.free(regs);
    if (!try matchAt(vm, prog, s, start, f.sticky, regs)) {
        if (uses_last) try setLastIndex(vm, o, 0);
        return Value.null;
    }
    if (uses_last) try setLastIndex(vm, o, @intCast(regs[1]));
    const arr = try objmod.alloc(vm, vm.regexp_match_shape, .array);
    if (!f.has_indices and prog.ncaps <= objmod.inline_slots - 3) {
        arr.slot_cap = 3;
        arr.elems = @as([*]Value, &arr.inline_store) + 3;
        arr.elems_cap = objmod.inline_slots - 3;
    } else {
        try objmod.growElems(vm, arr, prog.ncaps);
    }
    var i: u32 = 0;
    while (i < prog.ncaps) : (i += 1) {
        const a = regs[i * 2];
        const b = regs[i * 2 + 1];
        arr.elems[i] = if (a < 0 or b < 0)
            Value.undefined
        else
            Value.fromString(try str.substring(vm, s, @intCast(a), @intCast(b)));
    }
    arr.elems_len = prog.ncaps;
    arr.arr_len = prog.ncaps;
    arr.slots[0] = Value.fromInt(regs[0]);
    arr.slots[1] = Value.fromString(s);
    var groups = Value.undefined;
    if (prog.names.len != 0) {
        const g = try objmod.create(vm, null, .object);
        for (prog.names) |n| {
            const k = try str.keyFromBytes(vm, n.name);
            try props.defineData(vm, g, k, arr.elems[n.index], PropFlags.all);
        }
        groups = g.value();
    }
    arr.slots[2] = groups;
    if (f.has_indices) {
        try props.addProp(vm, arr, vm.k.indices, try matchIndicesArray(vm, regs, prog.ncaps, prog.names), PropFlags.all);
    }
    return arr.value();
}

/// RegExpExec: honours a user-replaced exec method.
pub fn regExpExec(vm: *Vm, o: *Object, s: *JSString) Error!Value {
    if (hasBuiltinExec(vm, o)) return builtinExec(vm, o, s);
    const e = try props.get(vm, o, vm.k.exec);
    if (e.isCallable() and !(e.asObject() == vm.protos.regexp_exec and o.class == .regexp)) {
        const r = try calls.call(vm, e, o.value(), &.{Value.fromString(s)});
        if (!r.isObject() and !r.isNull()) return vm.throwError(.TypeError, "object null or function expected");
        return r;
    }
    if (o.class != .regexp) return vm.throwError(.TypeError, "RegExp.prototype.exec called on incompatible receiver");
    return builtinExec(vm, o, s);
}

fn thisRe(vm: *Vm, this: Value) Error!*Object {
    if (this.isObject() and this.asObject().class == .regexp) return this.asObject();
    return vm.throwError(.TypeError, "RegExp method called on incompatible receiver");
}

fn execFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return builtinExec(vm, try thisRe(vm, this), try conv.toStr(vm, u.arg(args, 0)));
}

fn testFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    if (!this.isObject()) return vm.throwError(.TypeError, "RegExp.prototype.test called on non-object");
    const o = this.asObject();
    const s = try conv.toStr(vm, u.arg(args, 0));
    if (hasBuiltinExec(vm, o)) return Value.fromBool(try builtinTest(vm, o, s));
    const e = try props.get(vm, o, vm.k.exec);
    if (e.isCallable() and !(e.asObject() == vm.protos.regexp_exec and o.class == .regexp)) {
        const r = try calls.call(vm, e, o.value(), &.{Value.fromString(s)});
        if (!r.isObject() and !r.isNull()) return vm.throwError(.TypeError, "object null or function expected");
        return Value.fromBool(!r.isNull());
    }
    if (o.class != .regexp) return vm.throwError(.TypeError, "RegExp.prototype.exec called on incompatible receiver");
    return Value.fromBool(try builtinTest(vm, o, s));
}

/// EscapeRegExpPattern for the source getter: a newline or bare slash must not appear raw.
fn escapedSource(vm: *Vm, s: *JSString) Error!*JSString {
    const t = try s.flat(vm);
    if (t.len == 0) return str.fromUtf8(vm, "(?:)");
    var needs = false;
    var in_class = false;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        const c = t[i];
        if (c == '\\') {
            i += 1;
        } else if (c == '[') {
            in_class = true;
        } else if (c == ']') {
            in_class = false;
        } else if (c == '\n' or (c == '/' and !in_class)) {
            needs = true;
        }
    }
    if (!needs) return s;
    var b = str.Builder.init(vm);
    defer b.deinit();
    in_class = false;
    i = 0;
    while (i < t.len) : (i += 1) {
        const c = t[i];
        if (c == '\\' and i + 1 < t.len) {
            try b.byte(c);
            i += 1;
            try b.byte(t[i]);
            continue;
        }
        if (c == '[') in_class = true;
        if (c == ']') in_class = false;
        if (c == '\n') {
            try b.bytes("\\n");
        } else if (c == '/' and !in_class) {
            try b.bytes("\\/");
        } else try b.byte(c);
    }
    return b.finish();
}

fn sourceGet(vm: *Vm, this: Value, _: []const Value) Error!Value {
    if (this.isObject() and this.asObject() == vm.protos.regexp) return Value.fromString(try str.fromUtf8(vm, "(?:)"));
    return Value.fromString(try escapedSource(vm, (try thisRe(vm, this)).payload.regexp.source));
}

pub fn formatFlags(pf: rp.Flags, buf: *[8]u8) []const u8 {
    var len: usize = 0;
    if (pf.has_indices) {
        buf[len] = 'd';
        len += 1;
    }
    if (pf.global) {
        buf[len] = 'g';
        len += 1;
    }
    if (pf.ignore_case) {
        buf[len] = 'i';
        len += 1;
    }
    if (pf.multiline) {
        buf[len] = 'm';
        len += 1;
    }
    if (pf.dot_all) {
        buf[len] = 's';
        len += 1;
    }
    if (pf.unicode) {
        buf[len] = 'u';
        len += 1;
    }
    if (pf.unicode_sets) {
        buf[len] = 'v';
        len += 1;
    }
    if (pf.sticky) {
        buf[len] = 'y';
        len += 1;
    }
    return buf[0..len];
}

fn flagsGet(vm: *Vm, this: Value, _: []const Value) Error!Value {
    if (!this.isObject()) return vm.throwError(.TypeError, "RegExp.prototype.flags getter called on non-object");
    const o = this.asObject();
    if (isFastRegExp(vm, o)) {
        var buf: [8]u8 = undefined;
        return Value.fromString(try str.fromUtf8(vm, formatFlags(o.payload.regexp.prog.flags, &buf)));
    }
    var b = str.Builder.init(vm);
    defer b.deinit();
    const table = [_]struct { name: []const u8, c: u8 }{
        .{ .name = "hasIndices", .c = 'd' },  .{ .name = "global", .c = 'g' }, .{ .name = "ignoreCase", .c = 'i' },
        .{ .name = "multiline", .c = 'm' },   .{ .name = "dotAll", .c = 's' }, .{ .name = "unicode", .c = 'u' },
        .{ .name = "unicodeSets", .c = 'v' }, .{ .name = "sticky", .c = 'y' },
    };
    for (table) |t| {
        if (ops.truthy(try props.get(vm, o, try str.keyFromBytes(vm, t.name)))) try b.byte(t.c);
    }
    return Value.fromString(try b.finish());
}

fn flagGetter(comptime field: []const u8) objmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, _: []const Value) Error!Value {
            if (this.isObject() and this.asObject() == vm.protos.regexp) return Value.undefined;
            return Value.fromBool(@field((try thisRe(vm, this)).payload.regexp.prog.flags, field));
        }
    }.f;
}

fn toStringFn(vm: *Vm, this: Value, _: []const Value) Error!Value {
    if (!this.isObject()) return vm.throwError(.TypeError, "RegExp.prototype.toString requires that 'this' be an Object");
    const o = this.asObject();
    var b = str.Builder.init(vm);
    defer b.deinit();
    try b.byte('/');
    try b.str(try conv.toStr(vm, try props.get(vm, o, vm.k.source)));
    try b.byte('/');
    try b.str(try conv.toStr(vm, try props.get(vm, o, vm.k.flags)));
    return Value.fromString(try b.finish());
}

/// Legacy compile(), which some old libraries still call.
fn compileFn(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = try thisRe(vm, this);
    const pat = u.arg(args, 0);
    const d = o.payload.regexp;
    const source = if (pat.isUndefined()) vm.empty else if (pat.isObject() and pat.asObject().class == .regexp) pat.asObject().payload.regexp.source else try conv.toStr(vm, pat);
    const flags = if (pat.isObject() and pat.asObject().class == .regexp) pat.asObject().payload.regexp.flags else if (u.arg(args, 1).isUndefined()) vm.empty else try conv.toStr(vm, args[1]);
    const prog = try programFor(vm, source, flags);
    d.prog.release(vm.gpa);
    d.prog = prog;
    d.source = source;
    d.flags = flags;
    try setLastIndex(vm, o, 0);
    return this;
}

pub fn init(vm: *Vm) Error!void {
    const p = try u.newProto(vm, vm.protos.object);
    vm.protos.regexp = p;
    vm.regexp_shape = try shape.transition(vm, try shape.rootFor(vm, p), vm.k.lastIndex, .{ .enumerable = false, .configurable = false });
    var ms = vm.array_root;
    ms = try shape.transition(vm, ms, vm.k.index, PropFlags.all);
    ms = try shape.transition(vm, ms, vm.k.input, PropFlags.all);
    ms = try shape.transition(vm, ms, vm.k.groups, PropFlags.all);
    vm.regexp_match_shape = ms;
    const c = try u.ctor(vm, "RegExp", 2, regexpCtor, p);
    vm.protos.regexp_ctor = c;
    try u.symGetter(vm, c, vm.sym.species, "get [Symbol.species]", u.returnThis);
    try u.method(vm, p, "exec", 1, execFn);
    vm.protos.regexp_exec = (try props.get(vm, p, vm.k.exec)).asObject();
    try u.method(vm, p, "test", 1, testFn);
    try u.method(vm, p, "toString", 0, toStringFn);
    try u.method(vm, p, "compile", 2, compileFn);
    try u.getter(vm, p, "source", sourceGet);
    try u.getter(vm, p, "flags", flagsGet);
    try u.getter(vm, p, "global", flagGetter("global"));
    try u.getter(vm, p, "ignoreCase", flagGetter("ignore_case"));
    try u.getter(vm, p, "multiline", flagGetter("multiline"));
    try u.getter(vm, p, "dotAll", flagGetter("dot_all"));
    try u.getter(vm, p, "unicode", flagGetter("unicode"));
    try u.getter(vm, p, "unicodeSets", flagGetter("unicode_sets"));
    try u.getter(vm, p, "sticky", flagGetter("sticky"));
    try u.getter(vm, p, "hasIndices", flagGetter("has_indices"));
    try sym.init(vm, p);
    p.flags.is_proto = true;
    p.flags.proto_dirty = false;
}
