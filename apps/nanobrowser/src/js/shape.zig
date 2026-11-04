//! Hidden classes. A shape names an object's prototype and its property layout.
//! Shapes form a transition tree rooted per prototype; a lineage shares one table
//! so adding a property never rebuilds it. Deleting or re-flagging a property moves
//! the object to a private dictionary shape that mutates in place and is never cached.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const PropKey = @import("value.zig").PropKey;
const heap = @import("heap.zig");
const Object = @import("object.zig").Object;
const Vm = @import("vm.zig").Vm;
const Error = @import("vm.zig").Error;

pub const PropFlags = packed struct(u8) {
    writable: bool = true,
    enumerable: bool = true,
    configurable: bool = true,
    accessor: bool = false,
    _pad: u4 = 0,

    pub const all = PropFlags{};
    pub const hidden = PropFlags{ .enumerable = false };
    pub const readonly = PropFlags{ .writable = false, .enumerable = false, .configurable = false };
    pub const config_only = PropFlags{ .writable = false, .enumerable = false };
};

pub const Entry = struct { key: PropKey, flags: PropFlags };

/// Keys in insertion order, plus an open-addressing index once past a few entries.
pub const Table = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Entry index + 1; 0 is empty, tombstone is deleted.
    index: []u32 = &.{},
    used: u32 = 0,
    refs: u32 = 1,

    const tombstone = std.math.maxInt(u32);
    const linear_max = 8;

    fn release(t: *Table, gpa: Allocator) void {
        t.refs -= 1;
        if (t.refs != 0) return;
        t.entries.deinit(gpa);
        gpa.free(t.index);
        gpa.destroy(t);
    }

    fn rebuildIndex(t: *Table, gpa: Allocator) Allocator.Error!void {
        var cap: usize = 32;
        while (cap < t.entries.items.len * 2 + 2) cap *= 2;
        const idx = try gpa.alloc(u32, cap);
        @memset(idx, 0);
        gpa.free(t.index);
        t.index = idx;
        t.used = 0;
        for (t.entries.items, 0..) |e, i| {
            if (e.key.bits != 0) t.indexInsert(e.key, @intCast(i));
        }
    }

    inline fn indexInsert(t: *Table, key: PropKey, i: u32) void {
        const mask = t.index.len - 1;
        var h: usize = key.hash() & mask;
        while (t.index[h] != 0 and t.index[h] != tombstone) h = (h + 1) & mask;
        if (t.index[h] == 0) t.used += 1;
        t.index[h] = i + 1;
    }

    fn append(t: *Table, gpa: Allocator, key: PropKey, flags: PropFlags) Allocator.Error!void {
        try t.entries.append(gpa, .{ .key = key, .flags = flags });
        if (t.entries.items.len > linear_max) {
            if (t.index.len == 0 or (t.used + 1) * 3 > t.index.len * 2) {
                try t.rebuildIndex(gpa);
            } else {
                t.indexInsert(key, @intCast(t.entries.items.len - 1));
            }
        }
    }

    fn find(t: *const Table, key: PropKey, count: u32) ?u32 {
        if (t.index.len == 0) {
            const es = t.entries.items[0..count];
            for (es, 0..) |e, i| {
                if (e.key.bits == key.bits) return @intCast(i);
            }
            return null;
        }
        const mask = t.index.len - 1;
        var h: usize = key.hash() & mask;
        while (true) {
            const v = t.index[h];
            if (v == 0) return null;
            if (v != tombstone and t.entries.items[v - 1].key.bits == key.bits) {
                return if (v - 1 < count) v - 1 else null;
            }
            h = (h + 1) & mask;
        }
    }

    fn removeFromIndex(t: *Table, key: PropKey) void {
        if (t.index.len == 0) return;
        const mask = t.index.len - 1;
        var h: usize = key.hash() & mask;
        while (true) {
            const v = t.index[h];
            if (v == 0) return;
            if (v != tombstone and t.entries.items[v - 1].key.bits == key.bits) {
                t.index[h] = tombstone;
                return;
            }
            h = (h + 1) & mask;
        }
    }
};

const TransKey = struct { key: u64, flags: u8 };

pub const Shape = struct {
    cell: heap.Cell,
    is_dict: bool,
    /// In the separate tree for exotic objects, whose lookups must never be cached.
    exotic_tree: bool = false,
    proto: ?*Object,
    table: *Table,
    /// Entries valid for this shape; in a dictionary, includes tombstones.
    count: u32,
    /// Live properties (differs from count only in a dictionary).
    live: u32,
    parent: ?*Shape,
    key: PropKey,
    flags: PropFlags,
    single: ?*Shape = null,
    many: ?*std.AutoHashMapUnmanaged(TransKey, *Shape) = null,

    pub fn trace(s: *Shape, m: *heap.Marker) void {
        m.markObj(s.proto);
        if (s.parent) |p| m.markCell(&p.cell);
        for (s.table.entries.items[0..s.count]) |e| m.markKey(e.key);
    }

    pub fn finalize(s: *Shape, gpa: Allocator) void {
        s.table.release(gpa);
        if (s.many) |t| {
            t.deinit(gpa);
            gpa.destroy(t);
        }
    }

    /// Called before an unmarked shape is freed: its live parent must forget it.
    pub fn unlink(s: *Shape, vm: *Vm) void {
        if (s.parent) |p| {
            if (p.cell.marked) {
                if (p.single == s) p.single = null;
                if (p.many) |t| _ = t.remove(.{ .key = s.key.bits, .flags = @bitCast(s.flags) });
            }
        } else if (!s.is_dict) {
            if (s.exotic_tree) {
                _ = vm.exotic_root_shapes.remove(s.proto);
            } else {
                _ = vm.root_shapes.remove(s.proto);
            }
        }
    }

    pub inline fn find(s: *const Shape, key: PropKey) ?u32 {
        return s.table.find(key, s.count);
    }
    pub inline fn entries(s: *const Shape) []const Entry {
        return s.table.entries.items[0..s.count];
    }
    pub inline fn flagsAt(s: *const Shape, i: u32) PropFlags {
        return s.table.entries.items[i].flags;
    }
};

fn newShape(vm: *Vm, proto: ?*Object, table: *Table, count: u32) Error!*Shape {
    const s = try vm.heap.create(Shape, .shape);
    s.is_dict = false;
    s.exotic_tree = false;
    s.proto = proto;
    s.table = table;
    s.count = count;
    s.live = count;
    s.parent = null;
    s.key = PropKey.none;
    s.flags = .{};
    s.single = null;
    s.many = null;
    return s;
}

/// The empty shape for objects with this prototype.
pub fn rootFor(vm: *Vm, proto: ?*Object) Error!*Shape {
    if (vm.root_shapes.get(proto)) |s| return s;
    const t = try vm.gpa.create(Table);
    t.* = .{};
    const s = try newShape(vm, proto, t, 0);
    try vm.root_shapes.put(vm.gpa, proto, s);
    return s;
}

/// The empty shape for exotic objects with this prototype. Ordinary objects never share
/// it, so an inline cache filled from an ordinary object can't answer for an exotic one.
pub fn exoticRootFor(vm: *Vm, proto: ?*Object) Error!*Shape {
    if (vm.exotic_root_shapes.get(proto)) |s| return s;
    const t = try vm.gpa.create(Table);
    t.* = .{};
    const s = try newShape(vm, proto, t, 0);
    s.exotic_tree = true;
    try vm.exotic_root_shapes.put(vm.gpa, proto, s);
    return s;
}

/// The shape reached by adding key to a non-dictionary shape.
pub fn transition(vm: *Vm, s: *Shape, key: PropKey, flags: PropFlags) Error!*Shape {
    const fbits: u8 = @bitCast(flags);
    if (s.single) |c| {
        if (c.key.bits == key.bits and @as(u8, @bitCast(c.flags)) == fbits) return c;
    }
    if (s.many) |t| {
        if (t.get(.{ .key = key.bits, .flags = fbits })) |c| return c;
    }
    const gpa = vm.gpa;
    var table: *Table = undefined;
    if (s.table.entries.items.len == s.count) {
        table = s.table;
        table.refs += 1;
    } else {
        table = try gpa.create(Table);
        table.* = .{};
        try table.entries.appendSlice(gpa, s.table.entries.items[0..s.count]);
        if (s.count > Table.linear_max) try table.rebuildIndex(gpa);
    }
    try table.append(gpa, key, flags);
    const c = try newShape(vm, s.proto, table, s.count + 1);
    c.parent = s;
    c.key = key;
    c.flags = flags;
    if (s.single == null and s.many == null) {
        s.single = c;
    } else {
        if (s.many == null) {
            const t = try gpa.create(std.AutoHashMapUnmanaged(TransKey, *Shape));
            t.* = .empty;
            s.many = t;
        }
        try s.many.?.put(gpa, .{ .key = key.bits, .flags = fbits }, c);
    }
    return c;
}

/// A private dictionary shape with the same layout as s, for one object to own.
pub fn toDict(vm: *Vm, s: *Shape, proto: ?*Object) Error!*Shape {
    const gpa = vm.gpa;
    const t = try gpa.create(Table);
    t.* = .{};
    try t.entries.appendSlice(gpa, s.table.entries.items[0..s.count]);
    if (s.count > Table.linear_max) try t.rebuildIndex(gpa);
    const d = try newShape(vm, proto, t, s.count);
    d.is_dict = true;
    d.live = s.live;
    return d;
}

pub fn dictAdd(vm: *Vm, d: *Shape, key: PropKey, flags: PropFlags) Error!void {
    try d.table.append(vm.gpa, key, flags);
    d.count += 1;
    d.live += 1;
}

pub fn dictRemove(d: *Shape, i: u32) void {
    const e = &d.table.entries.items[i];
    d.table.removeFromIndex(e.key);
    e.key = PropKey.none;
    d.live -= 1;
}

pub fn dictSetFlags(d: *Shape, i: u32, flags: PropFlags) void {
    d.table.entries.items[i].flags = flags;
}

/// Drops tombstones from a dictionary, moving the object's slots to match.
pub fn dictCompact(vm: *Vm, d: *Shape, slots: [*]Value) Error!void {
    const es = d.table.entries.items;
    var n: usize = 0;
    for (es, 0..) |e, i| {
        if (e.key.bits == 0) continue;
        es[n] = e;
        slots[n] = slots[i];
        n += 1;
    }
    d.table.entries.items.len = n;
    d.count = @intCast(n);
    d.live = @intCast(n);
    if (n > Table.linear_max) {
        try d.table.rebuildIndex(vm.gpa);
    } else {
        vm.gpa.free(d.table.index);
        d.table.index = &.{};
        d.table.used = 0;
    }
}
