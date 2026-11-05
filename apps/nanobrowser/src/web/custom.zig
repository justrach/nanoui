//! Custom elements: the registry, upgrades, and lifecycle callbacks. Reactions
//! run right after the DOM operation that caused them, not on a separate
//! queue. Customized built-ins (`extends`, `is=`) are accepted but don't upgrade.
const std = @import("std");
const js = @import("../js/js.zig");
const dom = @import("../dom.zig");
const props = @import("../js/props.zig");
const bind = @import("bind.zig");
const mutate = @import("mutate.zig");
const World = bind.World;
const Node = dom.Node;
const Value = js.Value;
const Vm = js.Vm;
const Error = js.Error;

pub const Def = struct {
    name: []const u8,
    ctor: Value,
    connected: Value,
    disconnected: Value,
    attribute_changed: Value,
    observed: std.ArrayList([]const u8) = .empty,
};

pub const Registry = struct {
    defs: std.StringHashMapUnmanaged(*Def) = .empty,
    /// Elements that have become what their name says, and as what.
    upgraded: std.AutoHashMapUnmanaged(*Node, *Def) = .empty,
    /// The element an upgrade is constructing: `HTMLElement()` answers with it.
    upgrading: ?*Node = null,

    pub fn deinit(r: *Registry, gpa: std.mem.Allocator) void {
        var it = r.defs.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            for (e.value_ptr.*.observed.items) |s| gpa.free(s);
            e.value_ptr.*.observed.deinit(gpa);
            gpa.destroy(e.value_ptr.*);
        }
        r.defs.deinit(gpa);
        r.upgraded.deinit(gpa);
    }

    pub fn mark(r: *Registry, m: *js.Marker) void {
        var it = r.defs.valueIterator();
        while (it.next()) |d| {
            m.mark(d.*.ctor);
            m.mark(d.*.connected);
            m.mark(d.*.disconnected);
            m.mark(d.*.attribute_changed);
        }
    }
};

pub fn isCustomName(tag: []const u8) bool {
    return std.mem.indexOfScalar(u8, tag, '-') != null;
}

/// `new` on HTMLElement and its subclasses: legal in a custom element's
/// constructor, whether upgrading an element or making a new one.
pub fn htmlElementCtor(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const w = bind.world(vm);
    const nt = vm.new_target;
    if (w.custom.upgrading) |n| {
        w.custom.upgrading = null;
        const wrapper = try bind.wrap(vm, n);
        const proto = try nt.asObject().get(vm, "prototype");
        if (proto.isObject()) _ = try props.setProto(vm, wrapper.asObject(), proto.asObject());
        return wrapper;
    }
    var it = w.custom.defs.valueIterator();
    while (it.next()) |d| {
        if (nt.isObject() and d.*.ctor.same(nt)) {
            const n = try w.page.doc.createElement(d.*.name);
            try w.custom.upgraded.put(w.gpa, n, d.*);
            return bind.adopt(w, this.asObject(), n);
        }
    }
    return vm.throwError(.TypeError, "Illegal constructor");
}

/// `$.ceDefine(name, ctor, connected, disconnected, attributeChanged, observed)`.
pub fn define(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const name = try bind.str(vm, args, 0);
    if (w.custom.defs.contains(name)) return bind.throwDom(vm, "NotSupportedError", "this name has already been used with this registry");
    const key = try w.gpa.dupe(u8, name);
    const d = try w.gpa.create(Def);
    d.* = .{ .name = key, .ctor = bind.arg(args, 1), .connected = bind.arg(args, 2), .disconnected = bind.arg(args, 3), .attribute_changed = bind.arg(args, 4) };
    if (bind.arg(args, 5).isObject()) {
        const list = args[5].asObject();
        const len = try vm.toNumber(try list.get(vm, "length"));
        var i: u32 = 0;
        while (@as(f64, @floatFromInt(i)) < len) : (i += 1) {
            const s = try vm.toStringSlice(try list.getIdx(vm, i));
            try d.observed.append(w.gpa, try w.gpa.dupe(u8, s));
        }
    }
    try w.custom.defs.put(w.gpa, key, d);
    // Elements already in the document become what they now are.
    var pending: std.ArrayList(*Node) = .empty;
    defer pending.deinit(w.gpa);
    const doc = w.page.doc.node;
    var at = doc.first_child;
    while (at) |n| : (at = n.nextDeep(doc)) {
        if (n.kind == .element and std.mem.eql(u8, n.tag, d.name)) try pending.append(w.gpa, n);
    }
    for (pending.items) |n| {
        if (!w.custom.upgraded.contains(n)) try upgrade(w, n, d);
    }
    return Value.undefined;
}

/// `customElements.upgrade(root)`.
pub fn upgradeTree(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const root = bind.asNode(bind.arg(args, 0)) orelse return Value.undefined;
    var pending: std.ArrayList(*Node) = .empty;
    defer pending.deinit(w.gpa);
    var at: ?*Node = root;
    while (at) |n| : (at = n.nextDeep(root)) {
        if (n.kind == .element and isCustomName(n.tag)) try pending.append(w.gpa, n);
    }
    for (pending.items) |n| {
        if (w.custom.upgraded.contains(n)) continue;
        if (w.custom.defs.get(n.tag)) |d| try upgrade(w, n, d);
    }
    return Value.undefined;
}

fn upgrade(w: *World, n: *Node, d: *Def) Error!void {
    const vm = w.vm;
    w.custom.upgrading = n;
    defer w.custom.upgrading = null;
    _ = vm.construct(d.ctor, &.{}) catch |e| {
        if (e != error.Thrown) return e;
        w.report(e);
        return;
    };
    w.custom.upgrading = null;
    try w.custom.upgraded.put(w.gpa, n, d);
    if (d.attribute_changed.isCallable()) for (d.observed.items) |name| {
        if (n.attr(name)) |v| {
            const args = [_]Value{ try vm.newString(name), Value.null, try vm.newString(v), Value.null };
            _ = try w.callGuarded(d.attribute_changed, try bind.wrap(vm, n), &args);
        }
    };
    if (mutate.isConnected(n) and d.connected.isCallable()) {
        _ = try w.callGuarded(d.connected, try bind.wrap(vm, n), &.{});
    }
}

/// A new element by its name: a defined one is built at once.
pub fn created(w: *World, n: *Node) Error!void {
    if (w.custom.defs.count() == 0 or !isCustomName(n.tag)) return;
    if (w.custom.defs.get(n.tag)) |d| try upgrade(w, n, d);
}

/// The element with a custom name came into the document.
pub fn connected(w: *World, n: *Node) Error!void {
    if (w.custom.upgraded.get(n)) |d| {
        if (d.connected.isCallable()) _ = try w.callGuarded(d.connected, try bind.wrap(w.vm, n), &.{});
        return;
    }
    if (w.custom.defs.get(n.tag)) |d| try upgrade(w, n, d);
}

pub fn disconnected(w: *World, n: *Node) Error!void {
    const d = w.custom.upgraded.get(n) orelse return;
    if (d.disconnected.isCallable()) _ = try w.callGuarded(d.disconnected, try bind.wrap(w.vm, n), &.{});
}

pub fn attributeChanged(w: *World, n: *Node, name: []const u8, old: ?[]const u8, value: ?[]const u8) Error!void {
    if (w.custom.upgraded.count() == 0) return;
    const d = w.custom.upgraded.get(n) orelse return;
    if (!d.attribute_changed.isCallable()) return;
    for (d.observed.items) |o| {
        if (!std.mem.eql(u8, o, name)) continue;
        const vm = w.vm;
        const args = [_]Value{ try vm.newString(name), try bind.optStr(vm, old), try bind.optStr(vm, value), Value.null };
        _ = try w.callGuarded(d.attribute_changed, try bind.wrap(vm, n), &args);
        return;
    }
}
