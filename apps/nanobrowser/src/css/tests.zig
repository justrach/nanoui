//! CSS engine tests: tokenizer, parser recovery, selectors, media. The cascade's
//! are in `tests_cascade.zig`.
const std = @import("std");
const dom = @import("../dom.zig");
const html = @import("../html/html.zig");
const css = @import("css.zig");
const tk = @import("tokenizer.zig");
const selectors = @import("selectors.zig");
const media = @import("media.zig");

const expect = std.testing.expect;
const eq = std.testing.expectEqualStrings;

test {
    _ = @import("url.zig");
    _ = @import("rule_index.zig");
    _ = @import("tests_cascade.zig");
    _ = @import("tests_stress.zig");
    _ = @import("tests_real.zig");
    _ = @import("tests_fuzz.zig");
}

const Ar = std.heap.ArenaAllocator;

test "tokenizer: table" {
    var ar = Ar.init(std.testing.allocator);
    defer ar.deinit();
    const K = tk.Kind;
    const Case = struct { src: []const u8, kinds: []const K };
    const cases = [_]Case{
        .{ .src = "a b", .kinds = &.{ .ident, .whitespace, .ident } },
        .{ .src = "--x:1px", .kinds = &.{ .ident, .colon, .dimension } },
        .{ .src = "calc(1%)", .kinds = &.{ .function, .percentage, .rparen } },
        .{ .src = "#a #1", .kinds = &.{ .hash, .whitespace, .hash } },
        .{ .src = "@media", .kinds = &.{.at_keyword} },
        .{ .src = "url(a.png) url( 'b' )", .kinds = &.{ .url, .whitespace, .function, .whitespace, .string, .whitespace, .rparen } },
        .{ .src = "url(a b)", .kinds = &.{.bad_url} },
        .{ .src = "'a\nb'", .kinds = &.{ .bad_string, .whitespace, .ident, .string } },
        .{ .src = "/* c */x/**/y", .kinds = &.{ .ident, .ident } },
        .{ .src = "1 +2 -3 .5 1e3 1.5em", .kinds = &.{ .number, .whitespace, .number, .whitespace, .number, .whitespace, .number, .whitespace, .number, .whitespace, .dimension } },
        .{ .src = "<!-- -->", .kinds = &.{ .cdo, .whitespace, .cdc } },
        .{ .src = "a\\:b", .kinds = &.{.ident} },
        .{ .src = "!", .kinds = &.{.delim} },
    };
    for (cases) |c| {
        var t: tk.Tokenizer = .{ .arena = ar.allocator(), .src = c.src };
        for (c.kinds) |want| {
            const got = try t.next();
            try expect(got.kind == want);
        }
        try expect((try t.next()).kind == .eof);
    }
    var e: tk.Tokenizer = .{ .arena = ar.allocator(), .src = "a\\:b\\20 c 'x\\41 y' 1e2" };
    try eq("a:b c", (try e.next()).text);
    _ = try e.next();
    try eq("xAy", (try e.next()).text);
    _ = try e.next();
    try expect((try e.next()).num == 100);
}

test "parser: rules, recovery, at-rules" {
    var ar = Ar.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\@charset "utf-8";
        \\@import url("a.css") screen;
        \\@import 'b.css' layer(x);
        \\/* comment */
        \\a { color: red; garbage; : ; width: 1px }
        \\b { nonsense: 1; color: blue !important; color: rgb(1 2 3) ! important }
        \\c d:unknown-thing { color: red }
        \\e, f::-moz-whatever { color: red }
        \\@font-face { font-family: x; src: url(y.woff) }
        \\@keyframes spin { from { top: 0 } to { top: 1px } }
        \\@page { margin: 1in }
        \\@unknown foo { a { color: red } }
        \\@unknown bar;
        \\g { color: red; ; ; }
        \\h { background: url(i.png) }
        \\j { color: red
    ;
    const s = try css.parseSheet(a, src, "https://x.com/s/main.css");
    try expect(s.imports.len == 2);
    try eq("https://x.com/s/a.css", s.imports[0].url);
    try expect(s.imports[0].media != null);
    try eq("https://x.com/s/b.css", s.imports[1].url);
    try eq("x", s.imports[1].layer);
    try expect(s.font_faces.len == 1);
    try expect(s.keyframes.len == 1);
    try eq("spin", s.keyframes[0].name);
    try expect(s.keyframes[0].frames.len == 2);
    try expect(s.keyframes[0].frames[1].at == 1);
    // a, b, g, h, j survive; the two with bad selectors don't.
    try expect(s.rules.len == 5);
    try expect(s.rules[0].decls.items.len == 2);
    const b_rule = s.rules[1].decls;
    try expect(b_rule.items.len == 2);
    try expect(b_rule.items[0].important);
    try expect(b_rule.has_important);
    try eq("https://x.com/s/i.png", s.rules[3].decls.items[0].value[0].text);
}

test "parser: @media nesting, @supports, @layer order, nesting" {
    var ar = Ar.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try css.parseSheet(a,
        \\@media (min-width: 100px) { a { top: 0 } @media print { b { top: 0 } } }
        \\@supports (display: grid) { c { top: 0 } }
        \\@supports (display: nonsense) { d { top: 0 } }
        \\@supports not (nonsense: 1) { e { top: 0 } }
        \\@supports selector(:has(a)) { f { top: 0 } }
        \\@layer one, two;
        \\@layer two { g { top: 0 } }
        \\@layer one { @layer inner { h { top: 0 } } }
        \\@layer { i { top: 0 } }
        \\j { top: 0; & k { top: 1px } left: 0; @media (min-width: 1px) { top: 2px } }
    , "");
    // a, b, c, e, f, g, h, i, j-first, k, j-left, j-media
    try expect(s.rules.len == 12);
    try expect(s.conds.len == 3);
    const v: media.Viewport = .{ .width = 500, .height = 500 };
    try expect(s.rules[0].cond.?.matches(v));
    try expect(!s.rules[1].cond.?.matches(v));
    try eq("two", s.rules[5].layer);
    try eq("one.inner", s.rules[6].layer);
    try expect(s.rules[7].layer.len > 0);
    try eq("one", s.layers[0]);
    try eq("two", s.layers[1]);
}

test "sheet media" {
    var ar = Ar.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v: media.Viewport = .{ .width = 500, .height = 500 };
    try expect(!(try css.parseSheetMedia(a, "a{}", "", "print")).active(v));
    try expect((try css.parseSheetMedia(a, "a{}", "", "screen and (min-width: 100px)")).active(v));
    try expect((try css.parseSheetMedia(a, "a{}", "", null)).active(v));
}

test "custom property values keep their blocks and case" {
    var ar = Ar.init(std.testing.allocator);
    defer ar.deinit();
    const d = try css.parseDeclarations(ar.allocator(), "--Thing: { a: b }; --y:; color: var(--Thing, red)");
    try expect(d.items.len == 3);
    try eq("--Thing", d.items[0].name);
    try expect(d.items[0].value.len > 3);
    try eq("--y", d.items[1].name);
    try expect(d.items[1].value.len == 0);
    try expect(d.items[2].has_var);
}

const SelCase = struct { sel: []const u8, id: []const u8, want: bool };

const selector_doc =
    \\<!doctype html><html lang="en-GB"><body>
    \\<div id="a" class="x y" title="Hello World" data-n="abc def" lang="fr">
    \\  <p id="p1" class="one">first</p>
    \\  <p id="p2">second</p>
    \\  <span id="s1"></span>
    \\  <p id="p3"><b id="b1">bold</b></p>
    \\  <span id="s2">t</span>
    \\</div>
    \\<ul id="u"><li id="l1"></li><li id="l2"></li><li id="l3"></li><li id="l4"></li><li id="l5"></li></ul>
    \\<a id="link" href="/x">x</a><a id="anchor">y</a>
    \\<form id="f"><input id="i1" required placeholder="p"><input id="i2" disabled value="v" placeholder="p">
    \\<input id="c1" type="checkbox" checked><input id="c2" type="CHECKBOX"><select id="sel"><option id="o1" selected>a</option></select>
    \\<fieldset disabled><input id="i3"><legend><input id="i4"></legend></fieldset></form>
    \\<section id="only"><i id="i-only"></i></section>
    \\<svg id="svg"><linearGradient id="lg"></linearGradient></svg>
    \\</body></html>
;

test "selectors: each kind" {
    var ar = Ar.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const doc = try dom.Document.create(a);
    try html.parseDocument(doc, selector_doc);
    const cases = [_]SelCase{
        .{ .sel = "div", .id = "a", .want = true },
        .{ .sel = "DIV", .id = "a", .want = true },
        .{ .sel = "p", .id = "a", .want = false },
        .{ .sel = "*", .id = "a", .want = true },
        .{ .sel = "#a", .id = "a", .want = true },
        .{ .sel = ".x", .id = "a", .want = true },
        .{ .sel = ".y.x", .id = "a", .want = true },
        .{ .sel = ".z", .id = "a", .want = false },
        .{ .sel = "[title]", .id = "a", .want = true },
        .{ .sel = "[title='Hello World']", .id = "a", .want = true },
        .{ .sel = "[title='hello world']", .id = "a", .want = false },
        .{ .sel = "[title='hello world' i]", .id = "a", .want = true },
        .{ .sel = "[title^=Hello]", .id = "a", .want = true },
        .{ .sel = "[title$=World]", .id = "a", .want = true },
        .{ .sel = "[title*='o W']", .id = "a", .want = true },
        .{ .sel = "[data-n~=def]", .id = "a", .want = true },
        .{ .sel = "[data-n~=de]", .id = "a", .want = false },
        .{ .sel = "[lang|=fr]", .id = "a", .want = true },
        .{ .sel = "html[lang|=en]", .id = "a", .want = false },
        .{ .sel = "div p", .id = "b1", .want = false },
        .{ .sel = "div b", .id = "b1", .want = true },
        .{ .sel = "div > b", .id = "b1", .want = false },
        .{ .sel = "p > b", .id = "b1", .want = true },
        .{ .sel = "#p1 + p", .id = "p2", .want = true },
        .{ .sel = "#p1 + span", .id = "s1", .want = false },
        .{ .sel = "#p1 ~ span", .id = "s1", .want = true },
        .{ .sel = "a, #p1", .id = "p1", .want = true },
        .{ .sel = ":not(p)", .id = "p1", .want = false },
        .{ .sel = ":not(div, span)", .id = "p1", .want = true },
        .{ .sel = ":is(p, div)", .id = "p1", .want = true },
        .{ .sel = ":where(.one) ", .id = "p1", .want = true },
        .{ .sel = ":is(:unknown-forgiven, p)", .id = "p1", .want = true },
        .{ .sel = "div:has(b)", .id = "a", .want = true },
        .{ .sel = "div:has(> b)", .id = "a", .want = false },
        .{ .sel = "div:has(> p b)", .id = "a", .want = true },
        .{ .sel = "p:has(+ span)", .id = "p2", .want = true },
        .{ .sel = "p:has(~ #s2)", .id = "p1", .want = true },
        .{ .sel = "p:has(+ div)", .id = "p2", .want = false },
        .{ .sel = ":root", .id = "a", .want = false },
        .{ .sel = "body > :first-child", .id = "a", .want = true },
        .{ .sel = ":empty", .id = "s1", .want = true },
        .{ .sel = ":empty", .id = "s2", .want = false },
        .{ .sel = ":first-child", .id = "p1", .want = true },
        .{ .sel = ":last-child", .id = "s2", .want = true },
        .{ .sel = ":only-child", .id = "i-only", .want = true },
        .{ .sel = ":only-child", .id = "p1", .want = false },
        .{ .sel = "span:first-of-type", .id = "s1", .want = true },
        .{ .sel = "span:last-of-type", .id = "s2", .want = true },
        .{ .sel = "p:first-of-type", .id = "p2", .want = false },
        .{ .sel = "li:nth-child(2)", .id = "l2", .want = true },
        .{ .sel = "li:nth-child(odd)", .id = "l3", .want = true },
        .{ .sel = "li:nth-child(even)", .id = "l3", .want = false },
        .{ .sel = "li:nth-child(2n+1)", .id = "l5", .want = true },
        .{ .sel = "li:nth-child(2n + 1)", .id = "l4", .want = false },
        .{ .sel = "li:nth-child(-n+2)", .id = "l2", .want = true },
        .{ .sel = "li:nth-child(-n+2)", .id = "l3", .want = false },
        .{ .sel = "li:nth-child(n+3)", .id = "l3", .want = true },
        .{ .sel = "li:nth-child(3n-1)", .id = "l5", .want = true },
        .{ .sel = "li:nth-last-child(1)", .id = "l5", .want = true },
        .{ .sel = "li:nth-last-child(2n)", .id = "l4", .want = true },
        .{ .sel = "p:nth-of-type(2)", .id = "p2", .want = true },
        .{ .sel = "p:nth-of-type(3)", .id = "p3", .want = true },
        .{ .sel = "p:nth-last-of-type(1)", .id = "p3", .want = true },
        .{ .sel = ":nth-child(2 of li)", .id = "l2", .want = true },
        .{ .sel = ":link", .id = "link", .want = true },
        .{ .sel = ":any-link", .id = "anchor", .want = false },
        .{ .sel = ":visited", .id = "link", .want = false },
        .{ .sel = ":checked", .id = "c1", .want = true },
        .{ .sel = ":checked", .id = "c2", .want = false },
        .{ .sel = ":checked", .id = "o1", .want = true },
        .{ .sel = ":disabled", .id = "i2", .want = true },
        .{ .sel = ":disabled", .id = "i1", .want = false },
        .{ .sel = ":enabled", .id = "i1", .want = true },
        .{ .sel = ":disabled", .id = "i3", .want = true },
        .{ .sel = ":disabled", .id = "i4", .want = false },
        .{ .sel = ":required", .id = "i1", .want = true },
        .{ .sel = ":optional", .id = "i2", .want = true },
        .{ .sel = ":placeholder-shown", .id = "i1", .want = true },
        .{ .sel = ":placeholder-shown", .id = "i2", .want = false },
        .{ .sel = "[type=checkbox]", .id = "c2", .want = true },
        .{ .sel = ":lang(fr)", .id = "p1", .want = true },
        .{ .sel = ":lang(en)", .id = "l1", .want = true },
        .{ .sel = ":lang(de)", .id = "l1", .want = false },
        .{ .sel = "lineargradient", .id = "lg", .want = true },
        .{ .sel = "svg > *", .id = "lg", .want = true },
    };
    for (cases) |c| {
        const n = doc.getElementById(c.id) orelse return error.Missing;
        const got = css.matchesSelector(n, c.sel, a) catch |e| {
            std.debug.print("selector failed to parse: {s}\n", .{c.sel});
            return e;
        };
        if (got != c.want) {
            std.debug.print("{s} on #{s}: got {}\n", .{ c.sel, c.id, got });
            return error.TestUnexpectedResult;
        }
    }
    const root = doc.documentElement().?;
    try expect(try css.matchesSelector(root, ":root", a));
    try expect(try css.matchesSelector(root, ":lang(en)", a));
}

test "selectors: state pseudo-classes and invalid ones" {
    var ar = Ar.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const doc = try dom.Document.create(a);
    try html.parseDocument(doc, selector_doc);
    const b = doc.getElementById("b1").?;
    const div = doc.getElementById("a").?;
    try expect(!try css.matchesSelector(b, ":hover", a));
    doc.hover = b;
    try expect(try css.matchesSelector(b, ":hover", a));
    try expect(try css.matchesSelector(div, ":hover", a));
    doc.focus = b;
    try expect(try css.matchesSelector(b, ":focus", a));
    try expect(try css.matchesSelector(b, ":focus-visible", a));
    try expect(!try css.matchesSelector(div, ":focus", a));
    try expect(try css.matchesSelector(div, ":focus-within", a));
    doc.active = b;
    try expect(try css.matchesSelector(div, ":active", a));

    const bad = [_][]const u8{ "", ":nonsense", "a:nonsense", "::nonsense", "a,", ",a", "a >", "[a", "[a=]", ":nth-child(x)", ":not()", "..a", "#1", "a::before::after b", "a b::before c", "> a" };
    for (bad) |s| {
        if (css.matchesSelector(div, s, a)) |_| {
            std.debug.print("should not parse: {s}\n", .{s});
            return error.TestUnexpectedResult;
        } else |e| try expect(e == error.InvalidSelector);
    }
    const good = [_][]const u8{ "a::before", "a::after", "::before", "a:before", "::marker", "::selection", "::placeholder", "::-webkit-scrollbar", "a:-webkit-autofill", "*|a", "*", "a|b", ":is()", ":where(:nonsense)" };
    for (good) |s| _ = try css.matchesSelector(div, s, a);
}

fn spec(a: std.mem.Allocator, text: []const u8) !u32 {
    const list = (try selectors.parseText(a, text)) orelse return error.Bad;
    return list[0].specificity;
}

test "selectors: specificity" {
    var ar = Ar.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const Case = struct { s: []const u8, want: u32 };
    const v = struct {
        fn f(x: u32, y: u32, z: u32) u32 {
            return x << 16 | y << 8 | z;
        }
    }.f;
    const cases = [_]Case{
        .{ .s = "*", .want = v(0, 0, 0) },
        .{ .s = "li", .want = v(0, 0, 1) },
        .{ .s = "ul li", .want = v(0, 0, 2) },
        .{ .s = "ul > li + li", .want = v(0, 0, 3) },
        .{ .s = ".a", .want = v(0, 1, 0) },
        .{ .s = "[a]", .want = v(0, 1, 0) },
        .{ .s = ":hover", .want = v(0, 1, 0) },
        .{ .s = "#a", .want = v(1, 0, 0) },
        .{ .s = "#a .b c", .want = v(1, 1, 1) },
        .{ .s = "a::before", .want = v(0, 0, 2) },
        .{ .s = ":is(#a, b)", .want = v(1, 0, 0) },
        .{ .s = ":where(#a, b)", .want = v(0, 0, 0) },
        .{ .s = ":not(#a, .b)", .want = v(1, 0, 0) },
        .{ .s = ":has(.a, b)", .want = v(0, 1, 0) },
        .{ .s = ":nth-child(2)", .want = v(0, 1, 0) },
        .{ .s = ":nth-child(2 of #a)", .want = v(1, 1, 0) },
        .{ .s = ":first-child", .want = v(0, 1, 0) },
    };
    for (cases) |c| try expect(try spec(a, c.s) == c.want);
}

test "query API" {
    var ar = Ar.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const doc = try dom.Document.create(a);
    try html.parseDocument(doc, selector_doc);
    const div = doc.getElementById("a").?;
    try expect((try css.querySelector(doc.node, "#p2", a)) == doc.getElementById("p2"));
    try expect((try css.querySelector(div, "li", a)) == null);
    try expect((try css.querySelector(div, ":scope > p", a)) == doc.getElementById("p1"));
    var list: std.ArrayList(*dom.Node) = .empty;
    try css.querySelectorAll(doc.node, "li:nth-child(odd)", a, &list);
    try expect(list.items.len == 3);
    try expect(list.items[1] == doc.getElementById("l3"));
    const b = doc.getElementById("b1").?;
    try expect((try css.closest(b, "div", a)) == div);
    try expect((try css.closest(b, "b", a)) == b);
    try expect((try css.closest(b, "ul", a)) == null);
}

fn mediaMatches(a: std.mem.Allocator, q: []const u8, v: media.Viewport) !bool {
    const l = try media.parseText(a, q);
    return l.matches(v);
}

test "media queries" {
    var ar = Ar.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const Case = struct { q: []const u8, want: bool };
    const v: media.Viewport = .{ .width = 800, .height = 600 };
    const cases = [_]Case{
        .{ .q = "screen", .want = true },
        .{ .q = "all", .want = true },
        .{ .q = "print", .want = false },
        .{ .q = "not print", .want = true },
        .{ .q = "not screen", .want = false },
        .{ .q = "only screen", .want = true },
        .{ .q = "print, screen", .want = true },
        .{ .q = "(min-width: 800px)", .want = true },
        .{ .q = "(min-width: 801px)", .want = false },
        .{ .q = "(max-width: 50em)", .want = true },
        .{ .q = "(width: 800px)", .want = true },
        .{ .q = "(height > 500px)", .want = true },
        .{ .q = "(height >= 700px)", .want = false },
        .{ .q = "(width <= 800px)", .want = true },
        .{ .q = "(400px <= width <= 900px)", .want = true },
        .{ .q = "(400px <= width <= 700px)", .want = false },
        .{ .q = "(900px > width)", .want = true },
        .{ .q = "screen and (min-width: 100px)", .want = true },
        .{ .q = "print and (min-width: 100px)", .want = false },
        .{ .q = "not print and (min-width: 9000px)", .want = true },
        .{ .q = "(min-width: 100px) and (max-width: 200px)", .want = false },
        .{ .q = "(min-width: 9000px) or (max-width: 900px)", .want = true },
        .{ .q = "not (min-width: 9000px)", .want = true },
        .{ .q = "((min-width: 100px))", .want = true },
        .{ .q = "(prefers-color-scheme: dark)", .want = false },
        .{ .q = "(prefers-color-scheme: light)", .want = true },
        .{ .q = "(prefers-reduced-motion: reduce)", .want = false },
        .{ .q = "(prefers-reduced-motion: no-preference)", .want = true },
        .{ .q = "(orientation: landscape)", .want = true },
        .{ .q = "(aspect-ratio: 4/3)", .want = true },
        .{ .q = "(hover: hover)", .want = true },
        .{ .q = "(pointer: fine)", .want = true },
        .{ .q = "(nonsense: 1)", .want = false },
        .{ .q = "garbage(", .want = false },
        .{ .q = "", .want = true },
    };
    for (cases) |c| {
        const got = try mediaMatches(a, c.q, v);
        if (got != c.want) {
            std.debug.print("{s}: got {}\n", .{ c.q, got });
            return error.TestUnexpectedResult;
        }
    }
    try expect(try mediaMatches(a, "(prefers-color-scheme: dark)", .{ .width = 1, .height = 1, .dark = true }));
}

test "garbage stylesheets parse without crashing" {
    const nasty = [_][]const u8{
        "",         "{",           "}",           "{{{{",                             "}}}}",             "a{",              "a{b",                       "a{b:",           "a{b:c",              "@",             "@media",            "@media{",         "@media (",     "@import",                                "@import url(",
        "/*",       "\"",          "'",           "url(",                             "url(a",            "\\",              "a\\",                       "#",              ".",                  ":",             ";;;",               "a{;;;}",          "a{:}",         "a{b:{}}",                                "a{b:(}",
        "a{--x:{}", "a{--x:}",     "!important",  "a{color:red!important!important}", "@layer",           "@layer a.b.c,d;", "@layer {",                  "@supports",      "@supports (",        "@supports not", "@keyframes",        "a{&{&{&{&{}}}}}", "&{color:red}", "a{@media print{@media screen{b{c:d}}}}", "<!--a{}-->",
        "\x00",     "a\x00b{c:d}", "@font-face{", "a,b,{c:d}",                        ":is(:is(:is(:is(", "\xFF\xFE{}",      "@media (min-width: ){a{}}", "a{width:calc(}", "a{width:calc(1px+}", "a{color:rgb(}", "a{background:url(",
    };
    for (nasty) |s| {
        var ar = Ar.init(std.testing.allocator);
        defer ar.deinit();
        _ = try css.parseSheet(ar.allocator(), s, "");
        _ = try css.parseDeclarations(ar.allocator(), s);
        _ = try selectors.parseText(ar.allocator(), s);
    }
    // Deep nesting of blocks and of selector functions.
    var ar = Ar.init(std.testing.allocator);
    defer ar.deinit();
    var src: std.ArrayList(u8) = .empty;
    for (0..2000) |_| try src.appendSlice(ar.allocator(), "a{");
    _ = try css.parseSheet(ar.allocator(), src.items, "");
    src.clearRetainingCapacity();
    for (0..2000) |_| try src.appendSlice(ar.allocator(), ":is(");
    _ = try selectors.parseText(ar.allocator(), src.items);
    src.clearRetainingCapacity();
    for (0..2000) |_| try src.appendSlice(ar.allocator(), "@media print{");
    _ = try css.parseSheet(ar.allocator(), src.items, "");
}
