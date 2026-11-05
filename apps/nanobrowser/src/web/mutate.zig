//! Every change a script makes to the tree passes through here, so that each
//! has its consequences in one place: mutation records, custom element
//! callbacks, scripts running when connected, a frame asked for. No layout:
//! the document's dirty flags say what the next frame or geometry read redoes.
const std = @import("std");
const frames = @import("../frames.zig");
const js = @import("../js/js.zig");
const dom = @import("../dom.zig");
const bind = @import("bind.zig");
const custom = @import("custom.zig");
const scripts = @import("scripts.zig");
const loader = @import("../loader.zig");
const web = @import("web.zig");
const World = bind.World;
const Node = dom.Node;
const Value = js.Value;
const Error = js.Error;

pub fn isConnected(n: *const Node) bool {
    var at: ?*const Node = n;
    while (at) |x| : (at = x.parent) {
        if (x.kind == .document) return true;
    }
    return false;
}

/// Connected to the page's own document, not one a script made.
fn inPage(w: *const World, n: *const Node) bool {
    var at: ?*const Node = n;
    while (at) |x| : (at = x.parent) {
        if (x.kind == .document) return x == w.page.doc.node;
    }
    return false;
}

fn adoptTree(n: *Node, doc: *dom.Document) void {
    if (n.doc == doc) return;
    n.doc = doc;
    var at = n.first_child;
    while (at) |k| : (at = k.nextInTree(n)) k.doc = doc;
}

/// An inline `<svg>` is drawn from its markup: what changes in it asks for that again.
fn svgChanged(n: *Node) void {
    if (n.ns != .svg) return;
    n.doc.svg_version +%= 1;
    n.doc.svg_dirty = true;
}

/// Moves `child` to before `ref` in `parent`, a fragment giving its children.
/// The hierarchy has been checked by the caller.
pub fn insert(w: *World, parent: *Node, child: *Node, ref: ?*Node) Error!void {
    svgChanged(parent);
    if (child.kind == .fragment) {
        var list: std.ArrayList(*Node) = .empty;
        defer list.deinit(w.gpa);
        var k = child.first_child;
        while (k) |x| : (k = x.next) try list.append(w.gpa, x);
        if (list.items.len == 0) return;
        if (w.observed.items.len > 0) try recordChildren(w, child, &.{}, list.items, null, null);
        const prev = if (ref) |r| r.prev else parent.last_child;
        for (list.items) |x| {
            adoptTree(x, parent.doc);
            parent.insertBefore(x, ref);
        }
        if (w.observed.items.len > 0) try recordChildren(w, parent, list.items, &.{}, prev, ref);
        w.changed();
        for (list.items) |x| try inserted(w, x);
        return afterChildren(w, parent);
    }
    const old_parent = child.parent;
    if (old_parent) |old| try removeOnly(w, old, child);
    adoptTree(child, parent.doc);
    const prev = if (ref) |r| r.prev else parent.last_child;
    parent.insertBefore(child, ref);
    if (w.observed.items.len > 0) try recordChildren(w, parent, &.{child}, &.{}, prev, ref);
    w.changed();
    try inserted(w, child);
    return afterChildren(w, parent);
}

/// What a parent's own kind makes of a change to its children.
fn afterChildren(w: *World, parent: *Node) Error!void {
    if (parent.kind != .element) return;
    if (parent.isTag("script")) {
        if (inPage(w, parent)) try scripts.connected(w, parent);
    } else if (parent.isTag("title")) w.page.title_stale = true;
}

/// Takes `child` out of `parent`, telling whoever should know.
pub fn remove(w: *World, parent: *Node, child: *Node) Error!void {
    svgChanged(parent);
    try removeOnly(w, parent, child);
    w.changed();
    if (parent.isTag("title")) w.page.title_stale = true;
}

fn removeOnly(w: *World, parent: *Node, child: *Node) Error!void {
    const was_connected = inPage(w, parent);
    const prev = bind.prevSibling(child);
    const next = child.next;
    forgetState(w, child);
    child.remove();
    if (w.observed.items.len > 0) try recordChildren(w, parent, &.{}, &.{child}, prev, next);
    if (was_connected) try removed(w, child);
}

/// The document's pointers at this subtree go: it isn't there to focus.
fn forgetState(w: *World, n: *Node) void {
    const d = n.doc;
    if (d.focus) |f| if (n.contains(f)) {
        d.focus = null;
    };
    if (d.hover) |f| if (n.contains(f)) {
        d.hover = null;
    };
    if (d.active) |f| if (n.contains(f)) {
        d.active = null;
    };
    if (w.page.open_select) |s| if (n.contains(s)) {
        w.page.open_select = null;
    };
}

/// Empties `n`.
pub fn removeAllChildren(w: *World, n: *Node) Error!void {
    if (bind.firstChild(n) == null) return;
    var list: std.ArrayList(*Node) = .empty;
    defer list.deinit(w.gpa);
    var k = bind.firstChild(n);
    while (k) |x| : (k = x.next) try list.append(w.gpa, x);
    const connected = inPage(w, n);
    for (list.items) |x| {
        forgetState(w, x);
        x.remove();
    }
    if (w.observed.items.len > 0) try recordChildren(w, n, &.{}, list.items, null, null);
    w.changed();
    if (connected) for (list.items) |x| try removed(w, x);
}

/// `n`'s children become what `fragment` holds, as one change.
pub fn replaceAllWith(w: *World, n: *Node, fragment: ?*Node) Error!void {
    svgChanged(n);
    var gone: std.ArrayList(*Node) = .empty;
    defer gone.deinit(w.gpa);
    var added: std.ArrayList(*Node) = .empty;
    defer added.deinit(w.gpa);
    var k = bind.firstChild(n);
    while (k) |x| : (k = x.next) try gone.append(w.gpa, x);
    const connected = inPage(w, n);
    for (gone.items) |x| {
        forgetState(w, x);
        x.remove();
    }
    if (fragment) |f| {
        k = f.first_child;
        while (k) |x| : (k = x.next) try added.append(w.gpa, x);
        for (added.items) |x| {
            adoptTree(x, n.doc);
            n.insertBefore(x, null);
        }
    }
    if (w.observed.items.len > 0 and (gone.items.len > 0 or added.items.len > 0)) try recordChildren(w, n, added.items, gone.items, null, null);
    w.changed();
    if (connected) for (gone.items) |x| try removed(w, x);
    for (added.items) |x| try inserted(w, x);
    return afterChildren(w, n);
}

/// What `document.write` put in the tree: as if it had just arrived.
pub fn arrived(w: *World, n: *Node) Error!void {
    return inserted(w, n);
}

/// A node arrived in the tree: its scripts run, its custom elements begin.
fn inserted(w: *World, n: *Node) Error!void {
    if (n.kind != .element or !inPage(w, n)) return;
    var pending: std.ArrayList(*Node) = .empty;
    defer pending.deinit(w.gpa);
    var at: ?*Node = n;
    while (at) |x| : (at = x.nextDeep(n)) {
        if (x.kind != .element) continue;
        if (x.isTag("script") and w.page.no_scripts) continue;
        if (x.isTag("script") or custom.isCustomName(x.tag)) {
            try pending.append(w.gpa, x);
        } else if (x.isTag("iframe")) {
            // There at once: a script may reach into it on the next line.
            frames.note(w.page, x);
        } else if (x.isTag("link") and !isSheet(x)) {
            // What won't load here is taken as loaded: nobody waits for ever.
            web.imageDone(w.page, x, true);
        }
    }
    for (pending.items) |x| {
        if (x.isTag("script")) {
            try scripts.connected(w, x);
        } else {
            try custom.connected(w, x);
        }
    }
}

fn isSheet(n: *const Node) bool {
    var words = std.mem.tokenizeAny(u8, n.attr("rel") orelse return false, " \t\r\n");
    while (words.next()) |w| if (std.ascii.eqlIgnoreCase(w, "stylesheet")) return true;
    return false;
}

fn removed(w: *World, n: *Node) Error!void {
    if (n.kind == .element and w.page.frames.list.items.len > 0) frames.sweep(w.page);
    if (n.kind != .element or w.custom.upgraded.count() == 0) return;
    var pending: std.ArrayList(*Node) = .empty;
    defer pending.deinit(w.gpa);
    var at: ?*Node = n;
    while (at) |x| : (at = x.nextDeep(n)) {
        if (x.kind == .element and w.custom.upgraded.contains(x)) try pending.append(w.gpa, x);
    }
    for (pending.items) |x| try custom.disconnected(w, x);
}

fn firesOnAttr(name: []const u8) bool {
    return name.len > 2 and name[0] == 'o' and name[1] == 'n';
}

/// Sets an attribute. `name` as stored (lowercased for HTML).
pub fn setAttr(w: *World, n: *Node, name: []const u8, value: []const u8) Error!void {
    const old = n.attr(name);
    if (old) |o| if (o.ptr == value.ptr) return;
    try recordAttr(w, n, name, old);
    svgChanged(n);
    try n.setAttr(name, value);
    w.changed();
    try attrChanged(w, n, name, old, value);
    if (old == null and n.isTag("details") and std.mem.eql(u8, name, "open")) web.detailsToggled(w.page, n);
}

pub fn removeAttr(w: *World, n: *Node, name: []const u8) Error!void {
    const old = n.attr(name) orelse return;
    try recordAttr(w, n, name, old);
    svgChanged(n);
    n.removeAttr(name);
    w.changed();
    try attrChanged(w, n, name, old, null);
}

fn recordAttr(w: *World, n: *Node, name: []const u8, old: ?[]const u8) Error!void {
    if (w.observed.items.len == 0) return;
    for (w.observed.items) |o| {
        if (!o.attributes or !(o.node == n or (o.subtree and o.node.contains(n)))) continue;
        if (o.filter.isObject() and !try filterHas(w, o.filter, name)) continue;
        const args = [_]Value{
            o.observer,                   try w.vm.newString("attributes"),                      try bind.wrap(w.vm, n), Value.null, Value.null,
            Value.null,                   Value.null,                                            try w.vm.newString(name),
            if (o.old_attr) try bind.optStr(w.vm, old) else Value.null,
        };
        _ = try w.vm.call(w.h.moRecord, Value.undefined, &args);
    }
}

fn filterHas(w: *World, filter: Value, name: []const u8) Error!bool {
    const arr = filter.asObject();
    const len = try w.vm.toNumber(try arr.get(w.vm, "length"));
    var i: u32 = 0;
    while (@as(f64, @floatFromInt(i)) < len) : (i += 1) {
        const s = try w.vm.toStringSlice(try arr.getIdx(w.vm, i));
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

/// What an attribute's change means to its element.
fn attrChanged(w: *World, n: *Node, name: []const u8, old: ?[]const u8, value: ?[]const u8) Error!void {
    if (firesOnAttr(name)) w.listen(name[2..]);
    if (n.kind == .element and n.ns == .html) {
        if (n.isTag("img")) {
            if (std.mem.eql(u8, name, "src") or std.mem.eql(u8, name, "srcset") or std.mem.eql(u8, name, "sizes")) {
                n.image_key = "";
                n.image = "";
                try @import("api_forms.zig").imageAsked(w, n);
            }
        } else if (n.isTag("source")) {
            // What it says goes to the picture it's beside.
            if (std.mem.eql(u8, name, "srcset") or std.mem.eql(u8, name, "media") or std.mem.eql(u8, name, "type") or std.mem.eql(u8, name, "sizes")) {
                var k = if (n.parent) |up| up.first_child else null;
                while (k) |x| : (k = x.next) if (x.isTag("img")) {
                    x.image_key = "";
                    x.image = "";
                    try @import("api_forms.zig").imageAsked(w, x);
                };
            }
        } else if (n.isTag("link")) {
            if (std.mem.eql(u8, name, "href") or std.mem.eql(u8, name, "rel")) loader.forget(w.page, n);
        } else if (n.isTag("input")) {
            if (std.mem.eql(u8, name, "value") and n.value == null) {
                if (n.editor) |e| @import("api_forms.zig").editorSet(e, value orelse "");
            }
        } else if (n.isTag("script")) {
            if (std.mem.eql(u8, name, "src") and inPage(w, n)) try scripts.connected(w, n);
        }
    }
    try custom.attributeChanged(w, n, name, old, value);
}

/// A text's or comment's characters change.
pub fn setData(w: *World, n: *Node, s: []const u8) Error!void {
    if (w.observed.items.len > 0) {
        for (w.observed.items) |o| {
            if (!o.character_data or !(o.node == n or (o.subtree and o.node.contains(n)))) continue;
            const args = [_]Value{
                o.observer, try w.vm.newString("characterData"), try bind.wrap(w.vm, n), Value.null, Value.null,
                Value.null, Value.null,                         Value.null,
                if (o.old_data) try w.vm.newString(n.data) else Value.null,
            };
            _ = try w.vm.call(w.h.moRecord, Value.undefined, &args);
        }
    }
    try n.setData(s);
    w.changed();
    if (n.parent) |p| if (p.isTag("title")) {
        w.page.title_stale = true;
    } else if (p.isTag("style")) p.doc.touchStyle();
}

fn recordChildren(w: *World, target: *Node, added: []const *Node, gone: []const *Node, prev: ?*Node, next: ?*Node) Error!void {
    for (w.observed.items) |o| {
        if (!o.child_list or !(o.node == target or (o.subtree and o.node.contains(target)))) continue;
        const args = [_]Value{
            o.observer,              try w.vm.newString("childList"), try bind.wrap(w.vm, target),
            try nodeArray(w, added), try nodeArray(w, gone),          try bind.wrap(w.vm, prev),
            try bind.wrap(w.vm, next), Value.null,                    Value.null,
        };
        _ = try w.vm.call(w.h.moRecord, Value.undefined, &args);
    }
}

fn nodeArray(w: *World, nodes: []const *Node) Error!Value {
    const arr = try w.vm.newArray(&.{});
    for (nodes, 0..) |n, i| try arr.setIdx(w.vm, @intCast(i), try bind.wrap(w.vm, n));
    return arr.value();
}
