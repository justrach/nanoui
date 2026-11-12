//! Cascade tests: what an element's computed `Style` comes to from a page and
//! its sheets.
const std = @import("std");
const dom = @import("../dom.zig");
const html = @import("../html/html.zig");
const css = @import("css.zig");
const style = @import("style.zig");
const props = @import("tests_props.zig");

const expect = std.testing.expect;
const eq = std.testing.expectEqualStrings;
const gpa = std.testing.allocator;

test {
    _ = props;
}

/// A parsed page with one author sheet, styled.
pub const Page = struct {
    arena: std.heap.ArenaAllocator,
    doc: *dom.Document,
    engine: css.Engine,

    pub fn make(source: []const u8, sheet_text: []const u8, v: css.Viewport) !*Page {
        const p = try gpa.create(Page);
        errdefer gpa.destroy(p);
        p.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer p.arena.deinit();
        const a = p.arena.allocator();
        p.doc = try dom.Document.create(a);
        try html.parseDocument(p.doc, source);
        p.engine = css.Engine.init(gpa, p.doc);
        const sheet = try css.parseSheet(a, sheet_text, "https://x.test/s.css");
        p.engine.setSheets(&.{sheet});
        p.engine.setViewport(v);
        try p.engine.restyleAll();
        return p;
    }

    pub fn done(p: *Page) void {
        p.engine.deinit();
        p.arena.deinit();
        gpa.destroy(p);
    }

    pub fn el(p: *Page, id: []const u8) *dom.Node {
        return p.doc.getElementById(id).?;
    }

    pub fn s(p: *Page, id: []const u8) *const style.Style {
        return p.el(id).computed.?;
    }
};

const vp: css.Viewport = .{ .width = 1000, .height = 500 };

fn near(a: f32, b: f32) !void {
    if (@abs(a - b) > 0.01) {
        std.debug.print("got {d}, want {d}\n", .{ a, b });
        return error.TestUnexpectedResult;
    }
}

test "UA sheet: display and defaults" {
    const p = try Page.make("<!doctype html><title id=t>x</title><body id=b><div id=d></div><span id=s></span><ul id=u><li id=li></li></ul><table id=tb><tr id=tr><td id=td></td></tr></table><h1 id=h1></h1><p id=pp></p><pre id=pre></pre><a id=lnk href=x></a><b id=bold></b><input id=in><button id=btn></button><div hidden id=hid></div>", "", vp);
    defer p.done();
    try expect(p.s("d").display == .block);
    try expect(p.s("s").display == .inline_);
    try expect(p.s("li").display == .list_item);
    try expect(p.s("tb").display == .table);
    try expect(p.s("tr").display == .table_row);
    try expect(p.s("td").display == .table_cell);
    try expect(p.s("tb").border_spacing == 2);
    try near(p.s("b").margin_top.px, 8);
    try near(p.s("h1").font_size, 32);
    try expect(p.s("h1").font_weight == 700);
    try near(p.s("h1").margin_top.px, 32 * 0.67);
    try near(p.s("pp").margin_top.px, 16);
    try near(p.s("u").padding_left.px, 40);
    try expect(p.s("u").list_style == .disc);
    try expect(p.s("pre").mono and p.s("pre").white_space == .pre);
    try near(p.s("pre").font_size, 13);
    try expect(p.s("lnk").underline);
    try near(p.s("lnk").color.b, 238.0 / 255.0);
    try expect(p.s("bold").font_weight == 700);
    try expect(p.s("in").display == .inline_block);
    try expect(p.s("btn").box_sizing == .border_box);
    try expect(p.s("hid").display == .none);
    // The head is display none, and its children have no style.
    try expect(p.doc.head().?.computed.?.display == .none);
    try expect(p.el("t").computed == null);
}

test "cascade order: specificity, source order, important, inline, origin" {
    const p = try Page.make("<!doctype html><body><div id=a class=c></div><div id=b class=c style='width:1px'></div><div id=e class=c style='width:1px !important'></div><p id=pp></p>",
        \\div { width: 10px; height: 10px; }
        \\div { width: 20px; }
        \\.c { width: 30px; }
        \\#a { width: 40px; height: 5px !important; }
        \\#a { height: 6px; }
        \\.c { top: 1px !important; }
        \\#a { top: 2px; }
        \\#e { width: 2px !important; }
        \\p { margin-top: 3px; }
    , vp);
    defer p.done();
    try near(p.s("a").width.px, 40);
    try near(p.s("a").height.px, 5);
    try near(p.s("a").top.px, 1);
    try near(p.s("b").width.px, 1);
    try near(p.s("e").width.px, 1);
    try near(p.s("pp").margin_top.px, 3);
}

test "cascade layers" {
    const p = try Page.make("<!doctype html><body><div id=a class=c></div><div id=b></div>",
        \\@layer base, theme;
        \\@layer theme { .c { width: 2px; height: 2px !important; } }
        \\@layer base { #a { width: 1px; height: 1px !important; } }
        \\#b { width: 9px; }
        \\@layer base { #b { width: 1px; } }
    , vp);
    defer p.done();
    // A later layer beats an earlier one regardless of specificity.
    try near(p.s("a").width.px, 2);
    // For !important the order turns over.
    try near(p.s("a").height.px, 1);
    // Unlayered beats layered.
    try near(p.s("b").width.px, 9);
}

test "inherit, initial, unset, revert, all" {
    const p = try Page.make("<!doctype html><body><div id=o><div id=a></div><div id=b></div><div id=c></div><p id=r></p><span id=all></span><div id=allr></div><b id=rb></b></div>",
        \\#o { color: red; width: 10px; font-size: 20px; }
        \\#a { width: inherit; color: green; }
        \\#b { color: initial; display: initial; }
        \\#c { color: unset; width: unset; }
        \\p { margin-top: 5px; display: inline; }
        \\#r { margin-top: revert; display: revert; }
        \\#all { all: unset; }
        \\#allr { all: revert; }
        \\b { font-weight: 100; }
        \\#rb { font-weight: revert; }
    , vp);
    defer p.done();
    try near(p.s("a").width.px, 10);
    try near(p.s("a").color.g, 128.0 / 255.0);
    try near(p.s("b").color.r, 0);
    try expect(p.s("b").display == .inline_);
    try near(p.s("c").color.r, 1);
    try expect(p.s("c").width.kind == .auto);
    try near(p.s("r").margin_top.px, 20);
    try expect(p.s("r").display == .block);
    try expect(p.s("all").display == .inline_);
    try near(p.s("all").font_size, 20);
    try expect(p.s("allr").display == .block);
    try expect(p.s("rb").font_weight == 700);
}

test "var(): fallback, inheritance, cycles, invalid at computed time" {
    const p = try Page.make("<!doctype html><body id=b><div id=a><div id=k></div><div id=f></div><div id=cy></div><div id=bad></div><div id=chain></div><div id=shadow><i id=si></i></div><div id=ini></div><div id=emp></div></div>",
        \\:root { --w: 10px; --c: blue; --empty:; }
        \\#a { --x: 5px; --sum: calc(var(--w) + var(--x)); }
        \\#k { width: var(--w); height: var(--sum); color: var(--c); }
        \\#f { width: var(--nope, 7px); height: var(--nope, var(--also-nope, 8px)); }
        \\#cy { --p: var(--q); --q: var(--p); --r: var(--r, 1px); --s: var(--p, 3px); width: var(--p, 4px); height: var(--r, 5px); top: var(--s); }
        \\#bad { color: red; color: var(--nope); width: 5px; width: var(--c); }
        \\#chain { --a: 3; --b: calc(var(--a) * 2px); width: var(--b); }
        \\#shadow { --w: 99px; }
        \\#si { width: var(--w); }
        \\#ini { --w: initial; width: var(--w, 6px); }
        \\#emp { margin: var(--empty) 1px; }
    , vp);
    defer p.done();
    try near(p.s("k").width.px, 10);
    try near(p.s("k").height.px, 15);
    try near(p.s("k").color.b, 1);
    try near(p.s("f").width.px, 7);
    try near(p.s("f").height.px, 8);
    try near(p.s("cy").width.px, 4);
    try near(p.s("cy").height.px, 5);
    try expect(p.s("cy").top.kind == .auto or p.s("cy").top.px == 3);
    // Invalid at computed time is unset: inherited color, initial width.
    try near(p.s("bad").color.r, 0);
    try expect(p.s("bad").width.kind == .auto);
    try near(p.s("chain").width.px, 6);
    try near(p.s("si").width.px, 99);
    try near(p.s("ini").width.px, 6);
    try near(p.s("emp").margin_top.px, 1);
    try eq("10px", p.engine.computedValue(p.el("k"), "--w").?);
    try expect(p.engine.computedValue(p.el("k"), "--nope") == null);
}

test "nesting and media apply" {
    const p = try Page.make("<!doctype html><body><div id=a class=x><span id=s></span><b id=bb></b></div><div id=y class=x></div><i id=q></i>",
        \\.x { width: 1px; & span { width: 2px; } > b { width: 3px; } &#y { width: 4px; } 
        \\   @media (min-width: 500px) { height: 5px; & > span { height: 6px; } }
        \\   @media (min-width: 5000px) { top: 5px; }
        \\}
        \\@media (max-width: 500px) { #q { width: 1px; } }
        \\@media (min-width: 500px) and (max-height: 500px) { #q { height: 2px; } }
    , vp);
    defer p.done();
    try near(p.s("a").width.px, 1);
    try near(p.s("s").width.px, 2);
    try near(p.s("bb").width.px, 3);
    try near(p.s("y").width.px, 4);
    try near(p.s("a").height.px, 5);
    try near(p.s("s").height.px, 6);
    try expect(p.s("a").top.kind == .auto);
    try expect(p.s("q").width.kind == .auto);
    try near(p.s("q").height.px, 2);
    // A viewport change flips the media queries.
    p.engine.setViewport(.{ .width = 400, .height = 500 });
    try p.engine.restyleAll();
    try near(p.s("q").width.px, 1);
    try expect(p.s("q").height.kind == .auto);
    try expect(p.s("a").height.kind == .auto);
}

test "pseudo elements" {
    const p = try Page.make("<!doctype html><body><div id=a data-t=hi></div><div id=b></div><div id=c class=flex></div><q id=qq></q><div id=none></div>",
        \\#a::before { content: "x" attr(data-t) "\41"; color: red; }
        \\#a::after { content: ""; display: block; width: 5px; }
        \\#b::before { color: red; }
        \\.flex { display: flex; }
        \\.flex::before { content: "f"; }
        \\#none::after { content: "n"; display: none; }
    , vp);
    defer p.done();
    const a = p.el("a");
    try eq("xhiA", a.before.?.content);
    try near(a.before.?.color.r, 1);
    try expect(a.after != null);
    try eq("", a.after.?.content);
    try expect(a.after.?.display == .block);
    try expect(p.el("b").before == null);
    try expect(p.el("c").before.?.display == .block);
    try eq("\u{201C}", p.el("qq").before.?.content);
    try expect(p.el("none").after == null);
}

test "display fix-ups" {
    const p = try Page.make("<!doctype html><body><span id=fl style='float:left'></span><span id=ab style='position:absolute;float:right'></span><div style='display:flex'><span id=k></span><span style='display:contents'><span id=kc></span></span><a id=kt style='display:inline-table'></a><i id=ki style='display:inline-flex'></i></div><div style='display:grid'><span id=g></span></div><table id=tt style='float:left'></table><td id=stray></td>", "", vp);
    defer p.done();
    try expect(p.s("fl").display == .block);
    try expect(p.s("ab").display == .block);
    try expect(p.s("ab").float == .none);
    try expect(p.s("k").display == .block);
    try expect(p.s("kc").display == .block);
    try expect(p.s("kt").display == .table);
    try expect(p.s("ki").display == .flex);
    try expect(p.s("g").display == .block);
    try expect(p.s("tt").display == .table);
    const r = p.doc.documentElement().?.computed.?;
    try expect(r.display == .block);
}

test "display none: descendants have no style" {
    const p = try Page.make("<!doctype html><body><div id=a style='display:none'><span id=b>t</span></div>", "", vp);
    defer p.done();
    try expect(p.s("a").display == .none);
    try expect(p.el("b").computed == null);
    try expect(p.el("b").first_child.?.computed == null);
}

test "text nodes share their parent's style" {
    const p = try Page.make("<!doctype html><body><div id=a>t</div>", "", vp);
    defer p.done();
    try expect(p.el("a").first_child.?.computed == p.el("a").computed);
}

test "restyleSubtree reports the change" {
    const p = try Page.make("<!doctype html><body><div id=a class=x><span id=s>t</span></div>",
        \\.x { width: 10px; }
        \\.w { width: 20px; }
        \\.c { color: red; }
        \\.c2 { color: red; background: blue; }
        \\.none { display: none; }
    , vp);
    defer p.done();
    const a = p.el("a");
    const first = a.computed.?;
    try expect((try p.engine.restyleSubtree(a)) == .none);
    try expect(a.computed.? == first);
    try a.setAttr("class", "x c");
    try expect((try p.engine.restyleSubtree(a)) == .paint);
    try near(p.s("s").color.r, 1);
    try a.setAttr("class", "x c w");
    try expect((try p.engine.restyleSubtree(a)) == .layout);
    try a.setAttr("class", "none");
    try expect((try p.engine.restyleSubtree(a)) == .layout);
    try expect(p.el("s").computed == null);
    try a.setAttr("class", "x");
    try expect((try p.engine.restyleSubtree(a)) == .layout);
    try expect(p.el("s").computed != null);
    // A style attribute is reparsed once changed, and cached before that.
    try a.setAttr("style", "width: 3px");
    _ = try p.engine.restyleSubtree(a);
    try near(a.computed.?.width.px, 3);
    const cached = a.inline_decls;
    _ = try p.engine.restyleSubtree(a);
    try expect(a.inline_decls == cached);
    try a.setAttr("style", "width: 4px");
    _ = try p.engine.restyleSubtree(a);
    try near(a.computed.?.width.px, 4);
}

test "generations: a restored node is not compared with freed styles" {
    const p = try Page.make("<!doctype html><body><div id=a></div>", "", vp);
    defer p.done();
    const a = p.el("a");
    const body = a.parent.?;
    a.remove();
    try p.engine.restyleAll();
    try p.engine.restyleAll();
    body.appendChild(a);
    try expect((try p.engine.restyleSubtree(a)) == .layout);
    try expect(a.computed.?.display == .block);
}

test "hover sensitivity and invalidation" {
    const none = try Page.make("<!doctype html><body><a id=a>x</a>", "a { color: red }", vp);
    defer none.done();
    try expect(!none.engine.hoverSensitive());
    try expect(none.engine.invalidatedByState(none.el("a"), .hover) == null);

    const p = try Page.make(
        \\<!doctype html><body id=b><nav id=n class=menu><ul id=u><li id=l class=item><a id=a class=lnk href=x><i id=i>x</i></a></li><li id=l2></li></ul></nav><div id=d></div><p id=pp></p><span id=sib class=trig></span><span id=after></span>
    ,
        \\.lnk:hover { color: red; }
        \\.menu:hover .lnk { color: blue; }
        \\.trig:hover + span { color: green; }
        \\#pp:focus-within { color: red; }
    , vp);
    defer p.done();
    try expect(p.engine.hoverSensitive());
    // Hovering inside the menu: the menu's subtree is what can change.
    try expect(p.engine.invalidatedByState(p.el("i"), .hover) == p.el("n"));
    try expect(p.engine.invalidatedByState(p.el("a"), .hover) == p.el("n"));
    // Nothing state-sensitive up this chain.
    try expect(p.engine.invalidatedByState(p.el("d"), .hover) == null);
    // A sibling combinator reaches past the element: the parent restyles.
    try expect(p.engine.invalidatedByState(p.el("sib"), .hover) == p.el("b"));

    p.doc.hover = p.el("a");
    _ = try p.engine.restyleSubtree(p.el("n"));
    // `.menu:hover .lnk` is the more specific.
    try near(p.s("a").color.b, 1);
    try near(p.s("a").color.r, 0);
    p.doc.hover = null;
    try expect((try p.engine.restyleSubtree(p.el("n"))) == .paint);
    try near(p.s("a").color.b, 238.0 / 255.0);
    p.doc.hover = p.el("sib");
    _ = try p.engine.restyleSubtree(p.el("b"));
    try near(p.s("after").color.g, 128.0 / 255.0);
}

test ":has with a state restyles from the element it sits on" {
    const p = try Page.make(
        \\<!doctype html><body id=b><div id=far></div><div id=card class=card><a id=a href=x>x</a></div>
    ,
        \\.card:has(:hover) { color: red; }
    , vp);
    defer p.done();
    try expect(p.engine.invalidatedByState(p.el("a"), .hover) == p.el("card"));
    try expect(p.engine.invalidatedByState(p.el("far"), .hover) == null);
    const s = try Page.make(
        \\<!doctype html><body id=b><div id=one class=one></div><a id=a href=x>x</a>
    ,
        \\.one:has(+ :hover) { color: red; }
    , vp);
    defer s.done();
    try expect(s.engine.invalidatedByState(s.el("a"), .hover) == s.doc.documentElement());
}

test "each state invalidates only what reads it" {
    const p = try Page.make(
        \\<!doctype html><body id=b><a id=a href=x>x</a>
    ,
        \\html:focus-within { color: red; }
        \\body:is(:active) { color: blue; }
    , vp);
    defer p.done();
    try expect(p.engine.invalidatedByState(p.el("a"), .hover) == null);
    try expect(p.engine.invalidatedByState(p.el("a"), .focus) == p.doc.documentElement());
    try expect(p.engine.invalidatedByState(p.el("a"), .active) == p.el("b"));
}

test "color-scheme and the dark viewport" {
    const dark: css.Viewport = .{ .width = 100, .height = 100, .dark = true };
    {
        const p = try Page.make("<!doctype html><body id=b>x", "", dark);
        defer p.done();
        // The page did not ask: it stays light.
        try expect(!p.doc.documentElement().?.computed.?.dark_scheme);
        try near(p.s("b").color.r, 0);
    }
    {
        const p = try Page.make("<!doctype html><body id=b><a id=l href=x></a>", ":root { color-scheme: light dark; }", dark);
        defer p.done();
        const r = p.doc.documentElement().?.computed.?;
        try expect(r.dark_scheme);
        try expect(r.background.a == 1 and r.background.r < 0.1);
        try expect(p.s("b").color.r > 0.8);
        try expect(p.s("l").color.r > 0.5);
    }
    {
        const p = try Page.make("<!doctype html><body id=b>", ":root { color-scheme: light dark; }", .{ .width = 100, .height = 100 });
        defer p.done();
        try expect(!p.doc.documentElement().?.computed.?.dark_scheme);
    }
    {
        const p = try Page.make("<!doctype html><meta name=color-scheme content=dark><body id=b>", "#b { color: light-dark(red, lime); }", .{ .width = 100, .height = 100 });
        defer p.done();
        try expect(p.s("b").dark_scheme);
        try near(p.s("b").color.g, 1);
    }
}

test "presentational hints" {
    const p = try Page.make(
        \\<body bgcolor=#ff6600 id=b><table id=t width="85%" border=0 cellspacing=0 cellpadding=3 bgcolor="#f6f6ef"><tr><td id=c align=right valign=top nowrap bgcolor=red width=18>x</td></tr></table><font id=f color=#828282 size=2>t</font><img id=i width=100 height=50 align=left><center id=ce>c</center><div id=au align=center></div>
    , "#ov { width: 1px }", vp);
    defer p.done();
    try near(p.s("b").background.r, 1);
    try near(p.s("t").width.pct, 85);
    try expect(p.s("t").border_spacing == 0);
    try near(p.s("c").padding_top.px, 3);
    try expect(p.s("c").text_align == .right);
    try expect(p.s("c").vertical_align == .top);
    try expect(p.s("c").white_space == .nowrap);
    try near(p.s("c").background.r, 1);
    try near(p.s("c").width.px, 18);
    try near(p.s("f").font_size, 13);
    try near(p.s("f").color.r, 130.0 / 255.0);
    try near(p.s("i").width.px, 100);
    try near(p.s("i").aspect_ratio, 2);
    try expect(p.s("i").float == .left);
    try expect(p.s("ce").text_align == .center);
    try expect(p.s("au").text_align == .center);
}

test "quirks mode" {
    const p = try Page.make("<body class=Foo><div id=d class=BaR></div><table id=t><tr><td id=c>x</td></tr></table>", "body { color: red; font-size: 20px } .bar { width: 1px }", vp);
    defer p.done();
    try expect(p.doc.quirks);
    // Classes compare case-insensitively.
    try near(p.s("d").width.px, 1);
    // A table does not inherit text style.
    try near(p.s("c").color.r, 0);
    try near(p.s("c").font_size, 16);
}

test "computedValue serializes" {
    const p = try Page.make("<!doctype html><body><div id=a style='display:inline-block;color:#ff0000;width:50%;margin-left:3px;background:rgba(0,0,0,.5);border:1px solid red;--v: 1px 2px'></div>", "", vp);
    defer p.done();
    const a = p.el("a");
    const v = struct {
        fn f(pg: *Page, n: *dom.Node, name: []const u8, want: []const u8) !void {
            const got = pg.engine.computedValue(n, name) orelse return error.Null;
            try eq(want, got);
        }
    }.f;
    try v(p, a, "display", "inline-block");
    try v(p, a, "color", "rgb(255, 0, 0)");
    try v(p, a, "width", "50%");
    try v(p, a, "margin-left", "3px");
    try v(p, a, "background-color", "rgba(0, 0, 0, 0.5)");
    try v(p, a, "border-top-width", "1px");
    try v(p, a, "border-top-style", "solid");
    try v(p, a, "--v", "1px 2px");
    try v(p, a, "height", "auto");
    try expect(p.engine.computedValue(a, "nonsense") == null);
}

test "what a browser makes of an old <hr>, and line-break's reach" {
    const p = try Page.make("<hr id=a noshade size=1><hr id=b size=6><hr id=c size=1 noshade color=red><div style='line-break:anywhere'><span id=d>x</span></div>", "", vp);
    defer p.done();
    try near(p.s("a").border_bottom.width, 0);
    try near(p.s("a").border_top.width, 1);
    try std.testing.expect(p.s("a").border_top.style == .solid);
    try near(p.s("a").background.r * 255, 169);
    try near(p.s("b").height.px, 4);
    try near(p.s("c").background.g, 0);
    try std.testing.expect(p.s("d").line_break_anywhere);
}

test "a form has a bottom margin in quirks mode only" {
    const q = try Page.make("<form id=f></form>", "", vp);
    defer q.done();
    try near(q.s("f").margin_bottom.px, 16);
    const std_mode = try Page.make("<!doctype html><form id=f></form>", "", vp);
    defer std_mode.done();
    try near(std_mode.s("f").margin_bottom.px, 0);
}

test "inline style sharing and subtree bloom selector pruning" {
    const p = try Page.make(
        "<!doctype html><body><div id=wrap>" ++
            "<div class='bar' style='width:42px;color:rgb(10,20,30)'><span>a</span></div>" ++
            "<div class='bar' style='width:42px;color:rgb(10,20,30)'><span class='needle' data-k='v'>b</span></div>" ++
            "<div class='bar' style='width:99px;color:rgb(10,20,30)'><span>c</span></div>" ++
            "</div>",
        ".bar { height: 12px; }",
        vp,
    );
    defer p.done();
    const wrap = p.el("wrap");
    const b1 = wrap.firstElementChild().?;
    const b2 = b1.nextElement().?;
    const b3 = b2.nextElement().?;
    try expect(b1.computed == b2.computed);
    try expect(b1.computed != b3.computed);
    const found_cls = (try css.querySelector(wrap, ".needle", p.arena.allocator())).?;
    const found_attr = (try css.querySelector(wrap, "[data-k='v']", p.arena.allocator())).?;
    try expect(found_cls == found_attr);
    try expect((try css.querySelector(wrap, ".nonexistent", p.arena.allocator())) == null);
}
