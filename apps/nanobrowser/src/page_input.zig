//! What the pointer does on a page: hover and `:hover`, the cursor, the events
//! scripts hear, and what a click does when no script stopped it: links,
//! labels, checkboxes, `<details>`, forms.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const dom = @import("dom.zig");
const css = @import("css/css.zig");
const loader = @import("loader.zig");
const web = @import("web/web.zig");
const view = @import("page_view.zig");
const Page = @import("page.zig").Page;

/// Called each frame with the element under the pointer.
pub fn pointer(p: *Page, c: *ui.Context, it: ui.Interaction, under: ?*dom.Node, x: f32, y: f32, inside: bool) void {
    const moved = x != p.pointer[0] or y != p.pointer[1];
    p.pointer = .{ x, y };
    const old = p.doc.hover;
    // A page moving under a still pointer isn't the person pointing at anything:
    // as in other browsers, hover waits for it to stop. Else each frame of a
    // scroll restyles what passes under the pointer.
    const held = inside and p.hover_held_until > c.time and !moved and !c.input.pressed and !c.input.released and !c.input.secondary;
    if (held) c.frameIn(@floatCast(@max(p.hover_held_until - c.time, 0.001)));
    const node = if (held) old else under;
    if (node != old and inside) {
        setState(p, &p.doc.hover, node);
        web.pointerMoved(p, old, node, x, y);
    } else if (moved and inside) web.pointerMoved(p, node, node, x, y);
    if (inside) c.cursor = cursorOf(node);
    if (it.hovered and c.input.pressed) {
        p.last_press = node;
        setState(p, &p.doc.active, node);
        web.lightDismiss(p, node);
        if (p.dead) return;
        if (node) |n| {
            const prevented = web.mouseEvent(p, n, "mousedown", x, y, modifiers(c));
            if (p.dead) return;
            if (!prevented) {
                const was = p.doc.focus;
                const target = focusTarget(n);
                if (target != was) {
                    setState(p, &p.doc.focus, target);
                    p.field_pressed = target;
                    web.focusChanged(p, was, target);
                    if (p.dead) return;
                }
            }
        }
    }
    if (c.input.secondary and it.hovered) if (node) |n| {
        _ = web.mouseEvent(p, n, "contextmenu", x, y, modifiers(c));
        if (p.dead) return;
    };
    if (c.input.released) {
        setState(p, &p.doc.active, null);
        if (it.hovered) if (node) |n| {
            _ = web.mouseEvent(p, n, "mouseup", x, y, modifiers(c));
        };
    }
    if (it.clicked) if (node) |n| if (p.last_press == n) click(p, c, n, x, y);
}

const Mods = web.Modifiers;

fn modifiers(c: *const ui.Context) Mods {
    return .{ .ctrl = c.input.ctrl, .shift = c.input.shift, .alt = c.input.alt, .meta = c.input.cmd };
}

/// A state `:hover`, `:active` or `:focus` reads: what it changes is restyled.
fn setState(p: *Page, slot: *?*dom.Node, to: ?*dom.Node) void {
    const old = slot.*;
    if (old == to) return;
    slot.* = to;
    // The UA's own `:focus` and `:active` rules aren't counted as sensitive.
    const always = slot == &p.doc.focus or slot == &p.doc.active;
    if (!always and !p.engine.hoverSensitive()) return;
    for ([_]?*dom.Node{ old, to }) |maybe| {
        const n = maybe orelse continue;
        const flip: css.Flip = if (slot == &p.doc.focus) .focus else if (slot == &p.doc.active) .active else .hover;
        const top = p.engine.invalidatedByState(n, flip) orelse if (always) n else continue;
        const change = p.engine.restyleSubtree(top) catch continue;
        switch (change) {
            .none => {},
            // Boxes hold the very styles that changed.
            .paint => p.list_dirty = true,
            .layout => p.doc.touchLayout(),
        }
    }
}

fn cursorOf(node: ?*dom.Node) ui.Cursor {
    var at = node;
    while (at) |n| : (at = n.parentElement()) {
        if (n.computed) |st| switch (st.cursor) {
            .pointer => return .hand,
            .text => return .text,
            .default => return .arrow,
            .not_allowed => return .not_allowed,
            .grab => return .open_hand,
            .col_resize => return .resize_left_right,
            .row_resize => return .resize_up_down,
            .auto => {},
        };
        if (n.isTag("a") and n.hasAttr("href")) return .hand;
        if (n.isTag("button") or n.isTag("summary") or n.isTag("select")) return .hand;
    }
    return .arrow;
}

/// What a press at `n` gives the focus to: it or a focusable ancestor.
fn focusTarget(n: *dom.Node) ?*dom.Node {
    var at: ?*dom.Node = n;
    while (at) |x| : (at = x.parentElement()) if (isFocusable(x)) return x;
    return null;
}

fn isFocusable(n: *const dom.Node) bool {
    if (n.computed) |st| if (st.inert) return false;
    return n.isTag("a") or n.isTag("button") or n.isTag("input") or n.isTag("select") or n.isTag("textarea") or n.hasAttr("tabindex");
}

fn click(p: *Page, c: *ui.Context, node: *dom.Node, x: f32, y: f32) void {
    const m = modifiers(c);
    if (web.mouseEvent(p, node, "click", x, y, m)) return;
    if (p.dead) return;
    if (c.input.click_count == 2) {
        _ = web.mouseEvent(p, node, "dblclick", x, y, m);
        if (p.dead) return;
    }
    activate(p, node, x, y, m, c.input.cmd or c.input.ctrl);
}

/// What a click does when no script stopped it: from a person, or `el.click()`.
pub fn activate(p: *Page, node: *dom.Node, x: f32, y: f32, m: web.Modifiers, new_tab: bool) void {
    var at: ?*dom.Node = node;
    while (at) |n| : (at = n.parentElement()) {
        if (n.isTag("a")) if (n.attr("href")) |href| return follow(p, new_tab, n, href);
        if (n.isTag("area")) if (n.attr("href")) |href| return follow(p, new_tab, n, href);
        if (n.isTag("label")) return labelClick(p, m, n, x, y);
        if (n.isTag("input")) return inputClick(p, n);
        if (n.isTag("button")) return buttonClick(p, n);
        if (n.isTag("summary")) if (n.parentElement()) |d| if (d.isTag("details")) {
            if (d.hasAttr("open")) d.removeAttr("open") else d.setAttr("open", "") catch {};
            web.detailsToggled(p, d);
            return;
        };
        if (n.isTag("select")) {
            p.open_select = if (p.open_select == n) null else n;
            return;
        }
    }
    p.open_select = null;
}

fn follow(p: *Page, new_tab: bool, a: *dom.Node, href: []const u8) void {
    if (href.len > 0 and href[0] == '#') {
        if (href.len > 1 and !new_tab) if (loader.linkFrom(p, href)) |to| web.hashNavigated(p, to);
        return fragment(p, href[1..]);
    }
    if (std.ascii.startsWithIgnoreCase(href, "javascript:")) {
        web.runUrl(p, href["javascript:".len..]);
        return;
    }
    const to = loader.linkFrom(p, href) orelse return;
    // The same page but for its fragment: no load.
    if (samePage(to, p.url())) if (std.mem.indexOfScalar(u8, to, '#')) |i| {
        web.hashNavigated(p, to);
        return fragment(p, to[i + 1 ..]);
    };
    const target = a.attr("target") orelse "";
    const blank = std.mem.eql(u8, target, "_blank");
    if (!blank and !new_tab and target.len > 0 and followTarget(p, target, to)) return;
    p.navigate(.{ .url = to, .new_tab = blank or new_tab });
}

/// `target=_top`, `_parent`, or a frame's name: true when it went there.
fn followTarget(p: *Page, target: []const u8, to: []const u8) bool {
    const frames = @import("frames.zig");
    if (std.ascii.eqlIgnoreCase(target, "_self")) return false;
    if (std.ascii.eqlIgnoreCase(target, "_top")) {
        const top = frames.topOf(p);
        top.navigate(.{ .url = to });
        return true;
    }
    if (std.ascii.eqlIgnoreCase(target, "_parent")) {
        const f = p.frame orelse return false;
        if (f.owner.frame) |up| frames.navigateTo(up, to, .{}) else f.owner.navigate(.{ .url = to });
        return true;
    }
    const f = frames.named(frames.topOf(p), target) orelse return false;
    frames.navigateTo(f, to, .{});
    return true;
}

fn samePage(a: []const u8, b: []const u8) bool {
    const x = a[0 .. std.mem.indexOfScalar(u8, a, '#') orelse a.len];
    const y = b[0 .. std.mem.indexOfScalar(u8, b, '#') orelse b.len];
    return std.mem.eql(u8, x, y);
}

/// Scrolls to the element a fragment names.
pub fn fragment(p: *Page, name: []const u8) void {
    if (name.len == 0 or std.mem.eql(u8, name, "top")) return view.scrollPageTo(p, 0);
    const target = p.doc.getElementById(name) orelse named(p, name) orelse return;
    // A section `hidden=until-found` shows itself to be gone to.
    var at: ?*dom.Node = target;
    var revealed = false;
    while (at) |x| : (at = x.parent) {
        if (x.attr("hidden")) |v| if (std.ascii.eqlIgnoreCase(v, "until-found")) {
            web.simpleEvent(p, x, "beforematch");
            x.removeAttr("hidden");
            revealed = true;
        };
    }
    if (revealed) web.layoutNow(p);
    const rect = @import("layout/layout.zig").rectOf(target) orelse return;
    // `scroll-margin-top` on it and `scroll-padding-top` on what scrolls.
    const margin = if (target.computed) |st| st.scroll_margin_top else 0;
    const padding = if (p.doc.documentElement()) |root| if (root.computed) |st| st.scroll_padding_top else 0 else 0;
    view.scrollPageTo(p, rect.y - margin - padding);
}

fn named(p: *Page, name: []const u8) ?*dom.Node {
    var at = p.doc.node.first_child;
    while (at) |n| : (at = n.nextInTree(p.doc.node)) {
        if (n.isTag("a")) if (n.attr("name")) |v| if (std.mem.eql(u8, v, name)) return n;
    }
    return null;
}

fn labelClick(p: *Page, m: web.Modifiers, label: *dom.Node, x: f32, y: f32) void {
    const target = if (label.attr("for")) |id| p.doc.getElementById(id) else firstControl(label);
    const n = target orelse return;
    if (web.mouseEvent(p, n, "click", x, y, m)) return;
    if (n.isTag("input")) inputClick(p, n);
}

fn firstControl(root: *dom.Node) ?*dom.Node {
    var at = root.first_child;
    while (at) |n| : (at = n.nextInTree(root)) {
        if (n.isTag("input") or n.isTag("select") or n.isTag("textarea") or n.isTag("button")) return n;
    }
    return null;
}

fn inputClick(p: *Page, n: *dom.Node) void {
    if (n.hasAttr("disabled")) return;
    const kind = n.attr("type") orelse "text";
    if (std.ascii.eqlIgnoreCase(kind, "checkbox")) {
        n.checked = !isChecked(n);
        changed(p, n);
    } else if (std.ascii.eqlIgnoreCase(kind, "radio")) {
        if (formOf(n)) |form| uncheckGroup(form, n) else uncheckGroup(p.doc.node, n);
        n.checked = true;
        changed(p, n);
    } else if (std.ascii.eqlIgnoreCase(kind, "submit") or std.ascii.eqlIgnoreCase(kind, "image")) {
        if (formOf(n)) |form| submit(p, form, n);
    } else if (std.ascii.eqlIgnoreCase(kind, "reset")) {
        if (formOf(n)) |form| reset(p, form);
    }
}

fn changed(p: *Page, n: *dom.Node) void {
    p.doc.touchStyle();
    web.simpleEvent(p, n, "input");
    web.simpleEvent(p, n, "change");
}

pub fn isChecked(n: *const dom.Node) bool {
    return n.checked orelse n.hasAttr("checked");
}

pub fn uncheckGroup(root: *dom.Node, n: *dom.Node) void {
    const name = n.attr("name") orelse return;
    var at = root.first_child;
    while (at) |x| : (at = x.nextInTree(root)) {
        if (!x.isTag("input") or x == n) continue;
        if (x.attr("name")) |v| if (std.mem.eql(u8, v, name)) {
            const kind = x.attr("type") orelse "";
            if (std.ascii.eqlIgnoreCase(kind, "radio")) x.checked = false;
        };
    }
}

fn buttonClick(p: *Page, n: *dom.Node) void {
    if (n.hasAttr("disabled")) return;
    if ((n.hasAttr("popovertarget") or n.hasAttr("commandfor")) and web.invoke(p, n)) return;
    const kind = n.attr("type") orelse "submit";
    const form = formOf(n) orelse return;
    if (std.ascii.eqlIgnoreCase(kind, "submit")) submit(p, form, n);
    if (std.ascii.eqlIgnoreCase(kind, "reset")) reset(p, form);
}

pub fn formOf(n: *dom.Node) ?*dom.Node {
    if (n.attr("form")) |id| return n.doc.getElementById(id);
    var at = n.parentElement();
    while (at) |f| : (at = f.parentElement()) if (f.isTag("form")) return f;
    return null;
}

pub fn reset(p: *Page, form: *dom.Node) void {
    var at = form.first_child;
    while (at) |x| : (at = x.nextInTree(form)) {
        x.value = null;
        x.checked = null;
        x.selected = null;
        if (x.editor) |e| {
            const buf: *ui.TextBuffer = @ptrCast(@alignCast(e));
            buf.set(x.attr("value") orelse "");
        }
    }
    p.doc.touchStyle();
}

/// Sends a form, `submitter` the button that did it, when scripts let it.
pub fn submit(p: *Page, form: *dom.Node, submitter: ?*dom.Node) void {
    if (web.deferSubmit(p, form, submitter)) return;
    if (web.submitEvent(p, form)) return;
    if (p.dead) return;
    sendForm(p, form, submitter);
}

/// Sends a form, no event asked: `form.submit()`.
pub fn sendForm(p: *Page, form: *dom.Node, submitter: ?*dom.Node) void {
    const a = p.arena();
    const body = encode(a, form, submitter) catch return;
    const action = form.attr("action") orelse "";
    const to = loader.linkFrom(p, if (action.len > 0) action else p.url()) orelse return;
    const method = form.attr("method") orelse "get";
    const blank = if (form.attr("target")) |t| std.mem.eql(u8, t, "_blank") else false;
    if (std.ascii.eqlIgnoreCase(method, "post")) {
        p.navigate(.{ .url = to, .post = true, .body = body, .new_tab = blank });
        return;
    }
    const cut = to[0 .. std.mem.indexOfAny(u8, to, "?#") orelse to.len];
    const full = std.fmt.allocPrint(a, "{s}?{s}", .{ cut, body }) catch return;
    p.navigate(.{ .url = full, .new_tab = blank });
}

/// What a form says, as `application/x-www-form-urlencoded`.
pub fn encode(a: std.mem.Allocator, form: *dom.Node, submitter: ?*dom.Node) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at = form.first_child;
    while (at) |n| : (at = n.nextInTree(form)) {
        if (n.kind != .element or n.hasAttr("disabled")) continue;
        const name = n.attr("name") orelse continue;
        if (name.len == 0) continue;
        if (n.isTag("input")) {
            const kind = n.attr("type") orelse "text";
            const is = struct {
                fn k(s: []const u8, w: []const u8) bool {
                    return std.ascii.eqlIgnoreCase(s, w);
                }
            }.k;
            if (is(kind, "checkbox") or is(kind, "radio")) {
                if (isChecked(n)) try pair(a, &out, name, n.attr("value") orelse "on");
            } else if (is(kind, "submit") or is(kind, "button") or is(kind, "reset") or is(kind, "image")) {
                if (n == submitter) try pair(a, &out, name, n.attr("value") orelse "");
            } else if (!is(kind, "file")) try pair(a, &out, name, n.value orelse n.attr("value") orelse "");
        } else if (n.isTag("textarea")) {
            try pair(a, &out, name, n.value orelse try n.textContent(a));
        } else if (n.isTag("select")) {
            if (selectedOption(n)) |o| try pair(a, &out, name, o.attr("value") orelse try o.textContent(a));
        } else if (n.isTag("button") and n == submitter) try pair(a, &out, name, n.attr("value") orelse "");
    }
    return out.items;
}

/// The option a `<select>` shows.
pub fn selectedOption(select: *dom.Node) ?*dom.Node {
    var first: ?*dom.Node = null;
    var marked: ?*dom.Node = null;
    var at = select.first_child;
    while (at) |n| : (at = n.nextInTree(select)) {
        if (!n.isTag("option")) continue;
        if (first == null) first = n;
        if (n.selected orelse n.hasAttr("selected")) marked = n;
    }
    return marked orelse first;
}

fn pair(a: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    if (out.items.len > 0) try out.append(a, '&');
    try escape(a, out, name);
    try out.append(a, '=');
    try escape(a, out, value);
}

fn escape(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '*' or ch == '-' or ch == '.' or ch == '_') {
            try out.append(a, ch);
        } else if (ch == ' ') {
            try out.append(a, '+');
        } else {
            const hex = "0123456789ABCDEF";
            try out.appendSlice(a, &.{ '%', hex[ch >> 4], hex[ch & 15] });
        }
    }
}

test "a form says what it holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try dom.Document.create(a);
    const form = try d.createElement("form");
    const add = struct {
        fn f(doc: *dom.Document, parent: *dom.Node, tag: []const u8, attrs: []const [2][]const u8) !*dom.Node {
            const n = try doc.createElement(tag);
            for (attrs) |kv| try n.setAttr(kv[0], kv[1]);
            parent.appendChild(n);
            return n;
        }
    }.f;
    const q = try add(d, form, "input", &.{.{ "name", "q" }});
    q.value = "a b&c";
    _ = try add(d, form, "input", &.{ .{ "name", "off" }, .{ "type", "checkbox" } });
    _ = try add(d, form, "input", &.{ .{ "name", "on" }, .{ "type", "checkbox" }, .{ "checked", "" } });
    _ = try add(d, form, "input", &.{ .{ "name", "gone" }, .{ "disabled", "" } });
    const go = try add(d, form, "input", &.{ .{ "name", "go" }, .{ "type", "submit" }, .{ "value", "Go" } });
    _ = try add(d, form, "input", &.{ .{ "name", "other" }, .{ "type", "submit" }, .{ "value", "No" } });
    const sel = try add(d, form, "select", &.{.{ "name", "s" }});
    _ = try add(d, sel, "option", &.{.{ "value", "1" }});
    _ = try add(d, sel, "option", &.{ .{ "value", "2" }, .{ "selected", "" } });
    try std.testing.expectEqualStrings("q=a+b%26c&on=on&go=Go&s=2", try encode(a, form, go));
}
