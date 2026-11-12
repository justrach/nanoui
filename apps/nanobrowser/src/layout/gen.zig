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
const counters = @import("counters.zig");
const cache = @import("cache.zig");
const perf = @import("../perf_rules.zig");
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
    /// The style a top-layer element is laid out with, and that element.
    top_style: ?*const Style = null,
    in_top: ?*dom.Node = null,
    /// `align` and `nowrap` on the way down.
    text_align: ?css.TextAlign = null,
    nowrap: bool = false,
    counters: counters.Counters = .{},
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
    // The top layer: above everything, sized against the viewport, whatever holds it.
    for (doc.top_layer.items) |n| try topLayer(&g, n);
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

/// An element of the top layer, its `::backdrop` under it, as if it were the root's
/// child.
fn topLayer(g: *Gen, n: *dom.Node) Error!void {
    const s0 = n.computed orelse return;
    if (s0.display == .none) return;
    const c = g.c;
    const backdrop = try c.arena.create(Style);
    backdrop.* = if (n.backdrop) |b| b.* else .{ .background = .{ .r = 0, .g = 0, .b = 0, .a = 0.1 } };
    backdrop.display = .block;
    backdrop.position = .fixed;
    backdrop.top = css.Len.zero;
    backdrop.left = css.Len.zero;
    backdrop.right = css.Len.zero;
    backdrop.bottom = css.Len.zero;
    backdrop.z_index = std.math.maxInt(i32);
    if (n.isTag("dialog")) {
        const b = try newBox(c, .block, n, backdrop);
        b.pseudo = true;
        b.lay.inline_root = true;
        try push(g, .{ .tag = .box, .box = b, .style = backdrop });
    }
    const on_top = try c.arena.create(Style);
    on_top.* = s0.*;
    on_top.z_index = std.math.maxInt(i32);
    // The rule makes it so; a page's own `position` on a popover stands.
    if (on_top.position == .static or on_top.position == .relative) on_top.position = .absolute;
    on_top.display = @import("../css/compute.zig").blockified(on_top.display);
    g.top_style = on_top;
    g.in_top = n;
    defer g.in_top = null;
    try element(g, n);
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

pub const HtmlTag = perf.HtmlTag;

fn inputType(n: *const dom.Node) []const u8 {
    return n.attr("type") orelse "text";
}

fn isButtonInputType(t: []const u8) bool {
    return std.ascii.eqlIgnoreCase(t, "submit") or std.ascii.eqlIgnoreCase(t, "button") or std.ascii.eqlIgnoreCase(t, "reset");
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

pub fn element(g: *Gen, n: *dom.Node) Error!void {
    if (g.depth >= max_depth) return;
    const s_in = n.computed orelse return;
    if (s_in.display == .none) return;
    // In the top layer it shows there and not here.
    var s0 = s_in;
    if (n.in_top_layer) {
        if (g.in_top != n) return;
        s0 = g.top_style.?;
    } else if (try cache.tryAdopt(g, n)) {
        return;
    }
    const htag: HtmlTag = n.html_tag;
    var is_btn_input = false;
    if (htag == .br) return push(g, .{ .tag = .br, .style = s0 });
    if (htag == .wbr) return push(g, .{ .tag = .wbr });
    if (htag == .input) {
        const it = inputType(n);
        if (std.ascii.eqlIgnoreCase(it, "hidden")) return;
        is_btn_input = isButtonInputType(it);
    }
    if (s0.display == .table_column or s0.display == .table_column_group) return;
    g.depth += 1;
    defer g.depth -= 1;
    if (s0.counter_reset.len != 0 or s0.counter_increment.len != 0 or s0.counter_set.len != 0) {
        try g.counters.apply(g.c.arena, s0, g.depth);
    }
    defer if (g.counters.entries.items.len != 0) g.counters.leave(g.depth);
    if (s0.display == .contents) {
        try pseudo(g, n, n.before);
        try children(g, n, s0, htag);
        try pseudo(g, n, n.after);
        return;
    }
    const saved_align = g.text_align;
    const saved_nowrap = g.nowrap;
    const is_list = (htag == .list);
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
    const s = try hints.apply(g.c, n, s0, htag);
    hints.descend(g, n, htag);

    const is_replaced = if (n.ns == .svg) n.isTag("svg") else (htag == .img or htag == .replaced);
    if (is_replaced) {
        if (htag == .img) if (brokenAlt(g.c, n)) |alt| return altBox(g, n, s, alt);
        const b = try newBox(g.c, .replaced, n, try atomStyle(g.c, s));
        b.lay.in_text_align = saved_align;
        b.lay.in_nowrap = saved_nowrap;
        b.lay.cached_style = s_in;
        n.setBox(b);
        return push(g, .{ .tag = .box, .box = b, .style = b.style });
    }
    if (htag == .control or (htag == .input and !is_btn_input)) {
        const b = try newBox(g.c, .control, n, try atomStyle(g.c, s));
        b.lay.in_text_align = saved_align;
        b.lay.in_nowrap = saved_nowrap;
        b.lay.cached_style = s_in;
        n.setBox(b);
        return push(g, .{ .tag = .box, .box = b, .style = b.style });
    }
    const is_button = (htag == .button or is_btn_input);
    const st = if (is_button) try atomStyle(g.c, s) else s;
    const b = try newBox(g.c, kindFor(st), n, st);
    b.lay.in_text_align = saved_align;
    b.lay.in_nowrap = saved_nowrap;
    b.lay.cached_style = s_in;
    n.setBox(b);
    if (hints.isContentHidden(n, st)) {
        // `content-visibility: hidden`, `hidden=until-found`: a box with nothing shown.
        try finish(g, b, g.stack.items.len);
        return;
    }
    if (is_button) {
        b.lay.shrink = true;
        b.lay.center_v = true;
        if (st.text_align == .start) g.text_align = .center;
    }
    const base = g.stack.items.len;
    if (st.display == .list_item) try marker(g, b, n, st);
    try pseudo(g, n, n.before);
    if (is_btn_input) {
        const v = n.value orelse n.attr("value") orelse buttonDefault(n);
        if (v.len > 0) try push(g, .{ .tag = .generated, .text = v, .style = st });
    } else try children(g, n, st, htag);
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
    n.setBox(b);
    const base = g.stack.items.len;
    try push(g, .{ .tag = .generated, .text = alt, .style = s });
    try finish(g, b, base);
}

fn marker(g: *Gen, b: *Box, n: *dom.Node, s: *const Style) Error!void {
    if (n.ns == .html) if (n.attr("value")) |raw_v| {
        const v = std.mem.trim(u8, raw_v, " \t\r\n");
        g.counter = std.fmt.parseInt(i64, v, 10) catch g.counter;
    };
    const value = g.counter;
    const a = g.c.arena;
    // `counter(list-item)` reads what the item's number is.
    try g.counters.set(a, "list-item", @intCast(std.math.clamp(value, -1000000000, 1000000000)), g.depth);
    g.counter += g.counter_step;
    if (s.list_style == .none and s.list_style_text == null and n.marker == null) return;
    // The list's counter is what the item changes: it survives the item.
    var text_str = try list.counterText(a, s.list_style, value);
    const ms = n.marker;
    if (ms) |m| {
        if (m.marker_hidden) return;
        if (m.content_parts.len > 0) {
            text_str = try g.counters.contentText(a, m.content_parts);
            b.lay.marker_no_gap = true;
        } else if (m.content.len > 0) {
            text_str = m.content;
            b.lay.marker_no_gap = true;
        }
        b.lay.marker_style = m;
    }
    if (s.list_style_text) |t| if (!b.lay.marker_no_gap) {
        text_str = t;
        b.lay.marker_no_gap = true;
    };
    if (s.list_style == .none and !b.lay.marker_no_gap) return;
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

fn children(g: *Gen, n: *dom.Node, s: *const Style, htag: HtmlTag) Error!void {
    // A shadow host renders its shadow tree; its own children go by its slots.
    if (n.shadow_root) |root| return element(g, root);
    if (htag == .details and !n.hasAttr("open")) return closedDetails(g, n, s);
    if (!n.is_shadow and (htag == .slot or (n.ns != .html and n.isTag("slot")))) if (shadowHostOf(n)) |host| {
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

/// A closed `<details>` shows its first `<summary>` and nothing else, whatever
/// `display` the rest has.
fn closedDetails(g: *Gen, n: *dom.Node, s: *const Style) Error!void {
    var k = n.first_child;
    while (k) |x| : (k = x.next) if (x.isTag("summary")) return element(g, x);
    _ = s;
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
    try g.counters.apply(g.c.arena, s, g.depth + 1);
    const words = if (s.content_parts.len > 0) try g.counters.contentText(g.c.arena, s.content_parts) else s.content;
    if (words.len > 0) try push(g, .{ .tag = .generated, .text = words, .style = s });
    try finish(g, b, base);
}

/// The stack from `base` is `b`'s content: gives it to `b`, and leaves in its
/// place what `b`'s parent should hold.
fn finish(g: *Gen, b: *Box, base: usize) Error!void {
    const c = g.c;
    const slice = g.stack.items[base..];
    if (b.kind == .inline_box) {
        const entries: []const Entry = if (slice.len == 0) &.{} else try c.arena.dupe(Entry, slice);
        g.stack.items.len = base;
        return inlineBox(g, b, entries);
    }
    switch (b.kind) {
        .flex, .grid => try itemsContainer(g, b, slice),
        .table => try gen_table.fixTable(g, b, slice),
        .table_row_group => try gen_table.fixGroup(g, b, slice),
        .table_row => try gen_table.fixRow(g, b, slice),
        else => try container(g, b, slice),
    }
    g.stack.items.len = base;
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
        n.setBox(first_of_node);
        try partsOf(g, n, entries);
    };
}

/// What a split inline's rect is the union of: the blocks in it, as the line
/// boxes they stand in fill their containers.
fn partsOf(g: *Gen, n: *dom.Node, entries: []const Entry) Error!void {
    var parts: std.ArrayList(*anyopaque) = .empty;
    for (entries) |e| if (isBlockLevel(e)) try parts.append(g.c.arena, e.box.?);
    n.box_parts = parts.items;
}

/// A block container: either all lines, or all blocks with anonymous blocks
/// around the runs of inline content between them.
pub fn container(g: *Gen, b: *Box, entries0: []const Entry) Error!void {
    if (entries0.len == 0) {
        b.lay.inline_root = true;
        if (b.style.text_align == .start) b.lay.text_align = g.text_align;
        b.lay.nowrap = g.nowrap;
        return;
    }
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
    const stored: []const Entry = if (entries.len == 0) &.{} else try g.c.arena.dupe(Entry, entries);
    b.lay.entries = stored;
    if (b.style.text_align == .start) b.lay.text_align = g.text_align;
    b.lay.nowrap = g.nowrap;
    if (stored.len > 0) try text.build(g.c, b);
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

/// Rebuilds the children and inline pieces of an adopted box `b` when its size changes.
pub fn rebuildAdoptedContents(c: *Ctx, b: *Box) Error!void {
    const n = b.node orelse return;
    if (b.kind == .control or b.kind == .replaced) return;
    var g: Gen = .{ .c = c, .text_align = b.lay.in_text_align, .nowrap = b.lay.in_nowrap };
    const htag: HtmlTag = n.html_tag;
    hints.descend(&g, n, htag);
    const st = b.style;
    if (hints.isContentHidden(n, st)) {
        try finish(&g, b, 0);
        return;
    }
    const is_btn_input = (htag == .input and isButtonInputType(inputType(n)));
    const is_button = (htag == .button or is_btn_input);
    if (is_button and st.text_align == .start) g.text_align = .center;
    try pseudo(&g, n, n.before);
    if (is_btn_input) {
        const v = n.value orelse n.attr("value") orelse buttonDefault(n);
        if (v.len > 0) try push(&g, .{ .tag = .generated, .text = v, .style = st });
    } else try children(&g, n, st, htag);
    try pseudo(&g, n, n.after);
    try finish(&g, b, 0);
}
