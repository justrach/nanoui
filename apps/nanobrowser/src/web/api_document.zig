//! Document.prototype: making nodes, finding them, what the document knows of
//! itself, and `document.write` during the initial run.
const std = @import("std");
const js = @import("../js/js.zig");
const dom = @import("../dom.zig");
const html = @import("../html/html.zig");
const bind = @import("bind.zig");
const mutate = @import("mutate.zig");
const scripts = @import("scripts.zig");
const custom = @import("custom.zig");
const classes = @import("classes.zig");
const net = @import("net.zig");
const api_node = @import("api_node.zig");
const Node = dom.Node;
const Value = js.Value;
const Vm = js.Vm;
const Error = js.Error;
const World = bind.World;
const nodeOf = bind.thisNode;

fn docOf(vm: *Vm, this: Value) Error!*dom.Document {
    return (try nodeOf(vm, this)).doc;
}

fn validName(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.mem.indexOfAny(u8, s, " \t\r\n\x0c<>/\"'=") != null) return false;
    return true;
}

fn createElement(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const d = try docOf(vm, this);
    const w = bind.world(vm);
    const name = try bind.str(vm, args, 0);
    if (!validName(name)) return bind.throwDom(vm, "InvalidCharacterError", "The tag name provided is not a valid name.");
    const n = try d.createElement(name);
    if (custom.isCustomName(n.tag)) try custom.created(w, n);
    return bind.wrap(vm, n);
}

fn nsFrom(uri: []const u8) dom.Ns {
    if (std.mem.eql(u8, uri, "http://www.w3.org/2000/svg")) return .svg;
    if (std.mem.eql(u8, uri, "http://www.w3.org/1998/Math/MathML")) return .mathml;
    return .html;
}

fn createElementNS(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const d = try docOf(vm, this);
    const w = bind.world(vm);
    const uri = try bind.strNullEmpty(vm, args, 0);
    const name = try bind.str(vm, args, 1);
    if (!validName(name)) return bind.throwDom(vm, "InvalidCharacterError", "The qualified name provided is not a valid name.");
    const ns = nsFrom(uri);
    const local = if (std.mem.indexOfScalar(u8, name, ':')) |i| name[i + 1 ..] else name;
    const n = try d.createElementNs(local, ns);
    if (ns == .html and custom.isCustomName(n.tag)) try custom.created(w, n);
    return bind.wrap(vm, n);
}

fn createTextNode(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const d = try docOf(vm, this);
    return bind.wrap(vm, try d.createText(try bind.str(vm, args, 0)));
}

fn createComment(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const d = try docOf(vm, this);
    return bind.wrap(vm, try d.createComment(try bind.str(vm, args, 0)));
}

fn createDocumentFragment(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return bind.wrap(vm, try (try docOf(vm, this)).createFragment());
}

fn getElementById(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const name = try bind.str(vm, args, 0);
    if (n.kind == .document) return bind.wrap(vm, n.doc.getElementById(name));
    var at = n.first_child;
    while (at) |x| : (at = x.nextInTree(n)) {
        if (x.kind == .element) if (x.attr("id")) |v| if (std.mem.eql(u8, v, name)) return bind.wrap(vm, x);
    }
    return Value.null;
}

fn documentElement(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return bind.wrap(vm, (try docOf(vm, this)).documentElement());
}

fn head(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return bind.wrap(vm, (try docOf(vm, this)).head());
}

fn body(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return bind.wrap(vm, (try docOf(vm, this)).body());
}

fn setBody(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const d = try docOf(vm, this);
    const w = bind.world(vm);
    const n = try bind.nodeArg(vm, args, 0, "body");
    const root = d.documentElement() orelse return Value.undefined;
    if (d.body()) |old| {
        const next = old.next;
        try mutate.remove(w, root, old);
        try mutate.insert(w, root, n, next);
    } else try mutate.insert(w, root, n, null);
    return Value.undefined;
}

fn doctype(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const d = try docOf(vm, this);
    var k = d.node.first_child;
    while (k) |x| : (k = x.next) if (x.kind == .doctype) return bind.wrap(vm, x);
    return Value.null;
}

fn title(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const d = try docOf(vm, this);
    const w = bind.world(vm);
    const raw = try d.title(w.page.arena());
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(w.gpa);
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n\x0c");
    while (it.next()) |word| {
        if (out.items.len > 0) try out.append(w.gpa, ' ');
        try out.appendSlice(w.gpa, word);
    }
    return vm.newString(out.items);
}

fn setTitle(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const d = try docOf(vm, this);
    const w = bind.world(vm);
    var at = d.node.first_child;
    var found: ?*Node = null;
    while (at) |n| : (at = n.nextInTree(d.node)) {
        if (n.isTag("title")) {
            found = n;
            break;
        }
    }
    const el = found orelse blk: {
        const hd = d.head() orelse return Value.undefined;
        const t = try d.createElement("title");
        hd.appendChild(t);
        break :blk t;
    };
    const f = try d.createFragment();
    f.appendChild(try d.createText(try bind.str(vm, args, 0)));
    try mutate.replaceAllWith(w, el, f);
    w.page.title_stale = true;
    return Value.undefined;
}

fn readyState(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const w = bind.world(vm);
    if (n.doc != w.page.doc) return vm.newString("complete");
    return vm.newString(@tagName(w.runner.phase));
}

fn currentScript(vm: *Vm, _: Value, _: []const Value) Error!Value {
    return bind.wrap(vm, bind.world(vm).runner.current);
}

fn url(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return vm.newString((try docOf(vm, this)).url);
}

fn cookie(vm: *Vm, _: Value, _: []const Value) Error!Value {
    const w = bind.world(vm);
    const text = try net.cookiesForScript(w.gpa, w.page.url());
    defer w.gpa.free(text);
    return vm.newString(text);
}

fn setCookie(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    net.setCookieFromScript(w.page.url(), try bind.str(vm, args, 0));
    return Value.undefined;
}

fn activeElement(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const d = try docOf(vm, this);
    return bind.wrap(vm, d.focus orelse d.body());
}

fn adoptNode(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const d = try docOf(vm, this);
    const n = try bind.nodeArg(vm, args, 0, "adoptNode");
    if (n.parent) |p| try mutate.remove(bind.world(vm), p, n);
    n.doc = d;
    var at = n.first_child;
    while (at) |k| : (at = k.nextInTree(n)) k.doc = d;
    return args[0];
}

fn importNode(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const d = try docOf(vm, this);
    const n = try bind.nodeArg(vm, args, 0, "importNode");
    return bind.wrap(vm, try api_node.clone(bind.world(vm), n, vm.toBoolean(bind.arg(args, 1)), d));
}

/// During the initial run, what a script writes goes in after it. Later, it's ignored.
fn writeText(vm: *Vm, this: Value, args: []const Value, newline: bool) Error!Value {
    const w = bind.world(vm);
    const d = try docOf(vm, this);
    if (d != w.page.doc) return Value.undefined;
    const r = &w.runner;
    if (w.doc_open or (w.page.frame != null and (r.phase != .loading or r.current == null))) return writeToOpen(vm, w, d, args, newline);
    // A write once a tab's page has loaded would wipe it: nobody wants that of a late script.
    if (r.phase != .loading) return Value.undefined;
    const cur = r.current orelse return Value.undefined;
    const parent = cur.parent orelse return Value.undefined;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(w.gpa);
    for (args) |a| try out.appendSlice(w.gpa, try vm.toStringSlice(a));
    if (newline) try out.append(w.gpa, '\n');
    const f = try html.parseFragment(d, if (parent.kind == .element) parent else d.body() orelse return Value.undefined, out.items);
    try scripts.adoptWritten(w, f);
    try mutate.insert(w, parent, f, r.write_anchor);
    return Value.undefined;
}

/// `document.open()` began a new document, or a write after loading has: what's
/// written is the whole of it, parsed as it comes; its scripts run at `close()`.
fn writeToOpen(vm: *Vm, w: *World, d: *dom.Document, args: []const Value, newline: bool) Error!Value {
    w.doc_open = true;
    for (args) |a| try w.doc_written.appendSlice(w.gpa, try vm.toStringSlice(a));
    if (newline) try w.doc_written.append(w.gpa, '\n');
    try reparse(w, d);
    return Value.undefined;
}

fn reparse(w: *World, d: *dom.Document) Error!void {
    d.node.removeChildren();
    const copy = try w.page.arena().dupe(u8, w.doc_written.items);
    try html.parseDocument(d, copy);
    w.page.title_stale = true;
    d.touchStyle();
    w.changed();
}

fn open(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const w = bind.world(vm);
    const d = try docOf(vm, this);
    if (d != w.page.doc or (w.runner.phase == .loading and w.runner.current != null)) return this;
    w.doc_open = true;
    w.doc_written.clearRetainingCapacity();
    try reparse(w, d);
    return this;
}

fn close(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const w = bind.world(vm);
    const d = try docOf(vm, this);
    if (d != w.page.doc or !w.doc_open) return Value.undefined;
    w.doc_open = false;
    if (d.documentElement()) |root| try mutate.arrived(w, root);
    return Value.undefined;
}

fn write(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return writeText(vm, this, args, false);
}

fn writeln(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return writeText(vm, this, args, true);
}

fn newDocument(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const d = try dom.Document.create(w.page.arena());
    d.url = w.page.doc.url;
    try html.parseDocumentWith(d, try bind.str(vm, args, 0), .{ .scripting = false });
    return bind.wrap(vm, d.node);
}

pub const internals = [_]bind.Method{
    .{ .name = "newDocument", .arity = 1, .f = newDocument },
};

pub fn install(w: *World) Error!void {
    const vm = w.vm;
    const doc = classes.proto(w, "Document");
    try bind.accessors(vm, doc, &.{
        .{ .name = "documentElement", .get = documentElement },
        .{ .name = "head", .get = head },
        .{ .name = "body", .get = body, .set = setBody },
        .{ .name = "doctype", .get = doctype },
        .{ .name = "title", .get = title, .set = setTitle },
        .{ .name = "readyState", .get = readyState },
        .{ .name = "currentScript", .get = currentScript },
        .{ .name = "URL", .get = url },
        .{ .name = "documentURI", .get = url },
        .{ .name = "cookie", .get = cookie, .set = setCookie },
        .{ .name = "activeElement", .get = activeElement },
    });
    try bind.methods(vm, doc, &.{
        .{ .name = "createElement", .arity = 1, .f = createElement },
        .{ .name = "createElementNS", .arity = 2, .f = createElementNS },
        .{ .name = "createTextNode", .arity = 1, .f = createTextNode },
        .{ .name = "createComment", .arity = 1, .f = createComment },
        .{ .name = "createDocumentFragment", .arity = 0, .f = createDocumentFragment },
        .{ .name = "getElementById", .arity = 1, .f = getElementById },
        .{ .name = "adoptNode", .arity = 1, .f = adoptNode },
        .{ .name = "importNode", .arity = 1, .f = importNode },
        .{ .name = "write", .arity = 0, .f = write },
        .{ .name = "writeln", .arity = 0, .f = writeln },
        .{ .name = "open", .arity = 0, .f = open },
        .{ .name = "close", .arity = 0, .f = close },
    });
    try classes.proto(w, "DocumentFragment").defineMethod(vm, "getElementById", 1, getElementById);
}
