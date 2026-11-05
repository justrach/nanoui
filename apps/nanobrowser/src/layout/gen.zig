//! Box generation: from the styled document to the box tree. Skips what does
//! not display, splices `display: contents`, makes `::before` and `::after`,
//! wraps inline runs beside blocks in anonymous blocks, splits inlines around
//! the blocks inside them and caps nesting so that odd input cannot run the
//! later passes out of stack. Table fix-up is in `gen_table.zig`.
const std = @import("std");
const box = @import("box.zig");
const css = @import("../css/style.zig");
const dom = @import("../dom.zig");
const ctx = @import("ctx.zig");
const hints = @import("hints.zig");
const list = @import("list.zig");
const text = @import("text.zig");
const replaced = @import("replaced.zig");
const gen_table = @import("gen_table.zig");
const Box = box.Box;
const Entry = box.Entry;
const Ctx = ctx.Ctx;
const Error = ctx.Error;
const Style = css.Style;

/// Elements nested deeper than this are dropped.
pub const max_depth: u32 = 512;

pub const Gen = struct {
    c: *Ctx,
    stack: std.ArrayList(Entry) = .empty,
    depth: u32 = 0,
    /// The next list item's number, and which way it goes.
    counter: i64 = 1,
    counter_step: i64 = 1,
    /// `align` and `nowrap` on the way down.
    text_align: ?css.TextAlign = null,
    nowrap: bool = false,
};

/// Builds the tree under a fresh initial containing block.
pub fn build(c: *Ctx, doc: *dom.Document) Error!*Box {
    const root_style = try c.arena.create(Style);
    root_style.* = .{ .display = .block };
    const root = try c.arena.create(Box);
    root.* = .{ .kind = .block, .style = root_style };
    var g: Gen = .{ .c = c };
    var k = doc.node.first_child;
    while (k) |n| : (k = n.next) if (n.kind == .element) try element(&g, n);
    const entries = try c.arena.dupe(Entry, g.stack.items);
    g.stack.clearRetainingCapacity();
    try container(&g, root, entries);
    return root;
}

pub fn newBox(c: *Ctx, kind: box.Kind, node: ?*dom.Node, s: *const Style) Error!*Box {
    const b = try c.arena.create(Box);
    b.* = .{ .kind = kind, .node = node, .style = s, .positioned = s.isOutOfFlow() };
    return b;
}

fn kindFor(s: *const Style) box.Kind {
    return switch (s.display) {
        .flex, .inline_flex => .flex,
        .grid, .inline_grid => .grid,
        .table, .inline_table => .table,
        .table_row_group, .table_header_group, .table_footer_group => .table_row_group,
        .table_row => .table_row,
        .table_cell => .table_cell,
        .table_caption => .table_caption,
        .inline_ => if (s.isOutOfFlow() or s.float != .none) .block else .inline_box,
        else => .block,
    };
}

fn isReplacedTag(n: *const dom.Node) bool {
    if (n.ns == .svg) return n.isTag("svg");
    if (n.ns != .html) return false;
    for ([_][]const u8{ "img", "canvas", "video", "iframe", "object", "embed" }) |t| {
        if (n.isTag(t)) return true;
    }
    return false;
}

fn inputType(n: *const dom.Node) []const u8 {
    return n.attr("type") orelse "text";
}

fn isButtonInput(n: *const dom.Node) bool {
    if (!n.isTag("input")) return false;
    const t = inputType(n);
    return std.ascii.eqlIgnoreCase(t, "submit") or std.ascii.eqlIgnoreCase(t, "button") or std.ascii.eqlIgnoreCase(t, "reset");
}

fn isControlTag(n: *const dom.Node) bool {
    if (n.ns != .html) return false;
    if (isButtonInput(n)) return false;
    for ([_][]const u8{ "input", "select", "textarea", "progress", "meter" }) |t| {
        if (n.isTag(t)) return true;
    }
    return false;
}

/// An atom must not be an inline box whatever the sheet says.
fn atomStyle(c: *Ctx, s: *const Style) Error!*const Style {
    if (s.display != .inline_) return s;
    const copy = try c.arena.create(Style);
    copy.* = s.*;
    copy.display = .inline_block;
    return copy;
}

fn push(g: *Gen, e: Entry) Error!void {
    try g.stack.append(g.c.arena, e);
}

fn element(g: *Gen, n: *dom.Node) Error!void {
    if (g.depth >= max_depth) return;
    const s0 = n.computed orelse return;
    if (s0.display == .none) return;
    if (n.ns == .html) {
        if (n.isTag("br")) return push(g, .{ .tag = .br, .style = s0 });
        if (n.isTag("wbr")) return push(g, .{ .tag = .wbr });
        if (n.isTag("input") and std.ascii.eqlIgnoreCase(inputType(n), "hidden")) return;
    }
    if (s0.display == .table_column or s0.display == .table_column_group) return;
    g.depth += 1;
    defer g.depth -= 1;
    if (s0.display == .contents) {
        try pseudo(g, n, n.before);
        try children(g, n, s0);
        try pseudo(g, n, n.after);
        return;
    }
    const saved_align = g.text_align;
    const saved_nowrap = g.nowrap;
    const is_list = n.isTag("ol") or n.isTag("ul") or n.isTag("menu") or n.isTag("dir");
    const saved_counter = g.counter;
    const saved_step = g.counter_step;
    defer {
        g.text_align = saved_align;
        g.nowrap = saved_nowrap;
        if (is_list) {
            g.counter = saved_counter;
            g.counter_step = saved_step;
        }
    }
    const s = try hints.apply(g.c, n, s0);
    hints.descend(g, n);

    if (isReplacedTag(n)) {
        if (brokenAlt(g.c, n)) |alt| return altBox(g, n, s, alt);
        const b = try newBox(g.c, .replaced, n, try atomStyle(g.c, s));
        n.box = b;
        return push(g, .{ .tag = .box, .box = b, .style = b.style });
    }
    if (isControlTag(n)) {
        const b = try newBox(g.c, .control, n, try atomStyle(g.c, s));
        n.box = b;
        return push(g, .{ .tag = .box, .box = b, .style = b.style });
    }
    const is_button = n.ns == .html and (n.isTag("button") or isButtonInput(n));
    const st = if (is_button) try atomStyle(g.c, s) else s;
    const b = try newBox(g.c, kindFor(st), n, st);
    n.box = b;
    if (is_button) {
        b.lay.shrink = true;
        b.lay.center_v = true;
        if (st.text_align == .start) g.text_align = .center;
    }
    const base = g.stack.items.len;
    if (st.display == .list_item) try marker(g, b, n, st);
    try pseudo(g, n, n.before);
    if (isButtonInput(n)) {
        const v = n.value orelse n.attr("value") orelse buttonDefault(n);
        if (v.len > 0) try push(g, .{ .tag = .generated, .text = v, .style = st });
    } else try children(g, n, st);
    try pseudo(g, n, n.after);
    try finish(g, b, base);
}

fn buttonDefault(n: *const dom.Node) []const u8 {
    const t = inputType(n);
    if (std.ascii.eqlIgnoreCase(t, "submit")) return "Submit";
    if (std.ascii.eqlIgnoreCase(t, "reset")) return "Reset";
    return "";
}

/// A picture that will not come, with words to stand for it, and no size asked.
fn brokenAlt(c: *Ctx, n: *dom.Node) ?[]const u8 {
    if (!n.isTag("img")) return null;
    if (c.m.image(c.m.ctx, n) != null) return null;
    // Not asked for yet: it needs a box to come near the window with.
    if (n.image_key.len == 0 and isLazy(n)) return null;
    if (replaced.dimAttr(n, "width") != null and replaced.dimAttr(n, "height") != null) return null;
    const alt = n.attr("alt") orelse return null;
    if (alt.len == 0) return null;
    return alt;
}

fn isLazy(n: *const dom.Node) bool {
    const v = n.attr("loading") orelse return false;
    return std.ascii.eqlIgnoreCase(v, "lazy");
}

fn altBox(g: *Gen, n: *dom.Node, s: *const Style, alt: []const u8) Error!void {
    const b = try newBox(g.c, kindFor(s), n, s);
    n.box = b;
    const base = g.stack.items.len;
    try push(g, .{ .tag = .generated, .text = alt, .style = s });
    try finish(g, b, base);
}

fn marker(g: *Gen, b: *Box, n: *dom.Node, s: *const Style) Error!void {
    if (n.ns == .html and n.attr("value") != null) {
        const v = std.mem.trim(u8, n.attr("value").?, " \t\r\n");
        g.counter = std.fmt.parseInt(i64, v, 10) catch g.counter;
    }
    const value = g.counter;
    // The list's counter is what the item changes: it survives the item.
    const text_str = try list.counterText(g.c.arena, s.list_style, value);
    g.counter += g.counter_step;
    if (s.list_style == .none) return;
    if (s.list_inside) {
        if (text_str) |t| {
            const with_space = try std.fmt.allocPrint(g.c.arena, "{s} ", .{t});
            try push(g, .{ .tag = .generated, .text = with_space, .style = s });
        } else try push(g, .{ .tag = .bullet, .style = s });
        return;
    }
    b.lay.has_marker = true;
    b.lay.marker_text = text_str orelse "";
}

fn children(g: *Gen, n: *dom.Node, s: *const Style) Error!void {
    // A shadow host renders its shadow tree; its own children go by its slots.
    if (n.first_child) |first| if (first.is_shadow) return element(g, first);
    if (!n.is_shadow and n.isTag("slot")) if (shadowHostOf(n)) |host| {
        if (try slotted(g, n, host, s)) return;
    };
    var k = n.first_child;
    while (k) |x| : (k = x.next) try child(g, x, s);
}

fn child(g: *Gen, x: *dom.Node, s: *const Style) Error!void {
    switch (x.kind) {
        .element => try element(g, x),
        .text => if (x.data.len > 0) try push(g, .{ .tag = .text, .node = x, .text = x.data, .style = s }),
        else => {},
    }
}

fn shadowHostOf(n: *const dom.Node) ?*dom.Node {
    var at = n.parent;
    while (at) |a| : (at = a.parent) if (a.is_shadow) return a.parent;
    return null;
}

/// The children of `host` this `<slot>` takes. False when none: it then shows its own.
fn slotted(g: *Gen, slot: *dom.Node, host: *dom.Node, s: *const Style) Error!bool {
    const name = slot.attr("name") orelse "";
    var any = false;
    var k = host.first_child;
    while (k) |x| : (k = x.next) {
        if (x.is_shadow) continue;
        const wants = if (x.kind == .element) x.attr("slot") orelse "" else "";
        if (!std.mem.eql(u8, wants, name)) continue;
        any = true;
        try child(g, x, s);
    }
    return any;
}

fn pseudo(g: *Gen, n: *dom.Node, sp: ?*const Style) Error!void {
    const s = sp orelse return;
    if (s.display == .none or s.display == .contents) return;
    if (g.depth >= max_depth) return;
    const b = try newBox(g.c, kindFor(s), n, s);
    b.pseudo = true;
    const base = g.stack.items.len;
    if (s.content.len > 0) try push(g, .{ .tag = .generated, .text = s.content, .style = s });
    try finish(g, b, base);
}

/// The stack from `base` is `b`'s content: gives it to `b`, and leaves in its
/// place what `b`'s parent should hold.
fn finish(g: *Gen, b: *Box, base: usize) Error!void {
    const c = g.c;
    const entries = try c.arena.dupe(Entry, g.stack.items[base..]);
    g.stack.items.len = base;
    switch (b.kind) {
        .inline_box => return inlineBox(g, b, entries),
        .flex, .grid => try itemsContainer(g, b, entries),
        .table => try gen_table.fixTable(g, b, entries),
        .table_row_group => try gen_table.fixGroup(g, b, entries),
        .table_row => try gen_table.fixRow(g, b, entries),
        else => try container(g, b, entries),
    }
    try push(g, .{ .tag = .box, .box = b, .style = b.style });
}

pub fn isOutOfFlowEntry(e: Entry) bool {
    if (e.tag != .box) return false;
    return e.box.?.style.isOutOfFlow() or e.box.?.style.float != .none;
}

pub fn isBlockLevel(e: Entry) bool {
    if (e.tag != .box or isOutOfFlowEntry(e)) return false;
    return !e.box.?.style.isInlineLevel();
}

/// Text that collapses to nothing beside a block.
pub fn isWhitespace(e: Entry) bool {
    if (e.tag != .text and e.tag != .generated) return false;
    const ws = (e.style orelse return false).white_space;
    if (ws == .pre or ws == .pre_wrap) return false;
    for (e.text) |ch| {
        if (ch == '\n' and ws == .pre_line) return false;
        if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r' and ch != 0x0c) return false;
    }
    return true;
}

fn adopt(b: *Box, e: Entry) void {
    if (e.tag == .box) b.append(e.box.?);
}

/// An inline box. With blocks inside it splits, and its parent gets the
/// parts and the blocks in turn.
fn inlineBox(g: *Gen, b: *Box, entries: []const Entry) Error!void {
    var any_block = false;
    for (entries) |e| any_block = any_block or isBlockLevel(e);
    if (!any_block) {
        for (entries) |e| adopt(b, e);
        b.lay.entries = entries;
        return push(g, .{ .tag = .box, .box = b, .style = b.style });
    }
    var part = b;
    var from: usize = 0;
    var first_of_node: ?*Box = null;
    const flush = struct {
        fn run(gg: *Gen, p: *Box, slice: []const Entry) Error!bool {
            var content = false;
            for (slice) |e| content = content or !isWhitespace(e);
            if (!content) return false;
            for (slice) |e| adopt(p, e);
            p.lay.entries = slice;
            try push(gg, .{ .tag = .box, .box = p, .style = p.style });
            return true;
        }
    };
    for (entries, 0..) |e, i| {
        if (!isBlockLevel(e)) continue;
        if (try flush.run(g, part, entries[from..i])) {
            if (first_of_node == null) first_of_node = part;
            part = try newBox(g.c, .inline_box, b.node, b.style);
            part.pseudo = b.pseudo;
        }
        if (first_of_node == null) first_of_node = e.box.?;
        try push(g, e);
        from = i + 1;
    }
    _ = try flush.run(g, part, entries[from..]);
    if (b.node) |n| if (!b.pseudo) {
        n.box = first_of_node;
    };
}

/// A block container: either all lines, or all blocks with anonymous blocks
/// around the runs of inline content between them.
pub fn container(g: *Gen, b: *Box, entries0: []const Entry) Error!void {
    const entries = try gen_table.wrapOrphans(g, b, entries0);
    var any_block = false;
    for (entries) |e| any_block = any_block or isBlockLevel(e);
    if (!any_block) return inlineRoot(g, b, entries);
    var from: usize = 0;
    for (entries, 0..) |e, i| {
        if (!isBlockLevel(e)) continue;
        try inlineRun(g, b, entries[from..i]);
        b.append(e.box.?);
        from = i + 1;
    }
    try inlineRun(g, b, entries[from..]);
}

fn inlineRoot(g: *Gen, b: *Box, entries: []const Entry) Error!void {
    for (entries) |e| adopt(b, e);
    b.lay.inline_root = true;
    b.lay.entries = entries;
    if (b.style.text_align == .start) b.lay.text_align = g.text_align;
    b.lay.nowrap = g.nowrap;
    try text.build(g.c, b);
}

fn inlineRun(g: *Gen, b: *Box, run: []const Entry) Error!void {
    if (run.len == 0) return;
    var content = false;
    for (run) |e| content = content or !(isWhitespace(e) or isOutOfFlowEntry(e));
    if (!content) {
        for (run) |e| adopt(b, e);
        return;
    }
    const anon = try newBox(g.c, .block, null, try g.c.anonStyle(b.style, .block));
    b.append(anon);
    try inlineRoot(g, anon, run);
}

/// A flex or grid container: every box is an item, and a run of text an
/// anonymous one.
fn itemsContainer(g: *Gen, b: *Box, entries0: []const Entry) Error!void {
    const entries = try gen_table.wrapOrphans(g, b, entries0);
    var from: usize = 0;
    for (entries, 0..) |e, i| {
        if (e.tag != .box or e.box.?.kind == .inline_box) continue;
        try itemRun(g, b, entries[from..i]);
        b.append(e.box.?);
        from = i + 1;
    }
    try itemRun(g, b, entries[from..]);
}

fn itemRun(g: *Gen, b: *Box, run: []const Entry) Error!void {
    var content = false;
    for (run) |e| content = content or !(isWhitespace(e) or e.tag == .br or e.tag == .wbr);
    if (!content) return;
    const anon = try newBox(g.c, .block, null, try g.c.anonStyle(b.style, .block));
    b.append(anon);
    try inlineRoot(g, anon, run);
}
