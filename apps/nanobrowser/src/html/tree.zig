//! The tree builder's state and the operations its insertion modes share:
//! the stack of open elements, scopes, insertion with foster parenting, and
//! the dispatch between HTML and foreign content. The modes themselves are in
//! `tree_head.zig`, `tree_body.zig` and `tree_table.zig`; WHATWG's section
//! 13.2.6 is the reference.
const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("../dom.zig");
const tags = @import("tags.zig");
const tz = @import("tokenizer.zig");
const head = @import("tree_head.zig");
const body = @import("tree_body.zig");
const table = @import("tree_table.zig");
const foreign = @import("tree_foreign.zig");

const T = tags.T;
pub const Token = tz.Token;
pub const Error = Allocator.Error;

pub const Mode = enum {
    initial,
    before_html,
    before_head,
    in_head,
    in_head_noscript,
    after_head,
    in_body,
    text,
    in_table,
    in_table_text,
    in_caption,
    in_column_group,
    in_table_body,
    in_row,
    in_cell,
    in_select,
    in_select_in_table,
    in_template,
    after_body,
    in_frameset,
    after_frameset,
    after_after_body,
    after_after_frameset,
};

/// A mode's verdict on a token: done with it, or look again in the (new) mode.
pub const Act = enum { done, again };

pub const Open = struct { node: *dom.Node, id: T };
/// An entry of active formatting elements; a null node is a marker.
pub const Formatting = struct { node: ?*dom.Node, id: T = .other };

/// Elements nest no deeper than this, as in Blink: restyle and layout are
/// spared a million-deep `<div>`.
const max_depth = 512;

/// An insertion point.
const Place = struct { parent: *dom.Node, before: ?*dom.Node };

pub const Builder = struct {
    doc: *dom.Document,
    arena: Allocator,
    tok: tz.Tokenizer,
    mode: Mode = .initial,
    original_mode: Mode = .in_body,
    table_text_mode: Mode = .in_table,
    template_modes: std.ArrayList(Mode) = .empty,
    open: std.ArrayList(Open) = .empty,
    formatting: std.ArrayList(Formatting) = .empty,
    /// The in-table-text mode's characters.
    pending_text: std.ArrayList([]const u8) = .empty,
    /// Where nodes go that have no element yet, and where the document is built.
    root: *dom.Node,
    head_ptr: ?*dom.Node = null,
    form_ptr: ?*dom.Node = null,
    /// Set in fragment parsing.
    context: ?Open = null,
    frameset_ok: bool = true,
    foster: bool = false,
    scripting: bool = true,
    ignore_lf: bool = false,

    pub fn init(doc: *dom.Document, source: []const u8, root: *dom.Node) Error!Builder {
        return .{
            .doc = doc,
            .arena = doc.arena,
            .tok = try tz.Tokenizer.init(doc.arena, source),
            .root = root,
        };
    }

    /// Runs the tokenizer and the modes to the end of the input.
    pub fn run(b: *Builder) Error!void {
        while (true) {
            b.tok.allow_cdata = if (b.adjustedCurrent()) |c| c.node.ns != .html else false;
            var t = try b.tok.next();
            try b.dispatch(&t);
            if (t == .eof) return;
        }
    }

    fn dispatch(b: *Builder, t: *Token) Error!void {
        if (t.* == .character) {
            var text = t.character;
            if (b.ignore_lf) {
                b.ignore_lf = false;
                if (text.len > 0 and text[0] == '\n') text = text[1..];
            }
            if (std.mem.indexOfScalar(u8, text, 0) != null) {
                const foreign_now = !b.useHtmlRules(t);
                const to = if (foreign_now) "\u{FFFD}" else "";
                text = try std.mem.replaceOwned(u8, b.arena, text, "\x00", to);
            }
            if (text.len == 0) return;
            t.character = text;
        } else b.ignore_lf = false;
        // Every mode change converges; the bound keeps garbage from ever
        // becoming a hang if one were missed.
        var guard: u32 = 0;
        while (guard < 64) : (guard += 1) {
            const act = if (b.useHtmlRules(t)) try b.html(t) else try foreign.process(b, t);
            if (act == .done) return;
        }
    }

    /// The tree construction dispatcher's test.
    fn useHtmlRules(b: *Builder, t: *const Token) bool {
        const c = b.adjustedCurrent() orelse return true;
        if (c.node.ns == .html) return true;
        const start_id: ?*const tz.Tag = if (t.* == .start_tag) &t.start_tag else null;
        if (tags.isMathText(c.id)) {
            if (t.* == .character) return true;
            if (start_id) |s| {
                if (!std.mem.eql(u8, s.name, "mglyph") and !std.mem.eql(u8, s.name, "malignmark")) return true;
            }
        }
        if (c.id == .f_annotation_xml) if (start_id) |s| if (s.id == .svg) return true;
        if (isHtmlIntegration(c)) if (start_id != null or t.* == .character) return true;
        return t.* == .eof;
    }

    pub fn html(b: *Builder, t: *Token) Error!Act {
        return b.htmlIn(b.mode, t);
    }

    /// Runs `t` under the rules of `mode`, which need not be the current one.
    pub fn htmlIn(b: *Builder, mode: Mode, t: *Token) Error!Act {
        return switch (mode) {
            .initial => head.initial(b, t),
            .before_html => head.beforeHtml(b, t),
            .before_head => head.beforeHead(b, t),
            .in_head => head.inHead(b, t),
            .in_head_noscript => head.inHeadNoscript(b, t),
            .after_head => head.afterHead(b, t),
            .in_body => body.inBody(b, t),
            .text => head.text(b, t),
            .in_table => table.inTable(b, t),
            .in_table_text => table.inTableText(b, t),
            .in_caption => table.inCaption(b, t),
            .in_column_group => table.inColumnGroup(b, t),
            .in_table_body => table.inTableBody(b, t),
            .in_row => table.inRow(b, t),
            .in_cell => table.inCell(b, t),
            .in_select => table.inSelect(b, t),
            .in_select_in_table => table.inSelectInTable(b, t),
            .in_template => table.inTemplate(b, t),
            .after_body => head.afterBody(b, t),
            .in_frameset => head.inFrameset(b, t),
            .after_frameset => head.afterFrameset(b, t),
            .after_after_body => head.afterAfterBody(b, t),
            .after_after_frameset => head.afterAfterFrameset(b, t),
        };
    }

    // The stack.

    pub fn current(b: *const Builder) ?Open {
        const items = b.open.items;
        return if (items.len == 0) null else items[items.len - 1];
    }

    /// `current()`'s id, or `.other` when the stack is empty.
    pub fn cur(b: *const Builder) T {
        const c = b.current() orelse return .other;
        return c.id;
    }

    pub fn adjustedCurrent(b: *const Builder) ?Open {
        if (b.context != null and b.open.items.len == 1) return b.context;
        return b.current();
    }

    pub fn push(b: *Builder, n: *dom.Node) Error!void {
        try b.open.append(b.arena, .{ .node = n, .id = tags.idOf(n) });
    }

    /// Pops the current node; the root stays.
    pub fn pop(b: *Builder) void {
        if (b.open.items.len > 1) b.open.items.len -= 1;
    }

    pub fn popAll(b: *Builder) void {
        b.open.items.len = 0;
    }

    pub fn popUntil(b: *Builder, id: T) void {
        while (b.open.items.len > 1) {
            const c = b.cur();
            b.pop();
            if (c == id) return;
        }
    }

    pub fn popUntilHeading(b: *Builder) void {
        while (b.open.items.len > 1) {
            const c = b.cur();
            b.pop();
            if (tags.isHeading(c)) return;
        }
    }

    /// Pops up to and including `n`.
    pub fn popUntilNode(b: *Builder, n: *dom.Node) void {
        while (b.open.items.len > 1) {
            const c = b.current().?.node;
            b.pop();
            if (c == n) return;
        }
    }

    pub fn stackIndex(b: *const Builder, n: *const dom.Node) ?usize {
        var i = b.open.items.len;
        while (i > 0) {
            i -= 1;
            if (b.open.items[i].node == n) return i;
        }
        return null;
    }

    pub fn removeFromStack(b: *Builder, n: *const dom.Node) void {
        if (b.stackIndex(n)) |i| _ = b.open.orderedRemove(i);
    }

    pub fn onStack(b: *const Builder, id: T) bool {
        for (b.open.items) |e| if (e.id == id) return true;
        return false;
    }

    // Scopes.

    pub fn inScope(b: *const Builder, id: T) bool {
        var i = b.open.items.len;
        while (i > 0) {
            i -= 1;
            const e = b.open.items[i].id;
            if (e == id) return true;
            if (tags.endsScope(e)) return false;
        }
        return false;
    }

    pub fn nodeInScope(b: *const Builder, n: *const dom.Node) bool {
        var i = b.open.items.len;
        while (i > 0) {
            i -= 1;
            if (b.open.items[i].node == n) return true;
            if (tags.endsScope(b.open.items[i].id)) return false;
        }
        return false;
    }

    pub fn inListScope(b: *const Builder, id: T) bool {
        var i = b.open.items.len;
        while (i > 0) {
            i -= 1;
            const e = b.open.items[i].id;
            if (e == id) return true;
            if (tags.endsScope(e) or e == .ol or e == .ul) return false;
        }
        return false;
    }

    pub fn inButtonScope(b: *const Builder, id: T) bool {
        var i = b.open.items.len;
        while (i > 0) {
            i -= 1;
            const e = b.open.items[i].id;
            if (e == id) return true;
            if (tags.endsScope(e) or e == .button) return false;
        }
        return false;
    }

    pub fn inTableScope(b: *const Builder, id: T) bool {
        var i = b.open.items.len;
        while (i > 0) {
            i -= 1;
            const e = b.open.items[i].id;
            if (e == id) return true;
            if (e == .html or e == .table or e == .template) return false;
        }
        return false;
    }

    pub fn inSelectScope(b: *const Builder, id: T) bool {
        var i = b.open.items.len;
        while (i > 0) {
            i -= 1;
            const e = b.open.items[i].id;
            if (e == id) return true;
            if (e != .optgroup and e != .option) return false;
        }
        return false;
    }

    pub fn headingInScope(b: *const Builder) bool {
        var i = b.open.items.len;
        while (i > 0) {
            i -= 1;
            const e = b.open.items[i].id;
            if (tags.isHeading(e)) return true;
            if (tags.endsScope(e)) return false;
        }
        return false;
    }

    pub fn generateImplied(b: *Builder, except: T) void {
        while (b.open.items.len > 1) {
            const c = b.cur();
            if (c == except or !tags.isImpliedEnd(c)) return;
            b.pop();
        }
    }

    pub fn generateThorough(b: *Builder) void {
        while (b.open.items.len > 1 and tags.isThoroughEnd(b.cur())) b.pop();
    }

    pub fn closeP(b: *Builder) void {
        if (!b.inButtonScope(.p)) return;
        b.generateImplied(.p);
        b.popUntil(.p);
    }

    // Insertion.

    pub fn newElement(b: *Builder, name: []const u8, ns: dom.Ns, attrs: []dom.Attr) Error!*dom.Node {
        const n = try b.arena.create(dom.Node);
        const perf = @import("../perf_rules.zig");
        n.* = .{ .kind = .element, .doc = b.doc, .tag = name, .ns = ns, .html_tag = if (ns == .html) perf.classifyHtmlTag(name) else .other, .has_resource = perf.isResourceTag(name), .has_insertion_work = perf.isInsertionWorkTag(name) };
        if (attrs.len > 0) {
            n.attrs = .fromOwnedSlice(attrs);
            for (attrs) |a| {
                if (a.name.len > 2 and a.name[0] == 'o' and a.name[1] == 'n') n.has_on_attr = true;
                perf.syncNodeAttr(n, a.name, a.value);
            }
        }
        return n;
    }

    /// A copy of an element for the formatting list and adoption agency.
    pub fn cloneElement(b: *Builder, n: *const dom.Node) Error!*dom.Node {
        const attrs = try b.arena.dupe(dom.Attr, n.attrs.items);
        return b.newElement(n.tag, n.ns, attrs);
    }

    /// Where a node goes: the "appropriate place for inserting a node".
    pub fn placeFor(b: *Builder, over: ?*dom.Node) Place {
        const target = contentOf(over orelse if (b.current()) |c| c.node else b.root);
        if (b.foster and fosterTarget(target)) {
            var i = b.open.items.len;
            while (i > 0) {
                i -= 1;
                const e = b.open.items[i];
                if (e.id == .template) return .{ .parent = contentOf(e.node), .before = null };
                if (e.id == .table) {
                    if (e.node.parent) |p| return .{ .parent = p, .before = e.node };
                    return .{ .parent = b.open.items[i - 1].node, .before = null };
                }
            }
            return .{ .parent = b.open.items[0].node, .before = null };
        }
        return .{ .parent = target, .before = null };
    }

    fn fosterTarget(n: *const dom.Node) bool {
        if (n.ns != .html) return false;
        const id = tags.htmlId(n.tag);
        return id == .table or tags.isTableSection(id) or id == .tr;
    }

    /// Where what goes in a node goes: a template's content rather than the template.
    fn contentOf(n: *dom.Node) *dom.Node {
        if (n.ns == .html and n.isTag("template")) if (n.template_content) |f| return f;
        return n;
    }

    /// Creates an element and places it, without entering it on the stack.
    pub fn insertNew(b: *Builder, name: []const u8, ns: dom.Ns, attrs: []dom.Attr) Error!*dom.Node {
        // Past the depth limit, new elements become the deepest element's
        // siblings.
        if (b.open.items.len >= max_depth) b.pop();
        const n = try b.newElement(name, ns, attrs);
        const at = b.placeFor(null);
        at.parent.parserInsert(n, at.before);
        return n;
    }

    /// "Insert an HTML element".
    pub fn insert(b: *Builder, t: *const tz.Tag) Error!*dom.Node {
        const n = try b.insertNew(t.name, .html, t.attrs);
        try b.open.append(b.arena, .{ .node = n, .id = t.id });
        return n;
    }

    /// Inserts an HTML element from a bare id (an implied `<tbody>`, say).
    pub fn insertImplied(b: *Builder, name: []const u8) Error!*dom.Node {
        const n = try b.insertNew(name, .html, &.{});
        try b.open.append(b.arena, .{ .node = n, .id = tags.htmlId(name) });
        return n;
    }

    /// Inserts and leaves at once: a void element.
    pub fn insertVoid(b: *Builder, t: *const tz.Tag) Error!void {
        _ = try b.insert(t);
        b.pop();
    }

    pub fn insertForeign(b: *Builder, name: []const u8, ns: dom.Ns, attrs: []dom.Attr) Error!*dom.Node {
        const n = try b.insertNew(name, ns, attrs);
        try b.push(n);
        return n;
    }

    pub fn insertText(b: *Builder, s: []const u8) Error!void {
        if (s.len == 0) return;
        const at = b.placeFor(null);
        const prev = if (at.before) |r| r.prev else at.parent.last_child;
        if (prev) |p| if (p.kind == .text) {
            p.data = try std.mem.concat(b.arena, u8, &.{ p.data, s });
            return;
        };
        if (at.parent.kind == .document) return;
        const n = try b.arena.create(dom.Node);
        n.* = .{ .kind = .text, .doc = b.doc, .data = s };
        at.parent.parserInsert(n, at.before);
    }

    pub fn insertComment(b: *Builder, s: []const u8, into: ?*dom.Node) Error!void {
        const n = try b.arena.create(dom.Node);
        n.* = .{ .kind = .comment, .doc = b.doc, .data = s };
        const parent = into orelse contentOf(if (b.current()) |c| c.node else b.root);
        parent.parserInsert(n, null);
    }

    /// Gives `n` the attributes of `t` it does not have (`<html>`, `<body>`
    /// seen a second time).
    pub fn addMissingAttrs(b: *Builder, n: *dom.Node, t: *const tz.Tag) Error!void {
        for (t.attrs) |a| {
            if (n.hasAttr(a.name)) continue;
            if (a.name.len > 2 and a.name[0] == 'o' and a.name[1] == 'n') n.has_on_attr = true;
            try n.attrs.append(b.arena, a);
            @import("../perf_rules.zig").syncNodeAttr(n, a.name, a.value);
        }
    }

    /// The generic raw text and RCDATA parsing algorithms.
    pub fn parseRaw(b: *Builder, t: *const tz.Tag, state: tz.State) Error!void {
        _ = try b.insert(t);
        b.tok.state = state;
        b.original_mode = b.mode;
        b.mode = .text;
    }

    /// "Reset the insertion mode appropriately".
    pub fn resetMode(b: *Builder) void {
        var i = b.open.items.len;
        while (i > 0) {
            i -= 1;
            var e = b.open.items[i];
            const last = i == 0;
            if (last) if (b.context) |c| {
                e = c;
            };
            switch (e.id) {
                .select => {
                    if (!last) {
                        var j = i;
                        while (j > 0) {
                            j -= 1;
                            const a = b.open.items[j].id;
                            if (a == .template) break;
                            if (a == .table) {
                                b.mode = .in_select_in_table;
                                return;
                            }
                        }
                    }
                    b.mode = .in_select;
                    return;
                },
                .td, .th => if (!last) {
                    b.mode = .in_cell;
                    return;
                },
                .tr => return b.setMode(.in_row),
                .tbody, .thead, .tfoot => return b.setMode(.in_table_body),
                .caption => return b.setMode(.in_caption),
                .colgroup => return b.setMode(.in_column_group),
                .table => return b.setMode(.in_table),
                .template => {
                    const m = b.template_modes.items;
                    return b.setMode(if (m.len > 0) m[m.len - 1] else .in_body);
                },
                .head => if (!last) return b.setMode(.in_head),
                .body => return b.setMode(.in_body),
                .frameset => return b.setMode(.in_frameset),
                .html => return b.setMode(if (b.head_ptr == null) .before_head else .after_head),
                else => {},
            }
            if (last) return b.setMode(.in_body);
        }
        b.setMode(.in_body);
    }

    fn setMode(b: *Builder, m: Mode) void {
        b.mode = m;
    }
};

pub fn isHtmlIntegration(c: Open) bool {
    if (c.id == .f_foreign_object or c.id == .f_desc or c.id == .f_title) return true;
    if (c.id != .f_annotation_xml) return false;
    const enc = c.node.attr("encoding") orelse return false;
    return std.ascii.eqlIgnoreCase(enc, "text/html") or std.ascii.eqlIgnoreCase(enc, "application/xhtml+xml");
}

/// Whitespace as the parser counts it.
pub fn isWs(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\t' or c == 0x0c or c == '\r';
}

pub fn allWs(s: []const u8) bool {
    for (s) |c| if (!isWs(c)) return false;
    return true;
}

/// The length of `s`'s leading whitespace.
pub fn wsPrefix(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and isWs(s[i])) : (i += 1) {}
    return i;
}
