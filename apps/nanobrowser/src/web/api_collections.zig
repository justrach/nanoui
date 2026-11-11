//! The live collections: NodeList (childNodes), HTMLCollection (children,
//! getElementsBy…), DOMTokenList, NamedNodeMap, dataset. Each answers through
//! host hooks, and a collection caches its nodes until the tree changes.
const std = @import("std");
const js = @import("../js/js.zig");
const dom = @import("../dom.zig");
const bind = @import("bind.zig");
const mutate = @import("mutate.zig");
const world_mod = @import("world.zig");
const Node = dom.Node;
const Value = js.Value;
const Vm = js.Vm;
const Error = js.Error;
const World = bind.World;

const Coll = struct {
    root: *Node,
    kind: Kind,
    name: []const u8 = "",
    items: std.ArrayList(*Node) = .empty,
    generation: u32 = 0,
    filled: bool = false,

    const Kind = enum { child_nodes, children, by_tag, by_class, static };
};

/// `host_tag`s of these objects, for natives to recognise `this`.
const tag_coll: u32 = 0x434f4c4c;
const tag_tokens: u32 = 0x544f4b4e;

fn collOf(o: *js.Object) *Coll {
    return @ptrCast(@alignCast(o.host));
}

inline fn collGen(c: *const Coll) u32 {
    return switch (c.kind) {
        .child_nodes, .children => c.root.children_gen,
        else => c.root.doc.generation,
    };
}

fn fill(w: *World, c: *Coll) Error!void {
    const gen = collGen(c);
    if (c.filled and c.generation == gen and c.kind != .static) return;
    if (c.kind == .static) return;
    c.filled = true;
    c.generation = gen;
    c.items.clearRetainingCapacity();
    const a = w.page.arena();
    switch (c.kind) {
        .child_nodes => {
            var k = bind.firstChild(c.root);
            while (k) |x| : (k = x.next) try c.items.append(a, x);
        },
        .children => {
            var k = bind.firstChild(c.root);
            while (k) |x| : (k = x.next) if (x.kind == .element) try c.items.append(a, x);
        },
        .by_tag => {
            var at = c.root.first_child;
            const all = std.mem.eql(u8, c.name, "*");
            while (at) |x| : (at = x.nextInTree(c.root)) {
                if (x.kind != .element) continue;
                if (all or std.ascii.eqlIgnoreCase(x.tag, c.name)) try c.items.append(a, x);
            }
        },
        .by_class => {
            var req_bits: u64 = 0;
            var any = false;
            var it = std.mem.tokenizeAny(u8, c.name, " \t\r\n\x0c");
            while (it.next()) |tok| {
                any = true;
                req_bits |= @import("../perf_rules.zig").classBit(tok);
            }
            if (!any or (c.root.subtree_class_bloom & req_bits) != req_bits) return;
            var at = c.root.first_child;
            while (at) |x| {
                if ((x.subtree_class_bloom & req_bits) != req_bits) {
                    at = x.nextSkippingChildren(c.root);
                    continue;
                }
                if (x.kind == .element and hasAllClasses(x, c.name)) try c.items.append(a, x);
                at = x.nextInTree(c.root);
            }
        },
        .static => {},
    }
}

fn hasAllClasses(n: *const Node, names: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, names, " \t\r\n\x0c");
    var any = false;
    while (it.next()) |c| {
        any = true;
        if (!n.hasClass(c)) return false;
    }
    return any;
}

fn collGetIndex(vm: *Vm, o: *js.Object, i: u32) Error!?Value {
    const c = collOf(o);
    if (!c.filled or (c.kind != .static and c.generation != collGen(c))) {
        try fill(bind.world(vm), c);
    }
    if (i >= c.items.items.len) return null;
    const n = c.items.items[i];
    if (n.js_object) |obj| return Value.fromObject(@ptrCast(@alignCast(obj)));
    return try bind.wrap(vm, n);
}

fn collLength(vm: *Vm, o: *js.Object) Error!u32 {
    const c = collOf(o);
    if (!c.filled or (c.kind != .static and c.generation != collGen(c))) {
        try fill(bind.world(vm), c);
    }
    return @intCast(c.items.items.len);
}

/// HTMLCollection's named items: by id or name.
fn collNamed(vm: *Vm, o: *js.Object, name: []const u8) Error!?Value {
    if (reserved(name)) return null;
    const c = collOf(o);
    if (c.kind == .child_nodes) return null;
    try fill(bind.world(vm), c);
    for (c.items.items) |n| {
        if (n.attr("id")) |v| if (std.mem.eql(u8, v, name)) return try bind.wrap(vm, n);
        if (n.attr("name")) |v| if (std.mem.eql(u8, v, name)) return try bind.wrap(vm, n);
    }
    return null;
}

fn reserved(name: []const u8) bool {
    const list = [_][]const u8{ "length", "item", "namedItem", "forEach", "entries", "keys", "values", "constructor", "toString", "then", "nodeType", "tagName", "__proto__" };
    for (list) |r| if (std.mem.eql(u8, r, name)) return true;
    return false;
}

const node_list_hooks = js.HostHooks{ .get_index = collGetIndex, .length_index = collLength };
const collection_hooks = js.HostHooks{ .get_index = collGetIndex, .length_index = collLength, .get_named = collNamed };

fn makeColl(w: *World, root: *Node, kind: Coll.Kind, name: []const u8) Error!*js.Object {
    const c = try w.page.arena().create(Coll);
    c.* = .{ .root = root, .kind = kind, .name = name };
    const is_list = kind == .child_nodes or kind == .static;
    const proto = if (is_list) w.extra.node_list else w.extra.html_collection;
    return w.vm.newExoticObject(proto, tag_coll, c, if (is_list) &node_list_hooks else &collection_hooks);
}

pub fn childNodes(w: *World, n: *Node) Error!Value {
    const key = world_mod.CacheKey{ .node = n, .kind = .child_nodes };
    if (w.cached.get(key)) |o| return o.value();
    const o = try makeColl(w, n, .child_nodes, "");
    try w.cached.put(w.gpa, key, o);
    return o.value();
}

pub fn children(w: *World, n: *Node) Error!Value {
    const key = world_mod.CacheKey{ .node = n, .kind = .children };
    if (w.cached.get(key)) |o| return o.value();
    const o = try makeColl(w, n, .children, "");
    try w.cached.put(w.gpa, key, o);
    return o.value();
}

pub fn byTag(w: *World, n: *Node, name: []const u8) Error!Value {
    return (try makeColl(w, n, .by_tag, try bind.dupe(w, name))).value();
}

pub fn byClass(w: *World, n: *Node, name: []const u8) Error!Value {
    return (try makeColl(w, n, .by_class, try bind.dupe(w, name))).value();
}

/// A NodeList that doesn't follow the tree: `querySelectorAll`.
pub fn staticList(w: *World, root: *Node, nodes: []const *Node) Error!Value {
    const o = try makeColl(w, root, .static, "");
    const c = collOf(o);
    try c.items.appendSlice(w.page.arena(), nodes);
    return o.value();
}

/// A template's content fragment; one a script made and filled gets its children.
pub fn templateContent(_: *World, n: *Node) ?*Node {
    if (n.template_content) |f| return f;
    const f = n.doc.createFragment() catch return null;
    while (n.first_child) |k| f.appendChild(k);
    n.template_content = f;
    return f;
}

// DOMTokenList: `classList`, `relList`, over one attribute.

const Tokens = struct { node: *Node, attr: []const u8 };

fn tokensOf(vm: *Vm, this: Value) Error!*Tokens {
    const o = this.objectOrNull() orelse return bind.illegal(vm);
    if (o.host_tag != tag_tokens) return bind.illegal(vm);
    return @ptrCast(@alignCast(o.host));
}

fn tokenAt(t: *const Tokens, i: u32) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, t.node.attr(t.attr) orelse "", " \t\r\n\x0c");
    var at: u32 = 0;
    while (it.next()) |x| : (at += 1) if (at == i) return x;
    return null;
}

fn tokensIndex(vm: *Vm, o: *js.Object, i: u32) Error!?Value {
    const t: *Tokens = @ptrCast(@alignCast(o.host));
    const s = tokenAt(t, i) orelse return null;
    return try vm.newString(s);
}

fn tokensLength(_: *Vm, o: *js.Object) Error!u32 {
    const t: *Tokens = @ptrCast(@alignCast(o.host));
    var it = std.mem.tokenizeAny(u8, t.node.attr(t.attr) orelse "", " \t\r\n\x0c");
    var n: u32 = 0;
    while (it.next()) |_| n += 1;
    return n;
}

const token_hooks = js.HostHooks{ .get_index = tokensIndex, .length_index = tokensLength };

pub fn tokenList(w: *World, n: *Node, attr: []const u8, kind: world_mod.Cached) Error!Value {
    if (kind == .class_list) if (n.js_class_list) |p| {
        const o: *js.Object = @ptrCast(@alignCast(p));
        return o.value();
    };
    const key = world_mod.CacheKey{ .node = n, .kind = kind };
    if (w.cached.get(key)) |o| {
        if (kind == .class_list) n.js_class_list = o;
        return o.value();
    }
    const t = try w.page.arena().create(Tokens);
    t.* = .{ .node = n, .attr = attr };
    const o = try w.vm.newExoticObject(w.extra.token_list, tag_tokens, t, &token_hooks);
    try w.cached.put(w.gpa, key, o);
    if (kind == .class_list) n.js_class_list = o;
    return o.value();
}

fn isClassAttr(attr: []const u8) bool {
    return attr.len == 5 and attr[0] == 'c' and std.mem.eql(u8, attr, "class");
}

fn hasToken(list: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n\x0c");
    while (it.next()) |x| if (std.mem.eql(u8, x, token)) return true;
    return false;
}

fn checkToken(vm: *Vm, token: []const u8) Error!void {
    if (token.len == 0) return bind.throwDom(vm, "SyntaxError", "The token provided must not be empty.");
    if (std.mem.indexOfAny(u8, token, " \t\r\n\x0c") != null) return bind.throwDom(vm, "InvalidCharacterError", "The token provided contains HTML space characters, which are not valid in tokens.");
}

fn tokensContains(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const t = try tokensOf(vm, this);
    const tok = try bind.str(vm, args, 0);
    if (isClassAttr(t.attr)) return Value.fromBool(t.node.hasClass(tok));
    return Value.fromBool(hasToken(t.node.attr(t.attr) orelse "", tok));
}

fn writeTokens(w: *World, t: *Tokens, list: []const u8, add: []const []const u8, drop: []const []const u8) Error!void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(w.gpa);
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n\x0c");
    while (it.next()) |x| {
        var gone = false;
        for (drop) |d| if (std.mem.eql(u8, d, x)) {
            gone = true;
        };
        if (gone or hasToken(out.items, x)) continue;
        if (out.items.len > 0) try out.append(w.gpa, ' ');
        try out.appendSlice(w.gpa, x);
    }
    for (add) |x| {
        if (hasToken(out.items, x)) continue;
        if (out.items.len > 0) try out.append(w.gpa, ' ');
        try out.appendSlice(w.gpa, x);
    }
    try mutate.setAttr(w, t.node, t.attr, out.items);
}

fn argTexts(vm: *Vm, args: []const Value, out: *[64][]const u8) Error![]const []const u8 {
    const n = @min(args.len, out.len);
    for (args[0..n], 0..) |a, i| {
        out[i] = try vm.toStringSlice(a);
        try checkToken(vm, out[i]);
    }
    return out[0..n];
}

fn tokensAdd(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const t = try tokensOf(vm, this);
    if (args.len == 1) {
        const tok = try vm.toStringSlice(args[0]);
        try checkToken(vm, tok);
        const is_cls = isClassAttr(t.attr);
        const cur = (if (is_cls) t.node.class_attr else t.node.attr(t.attr)) orelse "";
        if (cur.len == 0) {
            try mutate.setAttr(bind.world(vm), t.node, t.attr, tok);
            return Value.undefined;
        }
        if (if (is_cls) t.node.hasClass(tok) else hasToken(cur, tok)) return Value.undefined;
        try writeTokens(bind.world(vm), t, cur, &.{tok}, &.{});
        return Value.undefined;
    }
    var buf: [64][]const u8 = undefined;
    const list = try argTexts(vm, args, &buf);
    const cur = t.node.attr(t.attr) orelse "";
    var missing = false;
    for (list) |x| if (!hasToken(cur, x)) {
        missing = true;
    };
    if (missing) try writeTokens(bind.world(vm), t, cur, list, &.{});
    return Value.undefined;
}

fn tokensRemove(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const t = try tokensOf(vm, this);
    if (args.len == 1) {
        const tok = try vm.toStringSlice(args[0]);
        try checkToken(vm, tok);
        const is_cls = isClassAttr(t.attr);
        const cur = (if (is_cls) t.node.class_attr else t.node.attr(t.attr)) orelse return Value.undefined;
        if (is_cls) {
            if (!t.node.hasClass(tok)) return Value.undefined;
            if (t.node.class_single and std.mem.eql(u8, cur, tok)) {
                try mutate.setAttr(bind.world(vm), t.node, t.attr, "");
                return Value.undefined;
            }
        } else if (!hasToken(cur, tok)) return Value.undefined;
        try writeTokens(bind.world(vm), t, cur, &.{}, &.{tok});
        return Value.undefined;
    }
    var buf: [64][]const u8 = undefined;
    const list = try argTexts(vm, args, &buf);
    const cur = t.node.attr(t.attr) orelse return Value.undefined;
    var there = false;
    for (list) |x| if (hasToken(cur, x)) {
        there = true;
    };
    if (there) try writeTokens(bind.world(vm), t, cur, &.{}, list);
    return Value.undefined;
}

fn tokensToggle(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const t = try tokensOf(vm, this);
    const w = bind.world(vm);
    const token = try bind.str(vm, args, 0);
    try checkToken(vm, token);
    const is_cls = isClassAttr(t.attr);
    const cur = (if (is_cls) t.node.class_attr else t.node.attr(t.attr)) orelse "";
    const has = if (is_cls) t.node.hasClass(token) else hasToken(cur, token);
    const want = if (args.len > 1 and !args[1].isUndefined()) vm.toBoolean(args[1]) else !has;
    if (want == has) return Value.fromBool(has);
    if (want) {
        if (cur.len == 0) try mutate.setAttr(w, t.node, t.attr, token) else try writeTokens(w, t, cur, &.{token}, &.{});
    } else {
        if (is_cls and t.node.class_single and std.mem.eql(u8, cur, token)) try mutate.setAttr(w, t.node, t.attr, "") else try writeTokens(w, t, cur, &.{}, &.{token});
    }
    return Value.fromBool(want);
}

fn tokensReplace(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const t = try tokensOf(vm, this);
    const w = bind.world(vm);
    const a = try bind.str(vm, args, 0);
    const b = try bind.str(vm, args, 1);
    try checkToken(vm, a);
    try checkToken(vm, b);
    const cur = t.node.attr(t.attr) orelse "";
    if (!hasToken(cur, a)) return Value.false;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(w.gpa);
    var it = std.mem.tokenizeAny(u8, cur, " \t\r\n\x0c");
    while (it.next()) |x| {
        const piece = if (std.mem.eql(u8, x, a)) b else x;
        if (hasToken(out.items, piece)) continue;
        if (out.items.len > 0) try out.append(w.gpa, ' ');
        try out.appendSlice(w.gpa, piece);
    }
    try mutate.setAttr(w, t.node, t.attr, out.items);
    return Value.true;
}

fn tokensValue(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const t = try tokensOf(vm, this);
    return vm.newString(t.node.attr(t.attr) orelse "");
}

fn tokensSetValue(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const t = try tokensOf(vm, this);
    try mutate.setAttr(bind.world(vm), t.node, t.attr, try bind.str(vm, args, 0));
    return Value.undefined;
}

// `dataset`: `data-*` attributes under camelCase names.

fn dataAttrName(w: *World, name: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const a = w.page.arena();
    try out.appendSlice(a, "data-");
    for (name) |c| {
        if (c >= 'A' and c <= 'Z') {
            try out.append(a, '-');
            try out.append(a, c + 32);
        } else try out.append(a, c);
    }
    return out.items;
}

fn hostNode(o: *js.Object) *Node {
    return @ptrCast(@alignCast(o.host));
}

fn dataGet(vm: *Vm, o: *js.Object, name: []const u8) Error!?Value {
    const n = hostNode(o);
    var buf: [128]u8 = undefined;
    const key = dataKey(&buf, name) orelse return null;
    const v = n.attr(key) orelse return null;
    return try vm.newString(v);
}

/// `fooBar` as `data-foo-bar` without allocating, when short enough.
fn dataKey(buf: []u8, name: []const u8) ?[]const u8 {
    var i: usize = 5;
    if (name.len * 2 + 5 > buf.len) return null;
    @memcpy(buf[0..5], "data-");
    for (name) |c| {
        if (c >= 'A' and c <= 'Z') {
            buf[i] = '-';
            buf[i + 1] = c + 32;
            i += 2;
        } else {
            buf[i] = c;
            i += 1;
        }
    }
    return buf[0..i];
}

fn dataSet(vm: *Vm, o: *js.Object, name: []const u8, v: Value) Error!bool {
    const w = bind.world(vm);
    try mutate.setAttr(w, hostNode(o), try dataAttrName(w, name), try vm.toStringSlice(v));
    return true;
}


fn dataDelete(vm: *Vm, o: *js.Object, name: []const u8) Error!bool {
    const w = bind.world(vm);
    try mutate.removeAttr(w, hostNode(o), try dataAttrName(w, name));
    return true;
}

fn dataNames(vm: *Vm, o: *js.Object, out: *std.ArrayList(Value)) Error!void {
    const n = hostNode(o);
    for (n.attrs.items) |a| {
        if (!std.mem.startsWith(u8, a.name, "data-")) continue;
        var buf: [128]u8 = undefined;
        var i: usize = 0;
        var up = false;
        for (a.name[5..]) |c| {
            if (i >= buf.len) break;
            if (c == '-') {
                up = true;
                continue;
            }
            buf[i] = if (up) std.ascii.toUpper(c) else c;
            up = false;
            i += 1;
        }
        try out.append(vm.gpa, try vm.newString(buf[0..i]));
    }
}

const data_hooks = js.HostHooks{ .get_named = dataGet, .set_named = dataSet, .delete_named = dataDelete, .own_names = dataNames };

pub fn dataset(w: *World, n: *Node) Error!Value {
    const key = world_mod.CacheKey{ .node = n, .kind = .dataset };
    if (w.cached.get(key)) |o| return o.value();
    const o = try w.vm.newExoticObject(w.extra.dom_string_map, 1, n, &data_hooks);
    try w.cached.put(w.gpa, key, o);
    return o.value();
}

// NamedNodeMap: `attributes`, its items made by the prelude's `Attr`.

fn attrsIndex(vm: *Vm, o: *js.Object, i: u32) Error!?Value {
    const n = hostNode(o);
    if (i >= n.attrs.items.len) return null;
    const w = bind.world(vm);
    const args = [_]Value{ try bind.wrap(vm, n), try vm.newString(n.attrs.items[i].name) };
    return try vm.call(w.h.makeAttr, Value.undefined, &args);
}

fn attrsLength(_: *Vm, o: *js.Object) Error!u32 {
    return @intCast(hostNode(o).attrs.items.len);
}

fn attrsNamed(vm: *Vm, o: *js.Object, name: []const u8) Error!?Value {
    if (reservedAttrs(name)) return null;
    const n = hostNode(o);
    if (!n.hasAttr(name)) return null;
    const args = [_]Value{ try bind.wrap(vm, n), try vm.newString(name) };
    return try vm.call(bind.world(vm).h.makeAttr, Value.undefined, &args);
}

fn reservedAttrs(name: []const u8) bool {
    const list = [_][]const u8{ "length", "item", "getNamedItem", "setNamedItem", "removeNamedItem", "getNamedItemNS", "setNamedItemNS", "removeNamedItemNS", "constructor" };
    for (list) |r| if (std.mem.eql(u8, r, name)) return true;
    return false;
}

const attrs_hooks = js.HostHooks{ .get_index = attrsIndex, .length_index = attrsLength, .get_named = attrsNamed };

pub fn attributes(w: *World, n: *Node) Error!Value {
    const key = world_mod.CacheKey{ .node = n, .kind = .attributes };
    if (w.cached.get(key)) |o| return o.value();
    const o = try w.vm.newExoticObject(w.extra.named_node_map, 1, n, &attrs_hooks);
    try w.cached.put(w.gpa, key, o);
    return o.value();
}

fn illegalCtor(vm: *Vm, _: Value, _: []const Value) Error!Value {
    return vm.throwError(.TypeError, "Illegal constructor");
}

fn collItem(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = this.objectOrNull() orelse return bind.illegal(vm);
    if (o.host_tag != tag_coll) return bind.illegal(vm);
    const n = try vm.toNumber(bind.arg(args, 0));
    if (!(n >= 0 and n < 4294967295)) return Value.null;
    const c = collOf(o);
    try fill(bind.world(vm), c);
    const i: usize = @intFromFloat(n);
    if (i >= c.items.items.len) return Value.null;
    return bind.wrap(vm, c.items.items[i]);
}

fn collNamedItem(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const o = this.objectOrNull() orelse return bind.illegal(vm);
    if (o.host_tag != tag_coll) return bind.illegal(vm);
    return (try collNamed(vm, o, try bind.str(vm, args, 0))) orelse Value.null;
}

fn tokensItem(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const t = try tokensOf(vm, this);
    const n = try vm.toNumber(bind.arg(args, 0));
    if (!(n >= 0 and n < 4294967295)) return Value.null;
    const s = tokenAt(t, @intFromFloat(n)) orelse return Value.null;
    return vm.newString(s);
}

/// The classes of the collections, on the global object. Their iteration comes from Array's.
pub fn install(w: *World) Error!void {
    const vm = w.vm;
    const make = struct {
        fn f(x: *World, name: []const u8) Error!*js.Object {
            const pair = try x.vm.newClass(name, 0, illegalCtor, null);
            try x.vm.global().defineData(x.vm, name, pair.ctor.value(), js.PropFlags.hidden);
            return pair.proto;
        }
    }.f;
    w.extra.node_list = try make(w, "NodeList");
    w.extra.html_collection = try make(w, "HTMLCollection");
    w.extra.token_list = try make(w, "DOMTokenList");
    w.extra.dom_string_map = try make(w, "DOMStringMap");
    w.extra.named_node_map = try make(w, "NamedNodeMap");
    try w.extra.node_list.defineMethod(vm, "item", 1, collItem);
    try w.extra.html_collection.defineMethod(vm, "item", 1, collItem);
    try w.extra.html_collection.defineMethod(vm, "namedItem", 1, collNamedItem);
    try bind.methods(vm, w.extra.token_list, &.{
        .{ .name = "contains", .arity = 1, .f = tokensContains },
        .{ .name = "add", .arity = 0, .f = tokensAdd },
        .{ .name = "remove", .arity = 0, .f = tokensRemove },
        .{ .name = "toggle", .arity = 1, .f = tokensToggle },
        .{ .name = "replace", .arity = 2, .f = tokensReplace },
        .{ .name = "item", .arity = 1, .f = tokensItem },
    });
    try bind.accessors(vm, w.extra.token_list, &.{.{ .name = "value", .get = tokensValue, .set = tokensSetValue }});
}
