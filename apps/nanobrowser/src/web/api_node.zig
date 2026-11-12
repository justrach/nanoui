//! Node.prototype and CharacterData: the tree as scripts see it.
const std = @import("std");
const js = @import("../js/js.zig");
const dom = @import("../dom.zig");
const bind = @import("bind.zig");
const mutate = @import("mutate.zig");
const collections = @import("api_collections.zig");
const custom = @import("custom.zig");
const Node = dom.Node;
const Value = js.Value;
const Vm = js.Vm;
const Error = js.Error;
const nodeOf = bind.thisNode;

fn nodeType(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    if (bind.isShadow(n)) return Value.fromInt(11);
    return Value.fromInt(switch (n.kind) {
        .element => 1,
        .text => 3,
        .comment => 8,
        .document => 9,
        .doctype => 10,
        .fragment => 11,
    });
}

fn upperName(vm: *Vm, n: *const Node) Error!Value {
    if (n.ns != .html) return if (n.tag.len <= 32) vm.internString(n.tag) else vm.newString(n.tag);
    var buf: [128]u8 = undefined;
    if (n.tag.len <= 32) return vm.internString(std.ascii.upperString(&buf, n.tag));
    if (n.tag.len <= buf.len) return vm.newString(std.ascii.upperString(&buf, n.tag));
    return vm.newString(n.tag);
}

fn nodeName(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    if (bind.isShadow(n)) return vm.internString("#document-fragment");
    return switch (n.kind) {
        .element => upperName(vm, n),
        .text => vm.internString("#text"),
        .comment => vm.internString("#comment"),
        .document => vm.internString("#document"),
        .doctype => vm.newString(n.data),
        .fragment => vm.internString("#document-fragment"),
    };
}

fn nodeValue(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    return if (n.kind == .text or n.kind == .comment) vm.newString(n.data) else Value.null;
}

fn setNodeValue(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    if (n.kind == .text or n.kind == .comment) try mutate.setData(bind.world(vm), n, try bind.strNullEmpty(vm, args, 0));
    return Value.undefined;
}

/// What scripts see of the text within.
fn textContent(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    if (n.kind == .document or n.kind == .doctype) return Value.null;
    const w = bind.world(vm);
    if (n.kind == .text or n.kind == .comment) return vm.newString(n.data);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(w.gpa);
    var k = bind.firstChild(n);
    while (k) |c| : (k = c.next) try c.collectText(w.gpa, &out);
    return vm.newString(out.items);
}

fn setTextContent(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const w = bind.world(vm);
    if (n.kind == .document or n.kind == .doctype) return Value.undefined;
    const s = try bind.strNullEmpty(vm, args, 0);
    if (n.kind == .text or n.kind == .comment) {
        try mutate.setData(w, n, s);
        return Value.undefined;
    }
    try mutate.replaceWithText(w, n, s);
    return Value.undefined;
}

fn parentNode(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    if (bind.isShadow(n)) return Value.null;
    return bind.wrap(vm, n.parent);
}

fn parentElement(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const p = n.parent orelse return Value.null;
    if (p.kind != .element or bind.isShadow(p) or bind.isShadow(n)) return Value.null;
    return bind.wrap(vm, p);
}

fn firstChild(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return bind.wrap(vm, bind.firstChild(try nodeOf(vm, this)));
}

fn lastChild(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return bind.wrap(vm, bind.lastChild(try nodeOf(vm, this)));
}

fn nextSibling(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    if (bind.isShadow(n)) return Value.null;
    return bind.wrap(vm, n.next);
}

fn previousSibling(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    if (bind.isShadow(n)) return Value.null;
    return bind.wrap(vm, bind.prevSibling(n));
}

fn childNodes(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return collections.childNodes(bind.world(vm), try nodeOf(vm, this));
}

fn ownerDocument(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    if (n.kind == .document) return Value.null;
    return bind.wrap(vm, n.doc.node);
}

fn isConnected(vm: *Vm, this: Value, _: []const Value) Error!Value {
    var at: ?*const Node = try nodeOf(vm, this);
    while (at) |x| {
        if (x.kind == .document) return Value.true;
        at = x.parent;
    }
    return Value.false;
}

fn hierarchyError(vm: *Vm, what: []const u8) Error {
    return bind.throwDom(vm, "HierarchyRequestError", what);
}

/// Whether `child` may go in `parent`, as DOM's "ensure pre-insertion validity".
fn checkInsert(vm: *Vm, parent: *Node, child: *Node, ref: ?*Node) Error!void {
    if (parent.kind == .text or parent.kind == .comment or parent.kind == .doctype) return hierarchyError(vm, "This node type does not support this method.");
    if (child.contains(parent)) return hierarchyError(vm, "The new child element contains the parent.");
    if (child.kind == .document) return hierarchyError(vm, "Nodes of type '#document' may not be inserted.");
    if (ref) |r| if (r.parent != parent) return bind.throwDom(vm, "NotFoundError", "The node before which the new node is to be inserted is not a child of this node.");
}

fn appendChild(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const p = try nodeOf(vm, this);
    const c = try bind.nodeArg(vm, args, 0, "appendChild");
    try checkInsert(vm, p, c, null);
    try mutate.insert(bind.world(vm), p, c, null);
    return args[0];
}

fn insertBefore(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const p = try nodeOf(vm, this);
    const c = try bind.nodeArg(vm, args, 0, "insertBefore");
    const ref = bind.asNode(bind.arg(args, 1));
    try checkInsert(vm, p, c, ref);
    // Before itself is where it already is: before what follows it.
    const at = if (ref == c) c.next else ref;
    try mutate.insert(bind.world(vm), p, c, at);
    return args[0];
}

fn removeChild(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const p = try nodeOf(vm, this);
    const c = try bind.nodeArg(vm, args, 0, "removeChild");
    if (c.parent != p) return bind.throwDom(vm, "NotFoundError", "The node to be removed is not a child of this node.");
    try mutate.remove(bind.world(vm), p, c);
    return args[0];
}

fn replaceChild(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const p = try nodeOf(vm, this);
    const c = try bind.nodeArg(vm, args, 0, "replaceChild");
    const old = try bind.nodeArg(vm, args, 1, "replaceChild");
    if (old.parent != p) return bind.throwDom(vm, "NotFoundError", "The node to be replaced is not a child of this node.");
    try checkInsert(vm, p, c, null);
    const w = bind.world(vm);
    var ref = old.next;
    if (ref == c) ref = c.next;
    if (c != old) {
        try mutate.remove(w, p, old);
        try mutate.insert(w, p, c, ref);
    }
    return bind.arg(args, 1);
}

/// A copy of `n`: its attributes share the arena's strings.
pub fn clone(w: *bind.World, n: *Node, deep: bool, doc: *dom.Document) Error!*Node {
    const a = doc.arena;
    const copy = try a.create(Node);
    copy.* = .{
        .kind = n.kind,
        .doc = doc,
        .tag = n.tag,
        .html_tag = n.html_tag,
        .ns = n.ns,
        .data = n.data,
        .has_resource = @import("../perf_rules.zig").isResourceTag(n.tag),
        .has_id = n.id_attr != null and n.id_attr.?.len != 0,
        .has_insertion_work = @import("../perf_rules.zig").isInsertionWorkTag(n.tag),
        .has_on_attr = n.has_on_attr,
        .id_attr = n.id_attr,
        .class_attr = n.class_attr,
        .class_filter = n.class_filter,
        .attr_filter = n.attr_filter,
        .subtree_class_bloom = n.class_filter,
        .subtree_attr_bloom = n.attr_filter,
        .class_src = n.class_src,
        .class_src_len = n.class_src_len,
        .class_single = n.class_single,
    };
    try copy.attrs.ensureTotalCapacity(a, n.attrs.items.len);
    for (n.attrs.items) |at| copy.attrs.appendAssumeCapacity(at);
    copy.value = n.value;
    copy.checked = n.checked;
    copy.selected = n.selected;
    // An inline `<svg>`'s markup is its original's alone.
    if (n.ns != .svg) {
        copy.image = n.image;
        copy.image_key = n.image_key;
    }
    if (deep) {
        // Depth may be great: a stack of where to go on.
        var from: *Node = n;
        var to: *Node = copy;
        var k = bind.firstChild(n);
        const templ = if (n.isTag("template")) collections.templateContent(w, n) else null;
        if (templ) |t| {
            copy.template_content = try clone(w, t, true, doc);
        }
        while (true) {
            if (k) |child| {
                const c2 = try a.create(Node);
                c2.* = .{
                    .kind = child.kind,
                    .doc = doc,
                    .tag = child.tag,
                    .html_tag = child.html_tag,
                    .ns = child.ns,
                    .data = child.data,
                    .has_resource = @import("../perf_rules.zig").isResourceTag(child.tag),
                    .has_id = child.id_attr != null and child.id_attr.?.len != 0,
                    .has_insertion_work = @import("../perf_rules.zig").isInsertionWorkTag(child.tag),
                    .has_on_attr = child.has_on_attr,
                    .id_attr = child.id_attr,
                    .class_attr = child.class_attr,
                    .class_filter = child.class_filter,
                    .attr_filter = child.attr_filter,
                    .subtree_class_bloom = child.class_filter,
                    .subtree_attr_bloom = child.attr_filter,
                    .class_src = child.class_src,
                    .class_src_len = child.class_src_len,
                    .class_single = child.class_single,
                };
                try c2.attrs.ensureTotalCapacity(a, child.attrs.items.len);
                for (child.attrs.items) |at| c2.attrs.appendAssumeCapacity(at);
                c2.value = child.value;
                c2.checked = child.checked;
                c2.selected = child.selected;
                if (child.ns != .svg) {
                    c2.image = child.image;
                    c2.image_key = child.image_key;
                }
                to.parserInsert(c2, null);
                if (child.isTag("template")) {
                    if (collections.templateContent(w, child)) |t| c2.template_content = try clone(w, t, true, doc);
                }
                if (child.first_child != null) {
                    from = child;
                    to = c2;
                    k = child.first_child;
                } else k = child.next;
            } else {
                if (from == n) break;
                k = from.next;
                from = from.parent.?;
                to = to.parent.?;
            }
        }
    }
    return copy;
}

fn cloneNode(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const w = bind.world(vm);
    if (n.kind == .document) {
        const d = try dom.Document.create(w.page.arena());
        d.url = n.doc.url;
        return bind.wrap(vm, d.node);
    }
    const c = try clone(w, n, vm.toBoolean(bind.arg(args, 0)), n.doc);
    if (c.kind == .element and custom.isCustomName(c.tag)) try custom.created(w, c);
    return bind.wrap(vm, c);
}

fn contains(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const o = bind.asNode(bind.arg(args, 0)) orelse return Value.false;
    // What's in a shadow tree isn't in its host, as scripts see it.
    var at: ?*const Node = o;
    while (at) |x| : (at = x.parent) {
        if (x == n) return Value.true;
        if (x.is_shadow) return Value.false;
    }
    return Value.false;
}

fn hasChildNodes(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return Value.fromBool(bind.firstChild(try nodeOf(vm, this)) != null);
}

/// Position in the tree, as a path of child indexes from the root.
fn compareDocumentPosition(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const a = try nodeOf(vm, this);
    const b = try bind.nodeArg(vm, args, 0, "compareDocumentPosition");
    if (a == b) return Value.fromInt(0);
    const disconnected: i32 = 1 | 32;
    var ra = a;
    while (ra.parent) |p| ra = p;
    var rb = b;
    while (rb.parent) |p| rb = p;
    if (ra != rb) return Value.fromInt(disconnected | (if (@intFromPtr(a) < @intFromPtr(b)) @as(i32, 4) else 2));
    if (a.contains(b)) return Value.fromInt(16 | 4);
    if (b.contains(a)) return Value.fromInt(8 | 2);
    // Walk up to the children of the common ancestor, then along the siblings.
    var x = a;
    while (x.parent) |p| : (x = p) if (p.contains(b)) break;
    var y = b;
    while (y.parent) |p| : (y = p) if (p == x.parent) break;
    var s = x.next;
    while (s) |k| : (s = k.next) if (k == y) return Value.fromInt(4);
    return Value.fromInt(2);
}

fn getRootNode(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    var composed = false;
    if (bind.arg(args, 0).isObject()) composed = vm.toBoolean(try args[0].asObject().get(vm, "composed"));
    var at = n;
    while (at.parent) |p| {
        if (bind.isShadow(at) and !composed) break;
        at = p;
    }
    return bind.wrap(vm, at);
}

/// Joins adjacent texts and drops empty ones.
fn normalize(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const root = try nodeOf(vm, this);
    const w = bind.world(vm);
    var at: ?*Node = root.first_child;
    while (at) |n| {
        if (n.kind != .text) {
            at = n.nextInTree(root);
            continue;
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(w.gpa);
        try out.appendSlice(w.gpa, n.data);
        var sib = n.next;
        while (sib) |s| {
            if (s.kind != .text) break;
            try out.appendSlice(w.gpa, s.data);
            const after = s.next;
            try mutate.remove(w, s.parent.?, s);
            sib = after;
        }
        if (out.items.len == 0) {
            const next = n.nextSkippingChildren(root);
            try mutate.remove(w, n.parent.?, n);
            at = next;
            continue;
        }
        if (out.items.len != n.data.len) try mutate.setData(w, n, out.items);
        at = n.nextInTree(root);
    }
    return Value.undefined;
}

fn isEqualNode(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const a = try nodeOf(vm, this);
    const b = bind.asNode(bind.arg(args, 0)) orelse return Value.false;
    return Value.fromBool(equalTrees(a, b));
}

fn equalTrees(a: *Node, b: *Node) bool {
    if (a.kind != b.kind or !std.mem.eql(u8, a.tag, b.tag) or !std.mem.eql(u8, a.data, b.data)) return false;
    if (a.attrs.items.len != b.attrs.items.len) return false;
    for (a.attrs.items) |x| {
        const v = b.attr(x.name) orelse return false;
        if (!std.mem.eql(u8, v, x.value)) return false;
    }
    var ca = a.first_child;
    var cb = b.first_child;
    while (ca != null and cb != null) {
        if (!equalTrees(ca.?, cb.?)) return false;
        ca = ca.?.next;
        cb = cb.?.next;
    }
    return ca == null and cb == null;
}

fn data(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return vm.newString((try nodeOf(vm, this)).data);
}

fn setCharData(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    try mutate.setData(bind.world(vm), n, try bind.strNullEmpty(vm, args, 0));
    return Value.undefined;
}

pub fn install(w: *bind.World) Error!void {
    const vm = w.vm;
    const classes = @import("classes.zig");
    const node = classes.proto(w, "Node");
    try bind.accessors(vm, node, &.{
        .{ .name = "nodeType", .get = nodeType },
        .{ .name = "nodeName", .get = nodeName },
        .{ .name = "nodeValue", .get = nodeValue, .set = setNodeValue },
        .{ .name = "textContent", .get = textContent, .set = setTextContent },
        .{ .name = "parentNode", .get = parentNode },
        .{ .name = "parentElement", .get = parentElement },
        .{ .name = "firstChild", .get = firstChild },
        .{ .name = "lastChild", .get = lastChild },
        .{ .name = "nextSibling", .get = nextSibling },
        .{ .name = "previousSibling", .get = previousSibling },
        .{ .name = "childNodes", .get = childNodes },
        .{ .name = "ownerDocument", .get = ownerDocument },
        .{ .name = "isConnected", .get = isConnected },
    });
    try bind.methods(vm, node, &.{
        .{ .name = "appendChild", .arity = 1, .f = appendChild },
        .{ .name = "insertBefore", .arity = 2, .f = insertBefore },
        .{ .name = "removeChild", .arity = 1, .f = removeChild },
        .{ .name = "replaceChild", .arity = 2, .f = replaceChild },
        .{ .name = "cloneNode", .arity = 0, .f = cloneNode },
        .{ .name = "contains", .arity = 1, .f = contains },
        .{ .name = "hasChildNodes", .arity = 0, .f = hasChildNodes },
        .{ .name = "compareDocumentPosition", .arity = 1, .f = compareDocumentPosition },
        .{ .name = "getRootNode", .arity = 0, .f = getRootNode },
        .{ .name = "normalize", .arity = 0, .f = normalize },
        .{ .name = "isEqualNode", .arity = 1, .f = isEqualNode },
    });
    try bind.accessors(vm, classes.proto(w, "CharacterData"), &.{
        .{ .name = "data", .get = data, .set = setCharData },
    });
}
