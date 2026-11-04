//! The JS heap: the cell header, the counting allocator that enforces the hard
//! heap limit, and the precise stop-the-world mark-sweep collector. Collection
//! is only legal between tasks, with no JS or native on the stack, so natives
//! never need handle scopes and the value stack is never scanned.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const PropKey = @import("value.zig").PropKey;
const Vm = @import("vm.zig").Vm;
const str = @import("string.zig");
const JSString = str.JSString;
const Symbol = str.Symbol;
const Shape = @import("shape.zig").Shape;
const objmod = @import("object.zig");
const Object = objmod.Object;
const bc = @import("bytecode.zig");
const coroutine = @import("coroutine.zig");
const module = @import("module.zig");
const big = std.math.big.int;

pub const CellKind = enum(u8) { object, string, symbol, bigint, shape, env, accessor, proto, coroutine, module, source };

pub const Cell = struct {
    next: ?*Cell = null,
    kind: CellKind,
    marked: bool = false,
};

/// A scope's captured variables, heap allocated so closures and generators keep them.
pub const Env = struct {
    cell: Cell,
    parent: ?*Env,
    len: u32,

    pub inline fn slots(e: *Env) [*]Value {
        return @ptrFromInt(@intFromPtr(e) + @sizeOf(Env));
    }
    pub fn allocSize(n: usize) usize {
        return @sizeOf(Env) + n * @sizeOf(Value);
    }
};

/// A getter/setter pair; the property's slot holds this as an internal value.
pub const Accessor = struct {
    cell: Cell,
    get: Value,
    set: Value,
};

pub const BigInt = struct {
    cell: Cell,
    v: big.Managed,
};

/// std.mem.Allocator wrapper that counts live bytes and refuses to pass the limit.
pub const Counting = struct {
    gpa: Allocator,
    bytes: usize = 0,
    limit: usize = 2 * 1024 * 1024 * 1024,

    pub fn allocator(self: *Counting) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (self.bytes + len > self.limit) return null;
        const p = self.gpa.rawAlloc(len, a, ra) orelse return null;
        self.bytes += len;
        return p;
    }
    fn resize(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (new_len > mem.len and self.bytes + (new_len - mem.len) > self.limit) return false;
        if (!self.gpa.rawResize(mem, a, new_len, ra)) return false;
        self.bytes = self.bytes + new_len - mem.len;
        return true;
    }
    fn remap(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (new_len > mem.len and self.bytes + (new_len - mem.len) > self.limit) return null;
        const p = self.gpa.rawRemap(mem, a, new_len, ra) orelse return null;
        self.bytes = self.bytes + new_len - mem.len;
        return p;
    }
    fn free(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.gpa.rawFree(mem, a, ra);
        self.bytes -= mem.len;
    }
};

/// The marker handed to the host's root callback.
pub const Marker = struct {
    vm: *Vm,
    stack: std.ArrayList(*Cell) = .empty,
    /// Live weak containers discovered during marking.
    weak: std.ArrayList(*Object) = .empty,

    pub fn mark(m: *Marker, v: Value) void {
        if (v.heapCell()) |c| m.markCell(c);
    }
    pub inline fn markCell(m: *Marker, c: *Cell) void {
        if (c.marked) return;
        c.marked = true;
        m.stack.append(m.vm.raw_gpa, c) catch @panic("gc: out of memory");
    }
    pub fn markObj(m: *Marker, o: ?*Object) void {
        if (o) |p| m.markCell(&p.cell);
    }
    pub fn markStr(m: *Marker, s: ?*JSString) void {
        if (s) |p| m.markCell(&p.cell);
    }
    pub fn markKey(m: *Marker, k: PropKey) void {
        if (k.isAtom()) {
            m.markCell(&k.atom().cell);
        } else if (k.isSymbol()) {
            m.markCell(&k.symbol().cell);
        }
    }
    pub fn markValues(m: *Marker, vs: []const Value) void {
        for (vs) |v| m.mark(v);
    }

    fn drain(m: *Marker) void {
        while (m.stack.pop()) |c| trace(m, c);
    }
};

fn trace(m: *Marker, c: *Cell) void {
    switch (c.kind) {
        .object => objmod.trace(m, @fieldParentPtr("cell", c)),
        .string => {
            const s: *JSString = @fieldParentPtr("cell", c);
            if (s.left) |l| m.markCell(&l.cell);
            if (s.right) |r| m.markCell(&r.cell);
            if (s.key.isAtom()) m.markCell(&s.key.atom().cell);
        },
        .symbol => {
            const s: *Symbol = @fieldParentPtr("cell", c);
            m.markStr(s.description);
        },
        .bigint => {},
        .shape => @as(*Shape, @fieldParentPtr("cell", c)).trace(m),
        .env => {
            const e: *Env = @fieldParentPtr("cell", c);
            if (e.parent) |p| m.markCell(&p.cell);
            m.markValues(e.slots()[0..e.len]);
        },
        .accessor => {
            const a: *Accessor = @fieldParentPtr("cell", c);
            m.mark(a.get);
            m.mark(a.set);
        },
        .proto => @as(*bc.FuncProto, @fieldParentPtr("cell", c)).trace(m),
        .coroutine => @as(*coroutine.Coroutine, @fieldParentPtr("cell", c)).trace(m),
        .module => @as(*module.Module, @fieldParentPtr("cell", c)).trace(m),
        .source => {},
    }
}

fn freeCell(vm: *Vm, c: *Cell) void {
    const gpa = vm.gpa;
    switch (c.kind) {
        .object => {
            const o: *Object = @fieldParentPtr("cell", c);
            objmod.finalize(vm, o);
            gpa.destroy(o);
        },
        .string => {
            const s: *JSString = @fieldParentPtr("cell", c);
            s.finalize(gpa);
            gpa.destroy(s);
        },
        .symbol => gpa.destroy(@as(*Symbol, @fieldParentPtr("cell", c))),
        .bigint => {
            const b: *BigInt = @fieldParentPtr("cell", c);
            b.v.deinit();
            gpa.destroy(b);
        },
        .shape => {
            const s: *Shape = @fieldParentPtr("cell", c);
            s.finalize(gpa);
            gpa.destroy(s);
        },
        .env => {
            const e: *Env = @fieldParentPtr("cell", c);
            const size = Env.allocSize(e.len);
            const bytes: [*]align(8) u8 = @ptrCast(e);
            gpa.free(bytes[0..size]);
        },
        .accessor => gpa.destroy(@as(*Accessor, @fieldParentPtr("cell", c))),
        .proto => {
            const p: *bc.FuncProto = @fieldParentPtr("cell", c);
            p.finalize(gpa);
            gpa.destroy(p);
        },
        .coroutine => {
            const co: *coroutine.Coroutine = @fieldParentPtr("cell", c);
            co.finalize(gpa);
            gpa.destroy(co);
        },
        .module => {
            const mo: *module.Module = @fieldParentPtr("cell", c);
            mo.finalize(gpa);
            gpa.destroy(mo);
        },
        .source => {
            const so: *bc.Source = @fieldParentPtr("cell", c);
            so.finalize(gpa);
            gpa.destroy(so);
        },
    }
}

/// Owns the cell list. `gpa` is the counting allocator every JS thing goes through.
pub const Heap = struct {
    gpa: Allocator,
    head: ?*Cell = null,
    count: usize = 0,

    pub inline fn link(h: *Heap, c: *Cell) void {
        c.next = h.head;
        h.head = c;
        h.count += 1;
    }

    /// Allocates one fixed-size cell; the first field of T must be `cell: Cell`.
    pub fn create(h: *Heap, comptime T: type, kind: CellKind) Allocator.Error!*T {
        const p = try h.gpa.create(T);
        p.cell = .{ .kind = kind };
        h.link(&p.cell);
        return p;
    }

    pub fn newEnv(h: *Heap, parent: ?*Env, n: usize) Allocator.Error!*Env {
        const bytes = try h.gpa.alignedAlloc(u8, .of(Env), Env.allocSize(n));
        const e: *Env = @ptrCast(bytes.ptr);
        e.* = .{ .cell = .{ .kind = .env }, .parent = parent, .len = @intCast(n) };
        h.link(&e.cell);
        return e;
    }

    pub fn newAccessor(h: *Heap, get: Value, set: Value) Allocator.Error!*Accessor {
        const a = try h.create(Accessor, .accessor);
        a.get = get;
        a.set = set;
        return a;
    }
};

/// The full stop-the-world collection. Only legal between tasks.
pub fn collect(vm: *Vm) void {
    var m = Marker{ .vm = vm };
    defer m.stack.deinit(vm.raw_gpa);
    defer m.weak.deinit(vm.raw_gpa);
    vm.markRoots(&m);
    m.drain();
    // Ephemerons: a WeakMap value is live only if its key is; iterate to a fixed point.
    var again = true;
    while (again) {
        again = false;
        var i: usize = 0;
        while (i < m.weak.items.len) : (i += 1) {
            if (objmod.traceWeak(&m, m.weak.items[i])) again = true;
        }
        m.drain();
    }
    for (m.weak.items) |o| objmod.sweepWeak(vm, o);
    // Weak tables must forget dying entries before any of those cells are freed.
    var it = vm.heap.head;
    while (it) |c| : (it = c.next) {
        if (c.marked) continue;
        switch (c.kind) {
            .shape => @as(*Shape, @fieldParentPtr("cell", c)).unlink(vm),
            .string => {
                const s: *JSString = @fieldParentPtr("cell", c);
                if (s.is_atom) _ = vm.atoms.remove(s.ptr[0..s.byte_len]);
            },
            else => {},
        }
    }
    sweep(vm, false);
    vm.counting.limit = vm.heap_limit;
}

fn sweep(vm: *Vm, all: bool) void {
    var link: *?*Cell = &vm.heap.head;
    while (link.*) |c| {
        if (c.marked and !all) {
            c.marked = false;
            link = &c.next;
        } else {
            link.* = c.next;
            vm.heap.count -= 1;
            freeCell(vm, c);
        }
    }
}

/// Frees every cell; used by vm.deinit().
pub fn freeAll(vm: *Vm) void {
    sweep(vm, true);
}
