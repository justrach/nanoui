//! `localStorage` and `sessionStorage`: Storage semantics over one in-memory table
//! per origin, kept for the life of the process and never written to disk.
const std = @import("std");
const js = @import("../js/js.zig");
const bind = @import("bind.zig");
const Value = js.Value;
const Vm = js.Vm;
const Error = js.Error;
const World = bind.World;

const gpa = std.heap.smp_allocator;

const Table = struct {
    items: std.StringArrayHashMapUnmanaged([]u8) = .empty,

    fn put(t: *Table, k: []const u8, v: []const u8) void {
        const value = gpa.dupe(u8, v) catch return;
        if (t.items.getPtr(k)) |old| {
            gpa.free(old.*);
            old.* = value;
            return;
        }
        const key = gpa.dupe(u8, k) catch {
            gpa.free(value);
            return;
        };
        t.items.put(gpa, key, value) catch {
            gpa.free(key);
            gpa.free(value);
        };
    }

    fn remove(t: *Table, k: []const u8) void {
        const e = t.items.fetchOrderedRemove(k) orelse return;
        gpa.free(e.key);
        gpa.free(e.value);
    }

    fn clear(t: *Table) void {
        var it = t.items.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        t.items.clearRetainingCapacity();
    }
};

var tables: std.StringHashMapUnmanaged(*Table) = .empty;

/// The table for `key` (`l:` or `s:` then an origin).
fn tableFor(key: []const u8) ?*Table {
    if (tables.get(key)) |t| return t;
    const t = gpa.create(Table) catch return null;
    t.* = .{};
    const k = gpa.dupe(u8, key) catch return null;
    tables.put(gpa, k, t) catch return null;
    return t;
}

/// For tests: forget everything.
pub fn clearAll() void {
    var it = tables.valueIterator();
    while (it.next()) |t| t.*.clear();
}

fn of(o: *js.Object) *Table {
    return @ptrCast(@alignCast(o.host));
}

fn isMember(name: []const u8) bool {
    const list = [_][]const u8{ "length", "key", "getItem", "setItem", "removeItem", "clear", "constructor", "toString", "valueOf", "hasOwnProperty" };
    for (list) |m| if (std.mem.eql(u8, m, name)) return true;
    return false;
}

fn getNamed(vm: *Vm, o: *js.Object, name: []const u8) Error!?Value {
    if (isMember(name)) return null;
    const v = of(o).items.get(name) orelse return null;
    return try vm.newString(v);
}

fn setNamed(vm: *Vm, o: *js.Object, name: []const u8, v: Value) Error!bool {
    if (isMember(name)) return false;
    of(o).put(name, try vm.toStringSlice(v));
    return true;
}


fn deleteNamed(_: *Vm, o: *js.Object, name: []const u8) Error!bool {
    of(o).remove(name);
    return true;
}

fn ownNames(vm: *Vm, o: *js.Object, out: *std.ArrayList(Value)) Error!void {
    for (of(o).items.keys()) |k| try out.append(vm.gpa, try vm.newString(k));
}

const hooks = js.HostHooks{ .get_named = getNamed, .set_named = setNamed, .delete_named = deleteNamed, .own_names = ownNames };

fn thisTable(vm: *Vm, this: Value) Error!*Table {
    const o = this.objectOrNull() orelse return bind.illegal(vm);
    if (o.host_tag != tag) return bind.illegal(vm);
    return of(o);
}

const tag: u32 = 0x53544f52;

fn getItem(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const t = try thisTable(vm, this);
    return bind.optStr(vm, t.items.get(try bind.str(vm, args, 0)));
}

fn setItem(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const t = try thisTable(vm, this);
    t.put(try bind.str(vm, args, 0), try bind.str(vm, args, 1));
    return Value.undefined;
}

fn removeItem(vm: *Vm, this: Value, args: []const Value) Error!Value {
    (try thisTable(vm, this)).remove(try bind.str(vm, args, 0));
    return Value.undefined;
}

fn clear(vm: *Vm, this: Value, _: []const Value) Error!Value {
    (try thisTable(vm, this)).clear();
    return Value.undefined;
}

fn keyAt(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const t = try thisTable(vm, this);
    const i = try vm.toNumber(bind.arg(args, 0));
    const keys = t.items.keys();
    if (!(i >= 0 and i < @as(f64, @floatFromInt(keys.len)))) return Value.null;
    return vm.newString(keys[@intFromFloat(i)]);
}

fn length(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return Value.fromUsize((try thisTable(vm, this)).items.count());
}

fn illegalCtor(vm: *Vm, _: Value, _: []const Value) Error!Value {
    return vm.throwError(.TypeError, "Illegal constructor");
}

/// `$.storage(prefix, origin)`: a Storage for that origin.
fn makeStorage(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    var buf: [600]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ try bind.str(vm, args, 0), try bind.str(vm, args, 1) }) catch "x";
    const t = tableFor(key) orelse return Value.null;
    return (try vm.newExoticObject(w.extra.storage, tag, t, &hooks)).value();
}

pub const internals = [_]bind.Method{.{ .name = "storage", .arity = 2, .f = makeStorage }};

pub fn install(w: *World) Error!void {
    const vm = w.vm;
    const pair = try vm.newClass("Storage", 0, illegalCtor, null);
    try vm.global().defineData(vm, "Storage", pair.ctor.value(), js.PropFlags.hidden);
    w.extra.storage = pair.proto;
    try bind.methods(vm, pair.proto, &.{
        .{ .name = "getItem", .arity = 1, .f = getItem },
        .{ .name = "setItem", .arity = 2, .f = setItem },
        .{ .name = "removeItem", .arity = 1, .f = removeItem },
        .{ .name = "clear", .arity = 0, .f = clear },
        .{ .name = "key", .arity = 1, .f = keyAt },
    });
    try pair.proto.defineAccessor(vm, "length", length, null);
}
