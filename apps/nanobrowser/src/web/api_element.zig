//! Element.prototype: attributes, markup, element navigation, selectors, and
//! the objects hanging off an element (`style`, `classList`, `dataset`, …).
const std = @import("std");
const js = @import("../js/js.zig");
const dom = @import("../dom.zig");
const html = @import("../html/html.zig");
const css = @import("../css/css.zig");
const bind = @import("bind.zig");
const mutate = @import("mutate.zig");
const scripts = @import("scripts.zig");
const collections = @import("api_collections.zig");
const style = @import("api_style.zig");
const classes = @import("classes.zig");
const world_mod = @import("world.zig");
const Node = dom.Node;
const Value = js.Value;
const Vm = js.Vm;
const Error = js.Error;
const World = bind.World;
const nodeOf = bind.thisNode;

fn elementOf(vm: *Vm, this: Value) Error!*Node {
    const n = try nodeOf(vm, this);
    if (n.kind != .element) return bind.illegal(vm);
    return n;
}

fn tagName(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    if (n.ns != .html) return vm.newString(n.tag);
    var buf: [128]u8 = undefined;
    if (n.tag.len <= buf.len) return vm.newString(std.ascii.upperString(&buf, n.tag));
    return vm.newString(n.tag);
}

fn localName(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return vm.newString((try elementOf(vm, this)).tag);
}

fn namespaceURI(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    return vm.newString(switch (n.ns) {
        .html => "http://www.w3.org/1999/xhtml",
        .svg => "http://www.w3.org/2000/svg",
        .mathml => "http://www.w3.org/1998/Math/MathML",
    });
}

fn getAttribute(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    const name = try bind.attrName(bind.world(vm), n, try bind.str(vm, args, 0));
    return bind.optStr(vm, n.attr(name));
}

fn setAttribute(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    const w = bind.world(vm);
    if (args.len < 2) return vm.throwError(.TypeError, "setAttribute: 2 arguments required");
    const raw = try bind.str(vm, args, 0);
    if (raw.len == 0 or std.mem.indexOfAny(u8, raw, " \t\r\n\x0c/>=") != null) {
        return bind.throwDom(vm, "InvalidCharacterError", "'setAttribute': the name is not a valid attribute name.");
    }
    try mutate.setAttr(w, n, try bind.attrName(w, n, raw), try bind.str(vm, args, 1));
    return Value.undefined;
}

fn removeAttribute(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    const w = bind.world(vm);
    try mutate.removeAttr(w, n, try bind.attrName(w, n, try bind.str(vm, args, 0)));
    return Value.undefined;
}

fn hasAttribute(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    return Value.fromBool(n.hasAttr(try bind.attrName(bind.world(vm), n, try bind.str(vm, args, 0))));
}

fn toggleAttribute(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    const w = bind.world(vm);
    const name = try bind.attrName(w, n, try bind.str(vm, args, 0));
    const has = n.hasAttr(name);
    const want = if (args.len > 1 and !args[1].isUndefined()) vm.toBoolean(args[1]) else !has;
    if (want and !has) try mutate.setAttr(w, n, name, "");
    if (!want and has) try mutate.removeAttr(w, n, name);
    return Value.fromBool(want);
}

fn getAttributeNames(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    const arr = try vm.newArray(&.{});
    for (n.attrs.items, 0..) |a, i| try arr.setIdx(vm, @intCast(i), try vm.newString(a.name));
    return arr.value();
}

fn hasAttributes(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return Value.fromBool((try elementOf(vm, this)).attrs.items.len > 0);
}

fn id(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return vm.newString((try elementOf(vm, this)).attr("id") orelse "");
}

fn setId(vm: *Vm, this: Value, args: []const Value) Error!Value {
    try mutate.setAttr(bind.world(vm), try elementOf(vm, this), "id", try bind.str(vm, args, 0));
    return Value.undefined;
}

fn className(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return vm.newString((try elementOf(vm, this)).attr("class") orelse "");
}

fn setClassName(vm: *Vm, this: Value, args: []const Value) Error!Value {
    try mutate.setAttr(bind.world(vm), try elementOf(vm, this), "class", try bind.str(vm, args, 0));
    return Value.undefined;
}

fn classList(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return collections.tokenList(bind.world(vm), try elementOf(vm, this), "class", .class_list);
}

fn relList(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return collections.tokenList(bind.world(vm), try elementOf(vm, this), "rel", .rel_list);
}

fn attributes(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return collections.attributes(bind.world(vm), try elementOf(vm, this));
}

fn dataset(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return collections.dataset(bind.world(vm), try elementOf(vm, this));
}

/// `element.classList = "..."` sets the class, as `className` does.
fn setClassList(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    try mutate.setAttr(bind.world(vm), n, "class", try bind.strNullEmpty(vm, args, 0));
    return Value.undefined;
}

fn styleOf(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return style.inlineStyle(bind.world(vm), try elementOf(vm, this));
}

/// `el.style = "…"` sets its text, as `el.style.cssText` does.
fn setStyleOf(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    const text = try bind.strNullEmpty(vm, args, 0);
    const w = bind.world(vm);
    if (text.len == 0) try mutate.removeAttr(w, n, "style") else try mutate.setAttr(w, n, "style", text);
    return Value.undefined;
}

/// A template's markup is its content's.
fn contentRoot(w: *World, n: *Node) *Node {
    if (n.isTag("template")) if (collections.templateContent(w, n)) |f| return f;
    return n;
}

fn serializeChildren(w: *World, n: *Node) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const a = w.gpa;
    defer out.deinit(a);
    const root = contentRoot(w, n);
    var k = bind.firstChild(root);
    while (k) |c| : (k = c.next) {
        const piece = try html.serialize(w.page.arena(), c, true);
        try out.appendSlice(a, piece);
    }
    return w.page.arena().dupe(u8, out.items);
}

fn innerHTML(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    return vm.newString(try serializeChildren(bind.world(vm), n));
}

/// Parses markup for an element; scripts in it never run.
fn parseFor(w: *World, context: *Node, text: []const u8) Error!*Node {
    const f = try html.parseFragment(context.doc, context, text);
    try scripts.markStarted(w, f);
    return f;
}

fn setInnerHTML(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const w = bind.world(vm);
    const text = try bind.strNullEmpty(vm, args, 0);
    const root = contentRoot(w, n);
    const context = if (root.kind == .element and !bind.isShadow(root)) root else try n.doc.createElement("div");
    const f = try parseFor(w, context, text);
    try mutate.replaceAllWith(w, root, f);
    return Value.undefined;
}

fn outerHTML(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    return vm.newString(try html.serialize(bind.world(vm).page.arena(), n, true));
}

fn setOuterHTML(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    const w = bind.world(vm);
    const parent = n.parent orelse return Value.undefined;
    const ctx = if (parent.kind == .element) parent else try n.doc.createElement("body");
    const f = try parseFor(w, ctx, try bind.strNullEmpty(vm, args, 0));
    const next = n.next;
    try mutate.remove(w, parent, n);
    try mutate.insert(w, parent, f, next);
    return Value.undefined;
}

fn insertAdjacentHTML(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    const w = bind.world(vm);
    const where = try bind.str(vm, args, 0);
    const text = try bind.str(vm, args, 1);
    if (std.ascii.eqlIgnoreCase(where, "beforebegin") or std.ascii.eqlIgnoreCase(where, "afterend")) {
        const parent = n.parent orelse return bind.throwDom(vm, "NoModificationAllowedError", "The element has no parent.");
        const ctx = if (parent.kind == .element) parent else try n.doc.createElement("body");
        const f = try parseFor(w, ctx, text);
        try mutate.insert(w, parent, f, if (std.ascii.eqlIgnoreCase(where, "beforebegin")) n else n.next);
    } else if (std.ascii.eqlIgnoreCase(where, "afterbegin") or std.ascii.eqlIgnoreCase(where, "beforeend")) {
        const f = try parseFor(w, n, text);
        try mutate.insert(w, n, f, if (std.ascii.eqlIgnoreCase(where, "afterbegin")) bind.firstChild(n) else null);
    } else return bind.throwDom(vm, "SyntaxError", "The value provided is not one of 'beforeBegin', 'afterBegin', 'beforeEnd', or 'afterEnd'.");
    return Value.undefined;
}

fn children(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return collections.children(bind.world(vm), try nodeOf(vm, this));
}

fn childElementCount(vm: *Vm, this: Value, _: []const Value) Error!Value {
    var c: i32 = 0;
    var k = bind.firstChild(try nodeOf(vm, this));
    while (k) |x| : (k = x.next) {
        if (x.kind == .element) c += 1;
    }
    return Value.fromInt(c);
}

fn firstElementChild(vm: *Vm, this: Value, _: []const Value) Error!Value {
    var k = bind.firstChild(try nodeOf(vm, this));
    while (k) |x| : (k = x.next) if (x.kind == .element) return bind.wrap(vm, x);
    return Value.null;
}

fn lastElementChild(vm: *Vm, this: Value, _: []const Value) Error!Value {
    var k = bind.lastChild(try nodeOf(vm, this));
    while (k) |x| : (k = x.prev) {
        if (x.kind == .element) return bind.wrap(vm, x);
    }
    return Value.null;
}

fn nextElementSibling(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return bind.wrap(vm, (try nodeOf(vm, this)).nextElement());
}

fn previousElementSibling(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const e = (try nodeOf(vm, this)).prevElement() orelse return Value.null;
    return bind.wrap(vm, e);
}

fn selectorError(vm: *Vm, e: css.QueryError, selector: []const u8) Error {
    if (e == error.InvalidSelector) {
        var buf: [200]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "'{s}' is not a valid selector.", .{selector[0..@min(selector.len, 120)]}) catch "not a valid selector";
        return bind.throwDom(vm, "SyntaxError", msg);
    }
    return error.OutOfMemory;
}

const Scratch = struct {
    arena: std.heap.ArenaAllocator,

    fn init(w: *World) Scratch {
        return .{ .arena = std.heap.ArenaAllocator.init(w.gpa) };
    }

    fn deinit(s: *Scratch) void {
        s.arena.deinit();
    }
};

/// Flushes nothing: selectors read attributes and the tree.
fn querySelector(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const sel = try bind.str(vm, args, 0);
    var s = Scratch.init(bind.world(vm));
    defer s.deinit();
    const found = css.querySelector(n, sel, s.arena.allocator()) catch |e| return selectorError(vm, e, sel);
    return bind.wrap(vm, found);
}

fn querySelectorAll(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const w = bind.world(vm);
    const sel = try bind.str(vm, args, 0);
    var s = Scratch.init(w);
    defer s.deinit();
    var out: std.ArrayList(*Node) = .empty;
    css.querySelectorAll(n, sel, s.arena.allocator(), &out) catch |e| return selectorError(vm, e, sel);
    return collections.staticList(w, n, out.items);
}

fn matches(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    const sel = try bind.str(vm, args, 0);
    var s = Scratch.init(bind.world(vm));
    defer s.deinit();
    return Value.fromBool(css.matchesSelector(n, sel, s.arena.allocator()) catch |e| return selectorError(vm, e, sel));
}

fn closest(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    const sel = try bind.str(vm, args, 0);
    var s = Scratch.init(bind.world(vm));
    defer s.deinit();
    const found = css.closest(n, sel, s.arena.allocator()) catch |e| return selectorError(vm, e, sel);
    return bind.wrap(vm, found);
}

fn getElementsByTagName(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return collections.byTag(bind.world(vm), try nodeOf(vm, this), try bind.str(vm, args, 0));
}

fn getElementsByClassName(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return collections.byClass(bind.world(vm), try nodeOf(vm, this), try bind.str(vm, args, 0));
}

/// `attachShadow`: the root is a `display: contents` element (a `<slot>` to the
/// style sheet) that hangs off its host, in none of its host's child lists. Layout
/// renders it in place of the host's children, which go where its `<slot>`s say
/// (`layout/gen.zig`); the rules that match inside it are its own (`css/cascade.zig`).
fn attachShadow(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    const w = bind.world(vm);
    var closed = false;
    if (bind.arg(args, 0).isObject()) {
        const mode = try args[0].asObject().get(vm, "mode");
        if (mode.isString()) closed = std.mem.eql(u8, try vm.toStringSlice(mode), "closed");
    }
    if (n.shadow_root) |root| {
        // One the parser made is the script's to take over, emptied.
        if (!root.shadow_declarative) return bind.throwDom(vm, "NotSupportedError", "Shadow root cannot be created on a host which already hosts a shadow tree.");
        root.shadow_declarative = false;
        root.shadow_closed = closed;
        try mutate.removeAllChildren(w, root);
        return bind.wrap(vm, root);
    }
    return bind.wrap(vm, try n.attachShadow(closed, false));
}

fn shadowRoot(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    const root = n.shadow_root orelse return Value.null;
    if (root.shadow_closed) return Value.null;
    return bind.wrap(vm, root);
}

fn shadowHost(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return bind.wrap(vm, (try nodeOf(vm, this)).parent);
}

fn templateContentGet(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try elementOf(vm, this);
    return bind.wrap(vm, collections.templateContent(bind.world(vm), n));
}

pub fn install(w: *World) Error!void {
    const vm = w.vm;
    const element = classes.proto(w, "Element");
    try bind.accessors(vm, element, &.{
        .{ .name = "tagName", .get = tagName },
        .{ .name = "localName", .get = localName },
        .{ .name = "namespaceURI", .get = namespaceURI },
        .{ .name = "id", .get = id, .set = setId },
        .{ .name = "className", .get = className, .set = setClassName },
        .{ .name = "classList", .get = classList, .set = setClassList },
        .{ .name = "attributes", .get = attributes },
        .{ .name = "innerHTML", .get = innerHTML, .set = setInnerHTML },
        .{ .name = "outerHTML", .get = outerHTML, .set = setOuterHTML },
        .{ .name = "nextElementSibling", .get = nextElementSibling },
        .{ .name = "previousElementSibling", .get = previousElementSibling },
        .{ .name = "shadowRoot", .get = shadowRoot },
    });
    try bind.methods(vm, element, &.{
        .{ .name = "getAttribute", .arity = 1, .f = getAttribute },
        .{ .name = "setAttribute", .arity = 2, .f = setAttribute },
        .{ .name = "removeAttribute", .arity = 1, .f = removeAttribute },
        .{ .name = "hasAttribute", .arity = 1, .f = hasAttribute },
        .{ .name = "toggleAttribute", .arity = 1, .f = toggleAttribute },
        .{ .name = "getAttributeNames", .arity = 0, .f = getAttributeNames },
        .{ .name = "hasAttributes", .arity = 0, .f = hasAttributes },
        .{ .name = "insertAdjacentHTML", .arity = 2, .f = insertAdjacentHTML },
        .{ .name = "matches", .arity = 1, .f = matches },
        .{ .name = "closest", .arity = 1, .f = closest },
        .{ .name = "getElementsByTagName", .arity = 1, .f = getElementsByTagName },
        .{ .name = "getElementsByClassName", .arity = 1, .f = getElementsByClassName },
        .{ .name = "attachShadow", .arity = 1, .f = attachShadow },
    });
    // What Document, DocumentFragment and Element share.
    for ([_]*js.Object{ element, classes.proto(w, "Document"), classes.proto(w, "DocumentFragment") }) |o| {
        try bind.accessors(vm, o, &.{
            .{ .name = "children", .get = children },
            .{ .name = "childElementCount", .get = childElementCount },
            .{ .name = "firstElementChild", .get = firstElementChild },
            .{ .name = "lastElementChild", .get = lastElementChild },
        });
        try bind.methods(vm, o, &.{
            .{ .name = "querySelector", .arity = 1, .f = querySelector },
            .{ .name = "querySelectorAll", .arity = 1, .f = querySelectorAll },
        });
    }
    const doc = classes.proto(w, "Document");
    try bind.methods(vm, doc, &.{
        .{ .name = "getElementsByTagName", .arity = 1, .f = getElementsByTagName },
        .{ .name = "getElementsByClassName", .arity = 1, .f = getElementsByClassName },
    });
    try bind.accessors(vm, classes.proto(w, "ShadowRoot"), &.{
        .{ .name = "host", .get = shadowHost },
        .{ .name = "innerHTML", .get = innerHTML, .set = setInnerHTML },
    });
    try bind.accessors(vm, classes.proto(w, "DocumentFragment"), &.{
        .{ .name = "nextElementSibling", .get = nextElementSibling },
        .{ .name = "previousElementSibling", .get = previousElementSibling },
    });
    try bind.accessors(vm, classes.proto(w, "CharacterData"), &.{
        .{ .name = "nextElementSibling", .get = nextElementSibling },
        .{ .name = "previousElementSibling", .get = previousElementSibling },
    });
    try bind.accessors(vm, w.protos.html, &.{
        .{ .name = "style", .get = styleOf, .set = setStyleOf },
        .{ .name = "dataset", .get = dataset },
    });
    try bind.accessors(vm, w.protos.svg, &.{
        .{ .name = "style", .get = styleOf, .set = setStyleOf },
        .{ .name = "dataset", .get = dataset },
    });
    try bind.accessors(vm, w.protos.mathml, &.{
        .{ .name = "style", .get = styleOf, .set = setStyleOf },
        .{ .name = "dataset", .get = dataset },
    });
    try bind.accessors(vm, classes.proto(w, "HTMLTemplateElement"), &.{.{ .name = "content", .get = templateContentGet }});
    for ([_]*js.Object{ classes.proto(w, "HTMLAnchorElement"), classes.proto(w, "HTMLLinkElement"), classes.proto(w, "HTMLAreaElement") }) |o| {
        try bind.accessors(vm, o, &.{.{ .name = "relList", .get = relList }});
    }
}
