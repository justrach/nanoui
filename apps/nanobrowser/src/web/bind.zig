//! What every binding file shares: finding the world from a native, reading
//! arguments, wrapping nodes, and installing tables of natives on an object.
const std = @import("std");
const js = @import("../js/js.zig");
const dom = @import("../dom.zig");
const world_mod = @import("world.zig");
const classes = @import("classes.zig");

pub const World = world_mod.World;
pub const Vm = js.Vm;
pub const Value = js.Value;
pub const Object = js.Object;
pub const Error = js.Error;
pub const Node = dom.Node;

/// `host_tag` of an object wrapping a node. Other tags are the exotic objects'.
pub const tag_node: u32 = 0x4e4f4445;

pub const Method = struct { name: []const u8, arity: u32, f: js.NativeFn };
pub const Prop = struct { name: []const u8, get: ?js.Getter, set: ?js.Setter = null };

pub fn world(vm: *Vm) *World {
    return @ptrCast(@alignCast(vm.roots_ctx.?));
}

pub fn methods(vm: *Vm, o: *Object, table: []const Method) Error!void {
    for (table) |m| try o.defineMethod(vm, m.name, m.arity, m.f);
}

pub fn accessors(vm: *Vm, o: *Object, table: []const Prop) Error!void {
    for (table) |p| try o.defineAccessor(vm, p.name, p.get, p.set);
}

pub fn illegal(vm: *Vm) Error {
    return vm.throwError(.TypeError, "Illegal invocation");
}

/// The node `v` wraps, or null when it wraps none.
pub fn asNode(v: Value) ?*Node {
    const o = v.objectOrNull() orelse return null;
    if (o.host_tag != tag_node) return null;
    return @ptrCast(@alignCast(o.host));
}

/// `this` as a node, the document when called bare.
pub fn thisNode(vm: *Vm, this: Value) Error!*Node {
    return asNode(this) orelse illegal(vm);
}

pub fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else Value.undefined;
}

/// A node argument that must be one.
pub fn nodeArg(vm: *Vm, args: []const Value, i: usize, what: []const u8) Error!*Node {
    if (asNode(arg(args, i))) |n| return n;
    var buf: [120]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: parameter is not of type 'Node'", .{what}) catch "parameter is not of type 'Node'";
    return vm.throwError(.TypeError, msg);
}

/// An argument as text. The slice lives until the next collection.
pub fn str(vm: *Vm, args: []const Value, i: usize) Error![]const u8 {
    return vm.toStringSlice(arg(args, i));
}

/// As `str`, with `null` meaning the empty string.
pub fn strNullEmpty(vm: *Vm, args: []const Value, i: usize) Error![]const u8 {
    const v = arg(args, i);
    if (v.isNull()) return "";
    return vm.toStringSlice(v);
}

pub fn jsStr(vm: *Vm, s: []const u8) Error!Value {
    return vm.newString(s);
}

pub fn optStr(vm: *Vm, s: ?[]const u8) Error!Value {
    return if (s) |x| vm.newString(x) else Value.null;
}

pub fn num(v: f64) Value {
    return Value.fromNumber(v);
}

/// The object for a node: made once, kept for the node's whole life.
pub fn wrap(vm: *Vm, node: ?*Node) Error!Value {
    const n = node orelse return Value.null;
    if (n.js_object) |o| {
        const obj: *Object = @ptrCast(@alignCast(o));
        return obj.value();
    }
    const w = world(vm);
    const o = try vm.newObjectWithProto(classes.protoFor(w, n));
    return adopt(w, o, n);
}

/// Makes `o` the wrapper of `n`.
pub fn adopt(w: *World, o: *Object, n: *Node) Error!Value {
    o.host = n;
    o.host_tag = tag_node;
    n.js_object = o;
    try w.wrappers.append(w.gpa, o);
    return o.value();
}

/// DOMException thrown from a native, through the prelude's class.
pub fn throwDom(vm: *Vm, name: []const u8, message: []const u8) Error {
    const w = world(vm);
    if (w.h.domException.isCallable()) {
        const args = [_]Value{ try vm.newString(message), try vm.newString(name) };
        const e = try vm.call(w.h.domException, Value.undefined, &args);
        return vm.throwValue(e);
    }
    return vm.throwError(.Error, message);
}

/// Text that may hold lone surrogates or be long: JS text from UTF-8 bytes.
pub fn dupe(w: *World, s: []const u8) Error![]const u8 {
    return w.page.arena().dupe(u8, s);
}

/// Lowercased copy of `s` in the arena; `s` itself when already lowercase.
pub fn lower(w: *World, s: []const u8) Error![]const u8 {
    for (s) |c| if (c >= 'A' and c <= 'Z') {
        const out = try w.page.arena().alloc(u8, s.len);
        _ = std.ascii.lowerString(out, s);
        return out;
    };
    return s;
}

/// An attribute's name as this element stores it.
pub fn attrName(w: *World, n: *const Node, name: []const u8) Error![]const u8 {
    return if (n.ns == .html) lower(w, name) else name;
}

/// Is this node a shadow root's stand-in (`api_shadow.zig`)?
pub fn isShadow(n: *const Node) bool {
    return n.is_shadow;
}

pub fn firstChild(n: *const Node) ?*Node {
    return n.first_child;
}

pub fn lastChild(n: *const Node) ?*Node {
    return n.last_child;
}

pub fn prevSibling(n: *const Node) ?*Node {
    return n.prev;
}
