//! JS strings: WTF-8 bytes with an is_ascii flag, UTF-16 semantics on top.
//! Ascii strings index in O(1); others build a UTF-16 copy on demand. Concatenation
//! makes ropes, flattened when the bytes are first needed, so `s += x` is linear.
//! Interned strings (atoms) are the property keys and compare by pointer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const heap = @import("heap.zig");
const Cell = heap.Cell;
const Value = @import("value.zig").Value;
const PropKey = @import("value.zig").PropKey;
const Vm = @import("vm.zig").Vm;
const Error = @import("vm.zig").Error;

pub const max_length: usize = 512 * 1024 * 1024;

pub const Symbol = struct {
    cell: Cell,
    description: ?*JSString,
    is_private: bool = false,
    is_registered: bool = false,
};

pub const JSString = struct {
    cell: Cell,
    is_ascii: bool,
    is_atom: bool = false,
    is_rope: bool = false,
    has_lone: bool = false,
    owns: bool = false,
    byte_len: u32,
    len16: u32,
    ptr: [*]const u8,
    /// Rope children, or (in `right`) the parent a slice points into.
    left: ?*JSString = null,
    right: ?*JSString = null,
    u16s: ?[*]u16 = null,
    /// The cached property key for this string; zero until first used as a key.
    key: PropKey = PropKey.none,

    pub fn finalize(s: *JSString, gpa: Allocator) void {
        if (s.owns) gpa.free(@constCast(s.ptr[0..s.byte_len]));
        if (s.u16s) |u| gpa.free(u[0..s.len16]);
    }

    /// The string's bytes; flattens a rope first.
    pub inline fn flat(s: *JSString, vm: *Vm) Error![]const u8 {
        if (s.is_rope) try flatten(vm, s);
        return s.ptr[0..s.byte_len];
    }

    /// The UTF-16 code units of a non-ascii string.
    pub fn units(s: *JSString, vm: *Vm) Error![]const u16 {
        if (s.u16s) |u| return u[0..s.len16];
        const b = try s.flat(vm);
        const out = try vm.gpa.alloc(u16, s.len16);
        var n: usize = 0;
        var i: usize = 0;
        while (i < b.len) {
            const d = decode(b, i);
            i += d.len;
            if (d.cp >= 0x10000) {
                const c = d.cp - 0x10000;
                out[n] = @intCast(0xD800 + (c >> 10));
                out[n + 1] = @intCast(0xDC00 + (c & 0x3FF));
                n += 2;
            } else {
                out[n] = @intCast(d.cp);
                n += 1;
            }
        }
        s.u16s = out.ptr;
        return out;
    }

    /// The code unit at a UTF-16 index, which must be in range.
    pub fn unitAt(s: *JSString, vm: *Vm, i: usize) Error!u16 {
        if (s.is_ascii) return (try s.flat(vm))[i];
        return (try s.units(vm))[i];
    }
};

pub const Decoded = struct { cp: u32, len: u8 };

/// Decodes one code point of WTF-8 at i. Malformed bytes decode as U+FFFD, length 1.
pub fn decode(b: []const u8, i: usize) Decoded {
    const c = b[i];
    if (c < 0x80) return .{ .cp = c, .len = 1 };
    if (c >= 0xC2 and c < 0xE0 and i + 1 < b.len and b[i + 1] & 0xC0 == 0x80) {
        return .{ .cp = (@as(u32, c & 0x1F) << 6) | (b[i + 1] & 0x3F), .len = 2 };
    }
    if (c >= 0xE0 and c < 0xF0 and i + 2 < b.len and b[i + 1] & 0xC0 == 0x80 and b[i + 2] & 0xC0 == 0x80) {
        const cp = (@as(u32, c & 0x0F) << 12) | (@as(u32, b[i + 1] & 0x3F) << 6) | (b[i + 2] & 0x3F);
        if (cp >= 0x800) return .{ .cp = cp, .len = 3 };
    }
    if (c >= 0xF0 and c < 0xF5 and i + 3 < b.len and b[i + 1] & 0xC0 == 0x80 and b[i + 2] & 0xC0 == 0x80 and b[i + 3] & 0xC0 == 0x80) {
        const cp = (@as(u32, c & 0x07) << 18) | (@as(u32, b[i + 1] & 0x3F) << 12) | (@as(u32, b[i + 2] & 0x3F) << 6) | (b[i + 3] & 0x3F);
        if (cp >= 0x10000 and cp <= 0x10FFFF) return .{ .cp = cp, .len = 4 };
    }
    return .{ .cp = 0xFFFD, .len = 1 };
}

/// Encodes a code point (lone surrogates included, as WTF-8). Returns the length.
pub fn encode(cp: u32, out: []u8) usize {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = @intCast(0xF0 | (cp >> 18));
    out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    out[3] = @intCast(0x80 | (cp & 0x3F));
    return 4;
}

fn isAscii(b: []const u8) bool {
    for (b) |c| if (c >= 0x80) return false;
    return true;
}

const Scan = struct { len16: usize, has_lone: bool, valid: bool };

fn scan(b: []const u8) Scan {
    var r = Scan{ .len16 = 0, .has_lone = false, .valid = true };
    var i: usize = 0;
    while (i < b.len) {
        const d = decode(b, i);
        if (d.cp == 0xFFFD and d.len == 1) r.valid = false;
        if (d.cp >= 0xD800 and d.cp < 0xE000) r.has_lone = true;
        r.len16 += if (d.cp >= 0x10000) 2 else 1;
        i += d.len;
    }
    return r;
}

fn alloc(vm: *Vm, is_ascii: bool, ptr: [*]const u8, byte_len: usize, len16: usize) Error!*JSString {
    const s = try vm.heap.create(JSString, .string);
    s.is_ascii = is_ascii;
    s.is_atom = false;
    s.is_rope = false;
    s.has_lone = false;
    s.owns = false;
    s.byte_len = @intCast(byte_len);
    s.len16 = @intCast(len16);
    s.ptr = ptr;
    s.left = null;
    s.right = null;
    s.u16s = null;
    s.key = PropKey.none;
    return s;
}

/// Takes ownership of `bytes`, which must be `gpa`-allocated WTF-8.
pub fn adopt(vm: *Vm, bytes: []const u8) Error!*JSString {
    if (bytes.len > max_length) {
        vm.gpa.free(bytes);
        return vm.throwError(.RangeError, "Invalid string length");
    }
    if (isAscii(bytes)) {
        const s = try alloc(vm, true, bytes.ptr, bytes.len, bytes.len);
        s.owns = bytes.len != 0;
        return s;
    }
    const r = scan(bytes);
    if (!r.valid) {
        defer vm.gpa.free(bytes);
        return fromUtf8(vm, bytes);
    }
    const s = try alloc(vm, false, bytes.ptr, bytes.len, r.len16);
    s.owns = true;
    s.has_lone = r.has_lone;
    return s;
}

/// Copies UTF-8 (or WTF-8) into a new string. Malformed input becomes U+FFFD.
pub fn fromUtf8(vm: *Vm, bytes: []const u8) Error!*JSString {
    if (bytes.len == 0) return vm.empty;
    if (bytes.len > max_length) return vm.throwError(.RangeError, "Invalid string length");
    if (bytes.len == 1 and bytes[0] < 0x80) return vm.char_strs[bytes[0]];
    const r = scan(bytes);
    if (r.valid) {
        const copy = try vm.gpa.dupe(u8, bytes);
        const ascii = r.len16 == bytes.len;
        const s = try alloc(vm, ascii, copy.ptr, copy.len, r.len16);
        s.owns = true;
        s.has_lone = r.has_lone;
        return s;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(vm.gpa);
    var i: usize = 0;
    var tmp: [4]u8 = undefined;
    while (i < bytes.len) {
        const d = decode(bytes, i);
        i += d.len;
        const n = encode(d.cp, &tmp);
        try out.appendSlice(vm.gpa, tmp[0..n]);
    }
    return adopt(vm, try out.toOwnedSlice(vm.gpa));
}

/// A string from UTF-16 code units; surrogate pairs merge, lone ones stay as WTF-8.
pub fn fromUtf16(vm: *Vm, u: []const u16) Error!*JSString {
    if (u.len == 0) return vm.empty;
    if (u.len == 1 and u[0] < 0x80) return vm.char_strs[u[0]];
    var size: usize = 0;
    var i: usize = 0;
    var lone = false;
    while (i < u.len) : (i += 1) {
        const c = u[i];
        if (c < 0x80) {
            size += 1;
        } else if (c < 0x800) {
            size += 2;
        } else if (c >= 0xD800 and c < 0xDC00 and i + 1 < u.len and u[i + 1] >= 0xDC00 and u[i + 1] < 0xE000) {
            size += 4;
            i += 1;
        } else {
            if (c >= 0xD800 and c < 0xE000) lone = true;
            size += 3;
        }
    }
    const buf = try vm.gpa.alloc(u8, size);
    var n: usize = 0;
    i = 0;
    while (i < u.len) : (i += 1) {
        var cp: u32 = u[i];
        if (cp >= 0xD800 and cp < 0xDC00 and i + 1 < u.len and u[i + 1] >= 0xDC00 and u[i + 1] < 0xE000) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (u[i + 1] - 0xDC00);
            i += 1;
        }
        n += encode(cp, buf[n..]);
    }
    const s = try alloc(vm, size == u.len, buf.ptr, size, u.len);
    s.owns = true;
    s.has_lone = lone;
    return s;
}

/// The interned string with these bytes.
pub fn intern(vm: *Vm, bytes: []const u8) Error!*JSString {
    if (vm.atoms.get(bytes)) |a| return a;
    const r = scan(bytes);
    if (!r.valid) {
        const s = try fromUtf8(vm, bytes);
        return internString(vm, s);
    }
    const copy = try vm.gpa.dupe(u8, bytes);
    const s = try alloc(vm, r.len16 == bytes.len, copy.ptr, copy.len, r.len16);
    s.owns = copy.len != 0;
    s.has_lone = r.has_lone;
    s.is_atom = true;
    try vm.atoms.put(vm.gpa, copy, s);
    return s;
}

/// The interned string equal to s, keeping s itself as the atom when none exists yet.
pub fn internString(vm: *Vm, s: *JSString) Error!*JSString {
    if (s.is_atom) return s;
    const b = try s.flat(vm);
    if (vm.atoms.get(b)) |a| return a;
    s.is_atom = true;
    try vm.atoms.put(vm.gpa, b, s);
    return s;
}

/// The property key for a string: a canonical array index, or its atom.
pub fn toKey(vm: *Vm, s: *JSString) Error!PropKey {
    if (s.key.bits != 0) return s.key;
    const b = try s.flat(vm);
    if (parseIndex(b)) |i| {
        s.key = PropKey.fromIndex(i);
        return s.key;
    }
    const a = try internString(vm, s);
    s.key = PropKey.fromAtom(a);
    return s.key;
}

/// Parses a canonical array index: decimal, no leading zeros, below 2^32-1.
pub fn parseIndex(b: []const u8) ?u32 {
    if (b.len == 0 or b.len > 10) return null;
    if (b[0] == '0') return if (b.len == 1) 0 else null;
    var n: u64 = 0;
    for (b) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
    }
    if (n >= 0xFFFF_FFFF) return null;
    return @intCast(n);
}

pub fn keyFromBytes(vm: *Vm, bytes: []const u8) Error!PropKey {
    if (parseIndex(bytes)) |i| return PropKey.fromIndex(i);
    return PropKey.fromAtom(try intern(vm, bytes));
}

/// a + b. Short results copy; long ones make a rope.
pub fn concat(vm: *Vm, a: *JSString, b: *JSString) Error!*JSString {
    if (a.byte_len == 0) return b;
    if (b.byte_len == 0) return a;
    const total: usize = @as(usize, a.byte_len) + b.byte_len;
    if (total > max_length) return vm.throwError(.RangeError, "Invalid string length");
    if (a.has_lone and b.has_lone) {
        // A high surrogate meeting a low one must merge into a single code point.
        const ua = try a.units(vm);
        const ub = try b.units(vm);
        const buf = try vm.gpa.alloc(u16, ua.len + ub.len);
        defer vm.gpa.free(buf);
        @memcpy(buf[0..ua.len], ua);
        @memcpy(buf[ua.len..], ub);
        return fromUtf16(vm, buf);
    }
    const ascii = a.is_ascii and b.is_ascii;
    const len16: usize = @as(usize, a.len16) + b.len16;
    if (total < 24 and !a.is_rope and !b.is_rope) {
        const buf = try vm.gpa.alloc(u8, total);
        @memcpy(buf[0..a.byte_len], a.ptr[0..a.byte_len]);
        @memcpy(buf[a.byte_len..], b.ptr[0..b.byte_len]);
        const s = try alloc(vm, ascii, buf.ptr, total, len16);
        s.owns = true;
        s.has_lone = a.has_lone or b.has_lone;
        return s;
    }
    const s = try alloc(vm, ascii, a.ptr, total, len16);
    s.is_rope = true;
    s.left = a;
    s.right = b;
    s.has_lone = a.has_lone or b.has_lone;
    return s;
}

fn flatten(vm: *Vm, root: *JSString) Error!void {
    const buf = try vm.gpa.alloc(u8, root.byte_len);
    // Fill from the end, walking right children first with an explicit stack.
    var stack: std.ArrayList(*JSString) = .empty;
    defer stack.deinit(vm.gpa);
    try stack.append(vm.gpa, root);
    var end: usize = buf.len;
    while (stack.pop()) |top| {
        var n = top;
        while (n.is_rope) {
            try stack.append(vm.gpa, n.left.?);
            n = n.right.?;
        }
        end -= n.byte_len;
        @memcpy(buf[end..][0..n.byte_len], n.ptr[0..n.byte_len]);
    }
    root.ptr = buf.ptr;
    root.left = null;
    root.right = null;
    root.is_rope = false;
    root.owns = true;
}

/// The substring over UTF-16 indices [start, end).
pub fn substring(vm: *Vm, s: *JSString, start: usize, end: usize) Error!*JSString {
    if (start >= end) return vm.empty;
    if (start == 0 and end == s.len16) return s;
    if (s.is_ascii) {
        const b = try s.flat(vm);
        if (end - start == 1) return vm.char_strs[b[start]];
        if (end - start < 32) return fromUtf8(vm, b[start..end]);
        const r = try alloc(vm, true, b.ptr + start, end - start, end - start);
        r.right = s;
        return r;
    }
    return fromUtf16(vm, (try s.units(vm))[start..end]);
}

pub fn eql(vm: *Vm, a: *JSString, b: *JSString) Error!bool {
    if (a == b) return true;
    if (a.byte_len != b.byte_len or a.len16 != b.len16) return false;
    if (a.is_atom and b.is_atom) return false;
    return std.mem.eql(u8, try a.flat(vm), try b.flat(vm));
}

/// Three-way compare by UTF-16 code units.
pub fn compare(vm: *Vm, a: *JSString, b: *JSString) Error!std.math.Order {
    if (a.is_ascii and b.is_ascii) return std.mem.order(u8, try a.flat(vm), try b.flat(vm));
    const ua = try toUnits(vm, a);
    defer ua.deinit(vm);
    const ub = try toUnits(vm, b);
    defer ub.deinit(vm);
    return std.mem.order(u16, ua.items, ub.items);
}

/// UTF-16 units of any string; ascii ones are widened into a temporary.
pub const Units = struct {
    items: []const u16,
    owned: bool,
    pub fn deinit(u: Units, vm: *Vm) void {
        if (u.owned) vm.gpa.free(u.items);
    }
};

pub fn toUnits(vm: *Vm, s: *JSString) Error!Units {
    if (!s.is_ascii) return .{ .items = try s.units(vm), .owned = false };
    const b = try s.flat(vm);
    const out = try vm.gpa.alloc(u16, b.len);
    for (b, out) |c, *o| o.* = c;
    return .{ .items = out, .owned = true };
}

pub fn fromCodeUnit(vm: *Vm, c: u16) Error!*JSString {
    if (c < 0x80) return vm.char_strs[c];
    const one = [1]u16{c};
    return fromUtf16(vm, &one);
}

pub fn fromCodePoint(vm: *Vm, cp: u32) Error!*JSString {
    var buf: [4]u8 = undefined;
    const n = encode(cp, &buf);
    return fromUtf8(vm, buf[0..n]);
}

pub fn newSymbol(vm: *Vm, description: ?*JSString) Error!*Symbol {
    const s = try vm.heap.create(Symbol, .symbol);
    s.description = description;
    s.is_private = false;
    s.is_registered = false;
    return s;
}

/// The key as a JS value: a string for atoms and indices, a symbol otherwise.
pub fn keyToValue(vm: *Vm, k: PropKey) Error!Value {
    if (k.isSymbol()) return Value.fromSymbol(k.symbol());
    if (k.isAtom()) return Value.fromString(k.atom());
    var buf: [16]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "{d}", .{k.index()}) catch unreachable;
    return Value.fromString(try fromUtf8(vm, t));
}

/// Writes the string form of a key for messages; symbols print as their description.
pub fn keyText(vm: *Vm, k: PropKey, buf: []u8) []const u8 {
    if (k.isIndex()) return std.fmt.bufPrint(buf, "{d}", .{k.index()}) catch "?";
    if (k.isSymbol()) {
        const d = k.symbol().description orelse return "Symbol()";
        return d.flat(vm) catch "Symbol()";
    }
    return k.atom().flat(vm) catch "?";
}

/// Grows a UTF-8 result piece by piece, then adopts it as a string.
pub const Builder = struct {
    vm: *Vm,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(vm: *Vm) Builder {
        return .{ .vm = vm };
    }
    pub fn deinit(b: *Builder) void {
        b.buf.deinit(b.vm.gpa);
    }
    pub fn bytes(b: *Builder, s: []const u8) Error!void {
        try b.buf.appendSlice(b.vm.gpa, s);
    }
    pub fn byte(b: *Builder, c: u8) Error!void {
        try b.buf.append(b.vm.gpa, c);
    }
    pub fn str(b: *Builder, s: *JSString) Error!void {
        try b.bytes(try s.flat(b.vm));
    }
    pub fn cp(b: *Builder, c: u32) Error!void {
        var t: [4]u8 = undefined;
        const n = encode(c, &t);
        try b.bytes(t[0..n]);
    }
    pub fn print(b: *Builder, comptime f: []const u8, args: anytype) Error!void {
        var t: [128]u8 = undefined;
        try b.bytes(std.fmt.bufPrint(&t, f, args) catch unreachable);
    }
    pub fn finish(b: *Builder) Error!*JSString {
        if (b.buf.items.len == 0) return b.vm.empty;
        return adopt(b.vm, try b.buf.toOwnedSlice(b.vm.gpa));
    }
};
