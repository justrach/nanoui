//! Pages in the shape real ones have: Hacker News's tables and presentational
//! attributes, Wikipedia's sheet, Tailwind's preflight, variables and utilities.
const std = @import("std");
const css = @import("css.zig");
const page = @import("tests_cascade.zig");

const expect = std.testing.expect;
const Page = page.Page;
const vp: css.Viewport = .{ .width = 1280, .height = 800 };

fn near(a: f32, b: f32) !void {
    if (@abs(a - b) > 0.02) {
        std.debug.print("got {d}, want {d}\n", .{ a, b });
        return error.TestUnexpectedResult;
    }
}

test "Hacker News" {
    const p = try Page.make(
        \\<html lang="en" op="news"><head><meta name="referrer" content="origin"><title>Hacker News</title></head>
        \\<body><center><table id="hnmain" border="0" cellpadding="0" cellspacing="0" width="85%" bgcolor="#f6f6ef">
        \\<tr><td id="hd" bgcolor="#ff6600"><table border="0" cellpadding="0" cellspacing="0" width="100%" style="padding:2px"><tr><td style="width:18px;padding-right:4px"><a href="https://news.ycombinator.com"><img id="logo" src="y18.svg" width="18" height="18" style="border:1px white solid; display:block"></a></td>
        \\<td style="line-height:12pt; height:10px;"><span class="pagetop"><b class="hnname"><a id="hn" href="news">Hacker News</a></b> <a href="newest">new</a></span></td>
        \\<td style="text-align:right;padding-right:4px;"><span class="pagetop"><a href="login">login</a></span></td></tr></table></td></tr>
        \\<tr id="pagespace" title="" style="height:10px"></tr>
        \\<tr><td><table border="0" cellpadding="0" cellspacing="0"><tr class="athing" id="1"><td align="right" valign="top" class="title"><span class="rank" id="rank">1.</span></td>
        \\<td valign="top" class="votelinks"><center><a id="up" href="vote"><div class="votearrow" id="arrow" title="upvote"></div></a></center></td>
        \\<td class="title"><span class="titleline"><a id="story" href="https://x">A story</a><span class="sitebit comhead"> (<a href="from"><span class="sitestr" id="site">x.com</span></a>)</span></span></td></tr>
        \\<tr><td colspan="2"></td><td class="subtext" id="sub"><span class="score">1 point</span></td></tr></table></td></tr>
        \\</table></center></body></html>
    ,
        \\body  { font-family:Verdana, Geneva, sans-serif; font-size:10pt; color:#828282; }
        \\td    { font-family:Verdana, Geneva, sans-serif; font-size:10pt; color:#828282; }
        \\.admin td   { font-family:Verdana, Geneva, sans-serif; font-size:8.5pt; color:#000000; }
        \\.subtext td { font-family:Verdana, Geneva, sans-serif; font-size:  7pt; color:#828282; }
        \\pre { overflow: auto; padding: 2px; white-space: pre-wrap; overflow-wrap:anywhere; }
        \\pre:hover { overflow:auto }
        \\a:link    { color:#000000; text-decoration:none; }
        \\a:visited { color:#828282; text-decoration:none; }
        \\.pagetop { font-family:Verdana, Geneva, sans-serif; font-size: 10pt; color:#222222; line-height:12px; }
        \\.title { font-family:Verdana, Geneva, sans-serif; font-size: 10pt; color:#828282; overflow:hidden; }
        \\.titleline a:link { color:#000000; }
        \\.subtext { font-family:Verdana, Geneva, sans-serif; font-size: 7pt; color:#828282; }
        \\.votearrow { width: 10px; height: 10px; border: 0px; margin: 3px 2px 6px; background: url("triangle.svg"), linear-gradient(transparent, transparent); background-size: 10px; background-repeat: no-repeat; }
        \\.rank { color: #828282 }
        \\.comhead a:link, .subtext a, .subline a { color:#828282; }
        \\@media only screen and (min-width : 300px) and (max-width : 750px) { #hnmain { width: 100%; } }
    , vp);
    defer p.done();
    try expect(p.doc.quirks);
    const main = p.s("hnmain");
    try near(main.width.pct, 85);
    try near(main.background.r, 246.0 / 255.0);
    try expect(main.border_spacing == 0);
    // `<center>` centers the table.
    try expect(main.margin_left.kind == .auto and main.margin_right.kind == .auto);
    try near(p.s("hd").background.g, 102.0 / 255.0);
    try near(p.s("hd").padding_top.px, 0);
    try near(p.s("logo").width.px, 18);
    try near(p.s("logo").border_top.width, 1);
    try expect(p.s("logo").display == .block);
    const hn = p.s("hn");
    try near(hn.color.r, 0);
    try expect(!hn.underline);
    try expect(hn.font_weight == 700);
    try near(hn.font_size, 13.33);
    try expect(!hn.serif and !hn.mono);
    try expect(p.s("rank").display == .inline_);
    try near(p.s("rank").color.r, 130.0 / 255.0);
    try near(p.s("arrow").width.px, 10);
    try near(p.s("arrow").margin_top.px, 3);
    try near(p.s("arrow").margin_bottom.px, 6);
    try near(p.s("arrow").border_top.width, 0);
    try expect(p.s("arrow").background_repeat == .no_repeat);
    try near(p.s("arrow").background_size_x.px, 10);
    try expect(std.mem.endsWith(u8, p.s("arrow").background_image, "triangle.svg"));
    try near(p.s("sub").font_size, 9.33);
    try near(p.s("site").color.r, 130.0 / 255.0);
    try near(p.el("story").computed.?.color.r, 0);
    // The small viewport flips the media query.
    p.engine.setViewport(.{ .width = 600, .height = 800 });
    try p.engine.restyleAll();
    try near(p.s("hnmain").width.pct, 100);
}

test "Wikipedia" {
    const p = try Page.make(
        \\<!DOCTYPE html><html class="client-js vector-feature-x" lang="en" dir="ltr"><head><title>T</title></head>
        \\<body class="skin-vector mediawiki"><div id="content" class="mw-body"><h1 id="firstHeading" class="firstHeading mw-first-heading"><span id="ht" class="mw-page-title-main">Title</span></h1>
        \\<div id="mw-content-text" class="mw-body-content"><div class="mw-parser-output"><table class="infobox vcard" id="ib"><tbody><tr><th id="ibh" scope="row" class="infobox-label">Born</th><td id="ibd" class="infobox-data">x</td></tr></tbody></table>
        \\<p id="para">Text <b>bold</b> <a id="wl" href="/wiki/X" title="X">link</a><sup id="ref" class="reference"><a href="#cite_note-1"><span class="cite-bracket">[</span>1<span class="cite-bracket">]</span></a></sup></p>
        \\<div id="toc" class="toc" role="navigation"><ul id="tocl"><li id="toci" class="toclevel-1"><a href="#x"><span class="tocnumber">1</span></a></li></ul></div>
        \\<h2 id="h2"><span class="mw-headline">Section</span></h2><pre id="pr">code</pre><code id="cd">c</code><blockquote id="bq">q</blockquote></div></div></div></body></html>
    ,
        \\html { font-size: 100%; }
        \\html, body { height: 100%; margin: 0; padding: 0; font-family: sans-serif; }
        \\body { background-color: #f8f9fa; }
        \\.mw-body { margin-left: 10em; padding: 1.25em 1.5em 1.5em; border: 1px solid #a2a9b1; border-right-width: 0; color: #202122; direction: ltr; background-color: #fff; }
        \\.mw-body h1, .mw-body-content h1, .mw-body-content h2 { font-family: 'Linux Libertine','Georgia','Times',serif; line-height: 1.3; margin-bottom: 0.25em; padding: 0; }
        \\.mw-body .firstHeading { overflow: visible; }
        \\.mw-body-content { position: relative; z-index: 0; font-size: 0.875em; line-height: 1.6; }
        \\.mw-body-content p { margin: 0.5em 0; }
        \\.mw-body-content a { text-decoration: none; }
        \\.mw-body-content a:hover { text-decoration: underline; }
        \\.mw-parser-output a:not(.mw-selflink):visited { color: #795cb2 }
        \\.mw-parser-output .infobox { float: right; clear: right; width: 22em; margin: 0.5em 0 1em 1em; padding: 0.2em; border: 1px solid #a2a9b1; font-size: 88%; background-color: #f8f9fa; border-spacing: 3px; }
        \\.infobox-label { text-align: left; }
        \\sup, .reference { line-height: 1; }
        \\.toc { display: table; padding: 7px; border: 1px solid #a2a9b1; background-color: #f8f9fa; }
        \\.toc ul { list-style-type: none; list-style-image: none; margin: 0.3em 0; padding: 0; text-align: left; }
        \\pre, code { font-family: monospace, monospace; background-color: #f8f9fa; }
        \\@media screen { .mw-body { color: #202122 } }
        \\@media print { .toc { display: none } }
        \\@media (prefers-color-scheme: dark) { body { background-color: #000 } }
        \\@supports (position: sticky) { .firstHeading { position: sticky } }
        \\@supports not (display: grid) { .toc { display: none } }
    , vp);
    defer p.done();
    try expect(!p.doc.quirks);
    const c = p.s("content");
    try near(c.margin_left.px, 160);
    try near(c.padding_top.px, 20);
    try near(c.border_top.width, 1);
    try near(c.border_right.width, 0);
    try near(c.color.r, 32.0 / 255.0);
    const h = p.s("firstHeading");
    try expect(h.serif);
    try near(h.font_size, 32);
    try near(h.line_height, 41.6);
    try near(h.margin_bottom.px, 8);
    try expect(h.position == .sticky);
    const text = p.s("mw-content-text");
    try near(text.font_size, 14);
    try near(text.line_height, 22.4);
    try expect(text.z_index.? == 0);
    const para = p.s("para");
    try near(para.font_size, 14);
    try near(para.margin_top.px, 7);
    try near(para.line_height, 22.4);
    const ib = p.s("ib");
    try expect(ib.float == .right);
    try expect(ib.display == .table);
    try near(ib.font_size, 12.32);
    try near(ib.width.px, 22 * 12.32);
    try near(ib.border_spacing, 3);
    try expect(p.s("ibh").text_align == .left);
    try expect(p.s("ibh").font_weight == 700);
    try expect(!p.s("wl").underline);
    try near(p.s("ref").line_height, p.s("ref").font_size);
    try expect(p.s("toc").display == .table);
    try expect(p.s("tocl").list_style == .none);
    try near(p.s("tocl").padding_left.px, 0);
    try near(p.s("toci").margin_top.px, 0);
    try expect(p.s("h2").serif);
    try near(p.s("h2").font_size, 21);
    try near(p.s("pr").font_size, 14);
    try expect(p.s("cd").mono);
    try near(p.s("bq").margin_left.px, 40);
    // Hovering the link turns its underline on, and costs its own subtree.
    p.doc.hover = p.el("wl");
    try expect(p.engine.invalidatedByState(p.el("wl"), .hover) == p.el("wl"));
    try expect((try p.engine.restyleSubtree(p.el("wl"))) == .paint);
    try expect(p.s("wl").underline);
}

test "Tailwind" {
    const p = try Page.make(
        \\<!doctype html><html><body id="b"><div id="card" class="mx-auto max-w-md rounded-xl bg-white p-6 shadow-lg flex items-center gap-4"><img id="im" class="h-12 w-12" src="x"><div id="t" class="text-xl font-medium text-black hover:text-blue-500 dark:bg-black">x</div></div>
        \\<button id="btn" class="bg-blue-500 hover:bg-blue-700 text-white py-2 px-4 rounded">b</button><div id="grid" class="grid grid-cols-3 md:grid-cols-[1fr_auto] gap-x-2"></div><p id="hd" class="hidden md:block">h</p></body></html>
    ,
        \\*, ::before, ::after { box-sizing: border-box; border-width: 0; border-style: solid; border-color: #e5e7eb; --tw-translate-x: 0; --tw-ring-offset-shadow: 0 0 #0000; --tw-ring-shadow: 0 0 #0000; --tw-shadow: 0 0 #0000; }
        \\::before, ::after { --tw-content: ''; }
        \\html { line-height: 1.5; -webkit-text-size-adjust: 100%; font-family: ui-sans-serif, system-ui, sans-serif; tab-size: 4; }
        \\body { margin: 0; line-height: inherit; }
        \\h1, h2 { font-size: inherit; font-weight: inherit; }
        \\button, input { font-family: inherit; font-size: 100%; font-weight: inherit; line-height: inherit; color: inherit; margin: 0; padding: 0; }
        \\button, [type='button'] { -webkit-appearance: button; background-color: transparent; background-image: none; }
        \\img, svg { display: block; vertical-align: middle; }
        \\img, video { max-width: 100%; height: auto; }
        \\[hidden] { display: none; }
        \\.mx-auto { margin-left: auto; margin-right: auto; }
        \\.max-w-md { max-width: 28rem; }
        \\.flex { display: flex; }
        \\.grid { display: grid; }
        \\.hidden { display: none; }
        \\.h-12 { height: 3rem; }
        \\.w-12 { width: 3rem; }
        \\.items-center { align-items: center; }
        \\.gap-4 { gap: 1rem; }
        \\.gap-x-2 { -moz-column-gap: 0.5rem; column-gap: 0.5rem; }
        \\.rounded { border-radius: 0.25rem; }
        \\.rounded-xl { border-radius: 0.75rem; }
        \\.bg-white { --tw-bg-opacity: 1; background-color: rgb(255 255 255 / var(--tw-bg-opacity)); }
        \\.bg-blue-500 { --tw-bg-opacity: 1; background-color: rgb(59 130 246 / var(--tw-bg-opacity)); }
        \\.p-6 { padding: 1.5rem; }
        \\.px-4 { padding-left: 1rem; padding-right: 1rem; }
        \\.py-2 { padding-top: 0.5rem; padding-bottom: 0.5rem; }
        \\.text-xl { font-size: 1.25rem; line-height: 1.75rem; }
        \\.font-medium { font-weight: 500; }
        \\.text-black { --tw-text-opacity: 1; color: rgb(0 0 0 / var(--tw-text-opacity)); }
        \\.text-white { --tw-text-opacity: 1; color: rgb(255 255 255 / var(--tw-text-opacity)); }
        \\.shadow-lg { --tw-shadow: 0 10px 15px -3px rgb(0 0 0 / 0.1), 0 4px 6px -4px rgb(0 0 0 / 0.1); --tw-shadow-colored: 0 10px 15px -3px var(--tw-shadow-color); box-shadow: var(--tw-ring-offset-shadow, 0 0 #0000), var(--tw-ring-shadow, 0 0 #0000), var(--tw-shadow); }
        \\.grid-cols-3 { grid-template-columns: repeat(3, minmax(0, 1fr)); }
        \\.hover\:text-blue-500:hover { --tw-text-opacity: 1; color: rgb(59 130 246 / var(--tw-text-opacity)); }
        \\.hover\:bg-blue-700:hover { --tw-bg-opacity: 1; background-color: rgb(29 78 216 / var(--tw-bg-opacity)); }
        \\@media (prefers-color-scheme: dark) { .dark\:bg-black { --tw-bg-opacity: 1; background-color: rgb(0 0 0 / var(--tw-bg-opacity)); } }
        \\@media (min-width: 768px) { .md\:block { display: block; } .md\:grid-cols-\[1fr_auto\] { grid-template-columns: 1fr auto; } }
    , vp);
    defer p.done();
    const c = p.s("card");
    try expect(c.display == .flex and c.box_sizing == .border_box);
    try expect(c.align_items == .center);
    try near(c.column_gap.px, 16);
    try near(c.max_width.px, 448);
    try expect(c.margin_left.kind == .auto);
    try near(c.radius[0], 12);
    try near(c.background.r, 1);
    try near(c.background.a, 1);
    try near(c.padding_left.px, 24);
    try near(c.border_top.width, 0);
    const sh = c.shadow.?;
    try near(sh.y, 10);
    try near(sh.blur, 15);
    try near(sh.spread, -3);
    try near(sh.color.a, 0.1);
    const im = p.s("im");
    try expect(im.display == .block);
    try near(im.width.px, 48);
    try near(im.height.px, 48);
    try near(im.max_width.pct, 100);
    const t = p.s("t");
    try near(t.font_size, 20);
    try near(t.line_height, 28);
    try expect(t.font_weight == 500);
    try expect(t.display == .block);
    try near(t.background.a, 0);
    const b = p.s("btn");
    try near(b.background.b, 246.0 / 255.0);
    try near(b.color.r, 1);
    try near(b.font_size, 16);
    try near(b.line_height, 24);
    try near(b.padding_left.px, 16);
    try near(b.padding_top.px, 8);
    try near(b.radius[3], 4);
    try near(b.border_top.width, 0);
    try expect(p.s("grid").display == .grid);
    try expect(p.s("grid").grid_template_columns.tracks.len == 2);
    try expect(p.s("grid").grid_template_columns.tracks[1].kind == .auto);
    try near(p.s("grid").column_gap.px, 8);
    try expect(p.s("hd").display == .block);
    try near(p.s("b").line_height, 24);
    try near(p.s("b").tab_size, 4);

    p.doc.hover = p.el("btn");
    try expect(p.engine.hoverSensitive());
    try expect(p.engine.invalidatedByState(p.el("btn"), .hover) == p.el("btn"));
    try expect((try p.engine.restyleSubtree(p.el("btn"))) == .paint);
    try near(p.s("btn").background.b, 216.0 / 255.0);
    try near(p.s("btn").background.r, 29.0 / 255.0);
    p.doc.hover = null;
    try expect((try p.engine.restyleSubtree(p.el("btn"))) == .paint);

    p.engine.setViewport(.{ .width = 500, .height = 800, .dark = true });
    try p.engine.restyleAll();
    try expect(p.s("hd").display == .none);
    try expect(p.s("grid").grid_template_columns.tracks.len == 3);
    try near(p.s("t").background.a, 1);
}

test "CSS variable themes, GitHub style" {
    const p = try Page.make(
        \\<!doctype html><html id="r" data-color-mode="dark" data-dark-theme="dark"><body id="b"><header id="h" class="Header"><a id="l" class="Header-link" href="/">x</a></header><main><article id="m" class="markdown-body"><pre id="pr"><code id="cd">x</code></pre><table id="t"><tr id="odd"><td>a</td></tr><tr id="even"><td id="ec">b</td></tr></table></article><button id="bt" class="btn btn-primary" disabled>go</button></main></body></html>
    ,
        \\@layer primer-base, primer-theme;
        \\@layer primer-base { body { margin: 0; font: 14px/1.5 -apple-system, "Segoe UI", sans-serif; } }
        \\[data-color-mode="dark"][data-dark-theme="dark"] { --fg: #e6edf3; --bg: #0d1117; --border: #30363d; --accent: var(--unset, #2f81f7); color-scheme: dark; }
        \\body { color: var(--fg); background-color: var(--bg, white); }
        \\.Header { display: flex; padding: var(--h-pad, 16px); background: color-mix(in srgb, var(--bg), white 10%); position: relative; z-index: 32; }
        \\.Header-link { color: inherit; font-weight: 600; white-space: nowrap; }
        \\.Header-link:where(:hover, :focus) { color: var(--accent); }
        \\.markdown-body { word-wrap: break-word; font-size: 16px; line-height: 1.5; }
        \\.markdown-body pre { padding: 16px; overflow: auto; font-size: 85%; line-height: 1.45; border-radius: 6px; background-color: var(--bg); }
        \\.markdown-body pre code { display: inline; max-width: auto; padding: 0; border: 0; font-size: 100%; word-break: normal; white-space: pre; }
        \\.markdown-body table { display: block; width: 100%; width: max-content; max-width: 100%; overflow: auto; border-spacing: 0; border-collapse: collapse; }
        \\.markdown-body table tr:nth-child(2n) { background-color: var(--border); }
        \\.btn { position: relative; display: inline-block; padding: 5px 16px; font-size: 14px; font-weight: 500; cursor: pointer; border: 1px solid var(--border); border-radius: 6px; appearance: none; }
        \\.btn:disabled, .btn.disabled { cursor: default; opacity: 0.5; }
        \\.btn:not(:disabled):hover { background-color: var(--accent); }
        \\@media (forced-colors: active) { .btn { border-color: red; } }
        \\@container (min-width: 100px) { .Header { margin-top: 1px; } }
    , vp);
    defer p.done();
    const body = p.s("b");
    try near(body.color.r, 230.0 / 255.0);
    try near(body.background.b, 23.0 / 255.0);
    try near(body.font_size, 14);
    try near(body.line_height, 21);
    try expect(body.dark_scheme);
    const h = p.s("h");
    try expect(h.display == .flex);
    try near(h.padding_top.px, 16);
    try near(h.background.r, (13.0 / 255.0) * 0.9 + 0.1);
    try expect(h.z_index.? == 32);
    // Nothing here is a container, so `@container` has nobody to ask.
    try near(h.margin_top.px, 0);
    const l = p.s("l");
    try near(l.color.r, 230.0 / 255.0);
    try expect(l.font_weight == 600 and l.white_space == .nowrap);
    try expect(l.display == .block);
    const pr = p.s("pr");
    try near(pr.font_size, 13.6);
    try near(pr.line_height, 19.72);
    const cd = p.s("cd");
    try near(cd.font_size, 13.6);
    try expect(cd.mono);
    const t = p.s("t");
    try expect(t.display == .block);
    try expect(t.width.kind == .max_content);
    try expect(t.border_collapse);
    try near(p.s("even").background.r, 48.0 / 255.0);
    try near(p.s("odd").background.a, 0);
    const b = p.s("bt");
    try expect(b.cursor == .default);
    try near(b.opacity, 0.5);
    try near(b.border_top.color.r, 48.0 / 255.0);
    try near(b.border_top.width, 1);
    p.doc.hover = p.el("l");
    _ = try p.engine.restyleSubtree(p.el("l"));
    try near(p.s("l").color.r, 47.0 / 255.0);
}
