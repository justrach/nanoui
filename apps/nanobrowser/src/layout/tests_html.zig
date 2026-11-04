//! From an HTML string through the parser and the cascade: pages shaped like
//! the ones the engine is for.
const std = @import("std");
const u = @import("tests_util.zig");
const box = @import("box.zig");
const dom = @import("../dom.zig");
const html = @import("../html/html.zig");
const css = @import("../css/css.zig");
const layout = @import("layout.zig");
const gpa = std.testing.allocator;
const close = u.close;
const eq = u.eqText;

const Page = struct {
    arena: std.heap.ArenaAllocator,
    doc: *dom.Document,
    engine: css.Engine,
    tree: box.Tree,

    fn make(source: []const u8, sheet: []const u8, w: f32, h: f32) !*Page {
        const p = try gpa.create(Page);
        p.arena = std.heap.ArenaAllocator.init(gpa);
        const a = p.arena.allocator();
        p.doc = try dom.Document.create(a);
        try html.parseDocument(p.doc, source);
        p.engine = css.Engine.init(gpa, p.doc);
        const s = try css.parseSheet(a, sheet, "https://x.test/s.css");
        p.engine.setSheets(&.{s});
        p.engine.setViewport(.{ .width = w, .height = h });
        try p.engine.restyleAll();
        p.tree = try layout.run(a, p.doc, .{ .width = w, .height = h }, u.measurer);
        return p;
    }

    fn done(p: *Page) void {
        p.engine.deinit();
        p.arena.deinit();
        gpa.destroy(p);
    }

    fn b(p: *Page, id: []const u8) *box.Box {
        const n = p.doc.getElementById(id) orelse @panic("no such id");
        return @ptrCast(@alignCast(n.box orelse @panic("no box")));
    }
};

test "the UA sheet's body margin and block flow" {
    const p = try Page.make("<!doctype html><html><body><p id=a>hello world</p><p id=b>next</p></body></html>", "", 800, 600);
    defer p.done();
    const a = p.b("a");
    try close(8, a.x, "body margin");
    try close(784, a.w, "the rest");
    // p's 1em margin collapses with body's 8.
    try close(16, a.y, "1em");
    try close(16, a.h, "one line");
    try close(48, p.b("b").y, "one margin between");
    try eq("hello world", a.runs[0].text);
}

const hn =
    \\<html lang="en" op="news"><head><meta name="referrer" content="origin">
    \\<title>Hacker News</title></head><body><center><table id="hnmain" border="0" cellpadding="0" cellspacing="0" width="85%" bgcolor="#f6f6ef">
    \\<tr><td bgcolor="#ff6600"><table border="0" cellpadding="0" cellspacing="0" width="100%" style="padding:2px"><tr><td id=logo style="width:18px;padding-right:4px"><a href="https://news.ycombinator.com"><img id=logoimg src="y18.svg" width="18" height="18" style="border:1px white solid; display:block"></a></td>
    \\<td id=nav style="line-height:12pt; height:10px;"><span class="pagetop"><b class="hnname"><a href="news">Hacker News</a></b>
    \\<a href="newest">new</a> | <a href="front">past</a></span></td><td id=login style="text-align:right;padding-right:4px;"><span class="pagetop"><a href="login">login</a></span></td>
    \\</tr></table></td></tr>
    \\<tr id="pagespace" title="" style="height:10px"></tr><tr><td><table border="0" cellpadding="0" cellspacing="0">
    \\<tr class='athing' id='1'>
    \\      <td id=rank align="right" valign="top" class="title"><span class="rank">1.</span></td>      <td id=vote valign="top" class="votelinks"><center><a id='up_1' href='vote'><div class='votearrow' title='upvote'></div></a></center></td><td id=title class="title"><span class="titleline"><a href="https://example.com/">A rather interesting story about something</a><span class="sitebit comhead"> (<a href="from"><span class="sitestr">example.com</span></a>)</span></span></td></tr><tr><td colspan="2"></td><td id=sub class="subtext"><span class="subline">
    \\          <span class="score" id="score_1">123 points</span> by <a href="user" class="hnuser">someone</a> <span class="age"><a href="item">2 hours ago</a></span> <span id="unv_1"></span> | <a href="item">45&nbsp;comments</a>        </span>
    \\              </td></tr>
    \\      <tr id=spacer class="spacer" style="height:5px"></tr>
    \\</table></td></tr></table></center></body></html>
;
const hn_css =
    \\body  { font-family:Verdana, Geneva, sans-serif; font-size:10pt; color:#828282; }
    \\td    { font-family:Verdana, Geneva, sans-serif; font-size:10pt; color:#828282; }
    \\.title { font-family:Verdana, Geneva, sans-serif; font-size: 10pt; color:#828282; overflow:hidden; }
    \\.subtext { font-family:Verdana, Geneva, sans-serif; font-size:  7pt; color:#828282; }
    \\.votearrow { width: 10px; height: 10px; border: 0px; margin: 3px 2px 6px; }
    \\.rank { color: #828282; }
;

test "Hacker News: center, nested tables, percent widths, quirks" {
    const p = try Page.make(hn, hn_css, 1000, 800);
    defer p.done();
    try std.testing.expect(p.doc.quirks);
    const main = p.b("hnmain");
    // 85% of the body's content width: 1000 less its margins.
    try close(836.4, main.w, "85%");
    try close(8 + (984 - main.w) / 2, main.x, "centered in the body");
}

test "Hacker News: the header row and story rows take the right shape" {
    const p = try Page.make(hn, hn_css, 1000, 800);
    defer p.done();
    const main = p.b("hnmain");
    const logo = p.b("logo");
    const img = p.b("logoimg");
    // The header table fills main; its padding is 2.
    try close(main.x + 2, logo.x, "logo cell at the padding");
    // Its content is the picture, 18 + a border of 1 each side, with padding of 4.
    try close(24, logo.w, "logo cell's width");
    try close(20, img.w, "18 + its border");
    const nav = p.b("nav");
    const login = p.b("login");
    try close(logo.x + logo.w, nav.x, "no spacing");
    try close(main.x + main.w - 2, login.x + login.w, "login reaches the far side");
    // Right aligned text in login.
    const span = login.first_child.?;
    try close(login.x + login.w - 4, span.x + span.w, "to its padding");

    const rank = p.b("rank");
    const vote = p.b("vote");
    const title = p.b("title");
    try close(rank.x + rank.w, vote.x, "rank then vote");
    try close(vote.x + vote.w, title.x, "vote then title");
    try close(14, vote.w, "the arrow's 10 + margins of 2");
    // Colspan 2: subtext lines up with the title.
    const sub = p.b("sub");
    try close(title.x, sub.x, "subtext under the title");
    try std.testing.expect(sub.y >= title.y + title.h);
    try close(5, p.b("spacer").h, "the spacer row");
    const row: *box.Box = @ptrCast(@alignCast(p.doc.getElementById("pagespace").?.box.?));
    try close(10, row.h, "the spacer row above the stories");
}

test "flex with Tailwind's habits: a nav, a centered card, gaps" {
    const src =
        \\<!doctype html><html><body class="m-0">
        \\<nav id=nav class="flex items-center justify-between px-4 h-16"><a id=brand class="font-bold" href="/">Brand</a>
        \\<div id=links class="flex gap-4"><a id=l1 href="/a">One</a><a id=l2 href="/b">Two</a></div></nav>
        \\<main class="mx-auto max-w-md p-4"><div id=card class="rounded p-4 flex flex-col gap-2 w-full">
        \\<h1 id=title class="text-xl">Hello</h1><p id=body class="m-0">Some text</p><button id=btn class="self-start px-4 py-2">Go</button></div></main>
        \\</body></html>
    ;
    const sheet =
        \\.m-0 { margin: 0 } .flex { display: flex } .items-center { align-items: center }
        \\.justify-between { justify-content: space-between } .px-4 { padding-left: 1rem; padding-right: 1rem }
        \\.h-16 { height: 4rem } .gap-4 { gap: 1rem } .mx-auto { margin-left: auto; margin-right: auto }
        \\.max-w-md { max-width: 28rem } .p-4 { padding: 1rem } .flex-col { flex-direction: column }
        \\.gap-2 { gap: .5rem } .w-full { width: 100% } .self-start { align-self: flex-start } .py-2 { padding-top: .5rem; padding-bottom: .5rem }
        \\*, ::before, ::after { box-sizing: border-box } h1 { margin: 0 }
    ;
    const p = try Page.make(src, sheet, 1024, 768);
    defer p.done();
    const nav = p.b("nav");
    try close(0, nav.y, "top");
    try close(64, nav.h, "h-16");
    const brand = p.b("brand");
    try close(16, brand.x, "px-4");
    const links = p.b("links");
    try close(1024 - 16, links.x + links.w, "pushed to the far side");
    const l1 = p.b("l1");
    const l2 = p.b("l2");
    try close(l1.x + l1.w + 16, l2.x, "gap-4");
    // 448 wide and centered.
    const card = p.b("card");
    try close(1024 / 2 - 224 + 16, card.x, "centered, inside p-4");
    try close(416, card.w, "448 - 32");
    const title = p.b("title");
    const body = p.b("body");
    try close(title.y + title.h + 8, body.y, "gap-2");
    const btn = p.b("btn");
    try std.testing.expect(btn.w < 100);
    try close(card.x + 16, btn.x, "self-start");
}

test "grid: a responsive card grid" {
    const src =
        \\<!doctype html><html><body style="margin:0"><div id=g style="display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:20px;padding:10px">
        \\<div id=a>one</div><div id=b style="grid-column:span 2">two</div><div id=c>three</div></div>
        \\<div id=f style="display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:10px"><i id=x>a</i><i id=y>b</i></div></body></html>
    ;
    const p = try Page.make(src, "", 1000, 600);
    defer p.done();
    const a = p.b("a");
    const b = p.b("b");
    const c = p.b("c");
    // (1000 - 20 padding - 40 gaps) / 3 = 313.33.
    try close(940.0 / 3.0, a.w, "a third");
    try close(10, a.x, "padding");
    try close(a.x + a.w + 20, b.x, "after the gap");
    try close(940.0 / 3.0 * 2 + 20, b.w, "two and a gap");
    try close(a.y + a.h + 20, c.y, "next row");
    // 1000: (1000 + 10) / 210 = 4 tracks of (1000 - 30) / 4 = 242.5.
    try close(242.5, p.b("x").w, "auto-fill");
    try close(252.5, p.b("y").x, "second");
}

test "Wikipedia's shape: an infobox floated right, text beside it, then cleared" {
    const src =
        \\<!doctype html><html><body><div id=page style="width:600px"><table id=info style="float:right;width:200px;margin:0 0 8px 8px"><tr><th>Born</th><td>1900</td></tr></table>
        \\<p id=first>Some words here beside the floated box and more of them to wrap around it again and again and again, enough to go on for a while beside it.</p>
        \\<h2 id=h style="clear:both">Life</h2></div></body></html>
    ;
    const p = try Page.make(src, "", 800, 600);
    defer p.done();
    const info = p.b("info");
    try close(8 + 600 - 200, info.x, "at the right");
    const first = p.b("first");
    try close(600, first.w, "the paragraph keeps its width");
    const run = first.runs[0];
    try std.testing.expect(run.x + run.w <= info.x - 8 + 0.01);
    const h = p.b("h");
    try std.testing.expect(h.y >= info.y + info.h);
}

test "lists and inputs through the UA sheet" {
    const src =
        \\<!doctype html><html><body><ol id=o start=3><li id=a>one</li><li id=b>two</li></ol><ul><li id=c>three</li></ul>
        \\<form><input id=i value=x><input id=k type=checkbox><select id=s><option>longer option</select><button id=g>go</button><input id=sub type=submit value=send></form></body></html>
    ;
    const p = try Page.make(src, "", 800, 600);
    defer p.done();
    try eq("3.", p.b("a").runs[0].text);
    try eq("4.", p.b("b").runs[0].text);
    try std.testing.expect(p.b("c").marker != null);
    try std.testing.expect(p.b("i").kind == .control);
    try std.testing.expect(p.b("i").w > 100);
    try close(13, p.b("k").w, "checkbox");
    try std.testing.expect(p.b("s").kind == .control);
    try std.testing.expect(p.b("g").kind == .block);
    try eq("send", p.b("sub").runs[0].text);
}
