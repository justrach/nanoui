//! HTML parser tests: tree dumps compared with what the WHATWG algorithm
//! gives, entities, encodings, and garbage that must neither crash nor hang.
const std = @import("std");
const dom = @import("../dom.zig");
const html = @import("html.zig");
const entities = @import("entities.zig");

const expect = std.testing.expect;
const eq = std.testing.expectEqualStrings;

const Fix = struct {
    arena: std.heap.ArenaAllocator,
    doc: *dom.Document,

    fn parse(src: []const u8) !*Fix {
        const f = try std.testing.allocator.create(Fix);
        f.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        f.doc = try dom.Document.create(f.arena.allocator());
        try html.parseDocument(f.doc, src);
        return f;
    }

    fn done(f: *Fix) void {
        f.arena.deinit();
        std.testing.allocator.destroy(f);
    }

    /// The body's markup.
    fn body(f: *Fix) ![]u8 {
        const b = f.doc.body() orelse return error.NoBody;
        return html.serialize(f.arena.allocator(), b, false);
    }

    /// The whole document's markup.
    fn all(f: *Fix) ![]u8 {
        return html.serialize(f.arena.allocator(), f.doc.node, false);
    }
};

const Case = struct { src: []const u8, want: []const u8 };

fn bodies(cases: []const Case) !void {
    for (cases) |c| {
        var src: [512]u8 = undefined;
        const f = try Fix.parse(try std.fmt.bufPrint(&src, "<!doctype html><body>{s}", .{c.src}));
        defer f.done();
        const got = try f.body();
        std.testing.expectEqualStrings(c.want, got) catch |e| {
            std.debug.print("input: {s}\n", .{c.src});
            return e;
        };
    }
}

test "document skeleton and implied elements" {
    const f = try Fix.parse("<!DOCTYPE html><title>t</title><p>x");
    defer f.done();
    try eq("<!DOCTYPE html><html><head><title>t</title></head><body><p>x</p></body></html>", try f.all());
    try expect(!f.doc.quirks);
    try expect(f.doc.head() != null);
    const g = try Fix.parse("hello");
    defer g.done();
    try expect(g.doc.quirks);
    try eq("<html><head></head><body>hello</body></html>", try g.all());
}

test "doctype quirks detection" {
    const Q = struct { src: []const u8, quirks: bool };
    const cases = [_]Q{
        .{ .src = "<!doctype html>", .quirks = false },
        .{ .src = "<!DOCTYPE HTML>", .quirks = false },
        .{ .src = "<!DOCTYPE html PUBLIC \"-//W3C//DTD HTML 4.01//EN\" \"http://www.w3.org/TR/html4/strict.dtd\">", .quirks = false },
        .{ .src = "<!DOCTYPE html PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\">", .quirks = true },
        .{ .src = "<!DOCTYPE html PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\" \"x\">", .quirks = false },
        .{ .src = "<!DOCTYPE html PUBLIC \"-//IETF//DTD HTML 2.0//EN\">", .quirks = true },
        .{ .src = "<!doctype foo>", .quirks = true },
        .{ .src = "<!doctype>", .quirks = true },
        .{ .src = "<!doctype html bogus>", .quirks = true },
        .{ .src = "<html>", .quirks = true },
    };
    for (cases) |c| {
        const f = try Fix.parse(c.src);
        defer f.done();
        try expect(f.doc.quirks == c.quirks);
    }
}

test "tokenizer: attributes" {
    try bodies(&.{
        .{ .src = "<div a=1 B='2' c=\"3\" d e = 5 a=9></div>", .want = "<div a=\"1\" b=\"2\" c=\"3\" d=\"\" e=\"5\"></div>" },
        .{ .src = "<a href=/x/y/>k</a>", .want = "<a href=\"/x/y/\">k</a>" },
        .{ .src = "<div =x></div>", .want = "<div =x=\"\"></div>" },
        .{ .src = "<div a=\"x&amp;y&lt;\"></div>", .want = "<div a=\"x&amp;y&lt;\"></div>" },
        .{ .src = "<a href=\"?a=1&copy=2\">k</a>", .want = "<a href=\"?a=1&amp;copy=2\">k</a>" },
        .{ .src = "<div/x=1></div>", .want = "<div x=\"1\"></div>" },
    });
}

test "tokenizer: comments and bogus comments" {
    try bodies(&.{
        .{ .src = "<!--a-->", .want = "<!--a-->" },
        .{ .src = "<!-->x", .want = "<!---->x" },
        .{ .src = "<!--->x", .want = "<!---->x" },
        .{ .src = "<!---->x", .want = "<!---->x" },
        .{ .src = "<!--a--!>x", .want = "<!--a-->x" },
        .{ .src = "<!--a", .want = "<!--a-->" },
        .{ .src = "<?php x?>y", .want = "<!--?php x?-->y" },
        .{ .src = "<!x>y", .want = "<!--x-->y" },
        .{ .src = "</ a>y", .want = "<!-- a-->y" },
        .{ .src = "</>y", .want = "y" },
    });
}

test "tokenizer: rawtext, rcdata, script data" {
    try bodies(&.{
        .{ .src = "<style>a<b&amp;</style>", .want = "<style>a<b&amp;</style>" },
        .{ .src = "<textarea>a<b>&amp;</textarea>", .want = "<textarea>a&lt;b&gt;&amp;</textarea>" },
        .{ .src = "<textarea>\nx</textarea>", .want = "<textarea>x</textarea>" },
        .{ .src = "<script>a</scriptx>b</SCRIPT >c", .want = "<script>a</scriptx>b</script>c" },
        .{ .src = "<script><!-- <script>x</script> y --></script>z", .want = "<script><!-- <script>x</script> y --></script>z" },
        .{ .src = "<script><!-- x</script>z", .want = "<script><!-- x</script>z" },
        .{ .src = "<title>a<b></title>", .want = "<title>a&lt;b&gt;</title>" },
        .{ .src = "<plaintext>a</plaintext><b>", .want = "<plaintext>a</plaintext><b></plaintext>" },
        .{ .src = "<xmp><b>x</xmp>", .want = "<xmp><b>x</xmp>" },
        .{ .src = "<noscript><b>x</b></noscript>", .want = "<noscript><b>x</b></noscript>" },
    });
}

test "tokenizer: character references" {
    try bodies(&.{
        .{ .src = "&amp;&lt;&gt;", .want = "&amp;&lt;&gt;" },
        .{ .src = "&copy;&mdash;&hellip;", .want = "©—…" },
        .{ .src = "&#65;&#x41;&#X41", .want = "AAA" },
        .{ .src = "&#128;", .want = "€" },
        .{ .src = "&#0;&#xD800;&#x110000;", .want = "\u{FFFD}\u{FFFD}\u{FFFD}" },
        .{ .src = "&amp x&ampx&copy1", .want = "&amp; x&amp;x©1" },
        .{ .src = "&notit;&notin;", .want = "¬it;∉" },
        .{ .src = "&nosuch; &", .want = "&amp;nosuch; &amp;" },
        .{ .src = "&nbsp;", .want = "&nbsp;" },
    });
    try expect(entities.count() > 300);
    try expect(entities.lookup("thetasym").? == 977);
    try expect(entities.lookup("diams").? == 9830);
}

test "tokenizer: newlines normalize" {
    try bodies(&.{.{ .src = "a\r\nb\rc", .want = "a\nb\nc" }});
}

test "tree: implied end tags" {
    try bodies(&.{
        .{ .src = "<p>a<p>b", .want = "<p>a</p><p>b</p>" },
        .{ .src = "<p>a<div>b</div>", .want = "<p>a</p><div>b</div>" },
        .{ .src = "<ul><li>a<li>b</ul>", .want = "<ul><li>a</li><li>b</li></ul>" },
        .{ .src = "<dl><dt>a<dd>b<dt>c</dl>", .want = "<dl><dt>a</dt><dd>b</dd><dt>c</dt></dl>" },
        .{ .src = "</p>", .want = "<p></p>" },
        .{ .src = "<h1>a<h2>b</h1>c", .want = "<h1>a</h1><h2>b</h2>c" },
        .{ .src = "<select><option>a<option>b</select>", .want = "<select><option>a</option><option>b</option></select>" },
        .{ .src = "<button>a<button>b", .want = "<button>a</button><button>b</button>" },
        .{ .src = "<ruby>a<rt>b<rp>c</ruby>", .want = "<ruby>a<rt>b</rt><rp>c</rp></ruby>" },
        .{ .src = "<br/></br>", .want = "<br><br>" },
        .{ .src = "<image src=x>", .want = "<img src=\"x\">" },
        .{ .src = "<pre>\nx</pre>", .want = "<pre>x</pre>" },
    });
}

test "tree: adoption agency" {
    try bodies(&.{
        .{ .src = "<b>1<p>2</b>3</p>", .want = "<b>1</b><p><b>2</b>3</p>" },
        .{ .src = "<a><b>1<p>2</a>3</p>", .want = "<a><b>1</b></a><b><p><a>2</a>3</p></b>" },
        .{ .src = "<a href=1>x<a href=2>y</a>", .want = "<a href=\"1\">x</a><a href=\"2\">y</a>" },
        .{ .src = "<b><i>x</b>y</i>z", .want = "<b><i>x</i></b><i>y</i>z" },
        .{ .src = "<p><b>x<p>y", .want = "<p><b>x</b></p><p><b>y</b></p>" },
        .{ .src = "<p><b><b><b><b>x<p>y", .want = "<p><b><b><b><b>x</b></b></b></b></p><p><b><b><b>y</b></b></b></p>" },
        .{ .src = "<nobr>a<nobr>b</nobr>", .want = "<nobr>a</nobr><nobr>b</nobr>" },
        .{ .src = "<i><div>x</i>y</div>", .want = "<i></i><div><i>x</i>y</div>" },
        .{ .src = "</b>x", .want = "x" },
    });
}

test "tree: tables and foster parenting" {
    try bodies(&.{
        .{ .src = "<table><tr><td>a<td>b<tr><td>c</table>", .want = "<table><tbody><tr><td>a</td><td>b</td></tr><tr><td>c</td></tr></tbody></table>" },
        .{ .src = "<table>x<tr><td>a</table>", .want = "x<table><tbody><tr><td>a</td></tr></tbody></table>" },
        .{ .src = "<table><div>x</div><tr><td>a</table>", .want = "<div>x</div><table><tbody><tr><td>a</td></tr></tbody></table>" },
        .{ .src = "<table><b>x<tr><td>y</td></tr>z</table>", .want = "<b>x</b><b>z</b><table><tbody><tr><td>y</td></tr></tbody></table>" },
        .{ .src = "<table><b>x<tr><td>y</td></tr></b>z</table>", .want = "<b>x</b>z<table><tbody><tr><td>y</td></tr></tbody></table>" },
        .{ .src = "<table> <tr> <td>a</td> </tr> </table>", .want = "<table> <tbody><tr> <td>a</td> </tr> </tbody></table>" },
        .{ .src = "<table><caption>c<tr><td>a</table>", .want = "<table><caption>c</caption><tbody><tr><td>a</td></tr></tbody></table>" },
        .{ .src = "<table><col><tr></table>", .want = "<table><colgroup><col></colgroup><tbody><tr></tr></tbody></table>" },
        .{ .src = "<table><thead><tr><th>h</thead><tfoot><tr><td>f</table>", .want = "<table><thead><tr><th>h</th></tr></thead><tfoot><tr><td>f</td></tr></tfoot></table>" },
        .{ .src = "<table><input type=hidden><input></table>", .want = "<input><table><input type=\"hidden\"></table>" },
        .{ .src = "<table><form><tr></table>", .want = "<table><form></form><tbody><tr></tr></tbody></table>" },
        .{ .src = "<table><td><table><td>x</table>y</table>", .want = "<table><tbody><tr><td><table><tbody><tr><td>x</td></tr></tbody></table>y</td></tr></tbody></table>" },
        .{ .src = "<table><tr><td><select><option>a<td>b</table>", .want = "<table><tbody><tr><td><select><option>a</option></select></td><td>b</td></tr></tbody></table>" },
        .{ .src = "<td>a</td>", .want = "a" },
        .{ .src = "<p><table><tr><td>x</table>", .want = "<p></p><table><tbody><tr><td>x</td></tr></tbody></table>" },
    });
}

test "tree: template contents are children" {
    try bodies(&.{
        .{ .src = "<template><td>a</td></template>", .want = "<template><td>a</td></template>" },
        .{ .src = "<template><tr><td>a</td></tr></template>", .want = "<template><tr><td>a</td></tr></template>" },
        .{ .src = "<template><div>x</div>", .want = "<template><div>x</div></template>" },
        .{ .src = "<table><template><tr><td>a</template></table>", .want = "<table><template><tr><td>a</td></tr></template></table>" },
    });
}

test "tree: foreign content" {
    try bodies(&.{
        .{ .src = "<svg viewbox='0 0 1 1'><lineargradient/><path d=x /></svg>", .want = "<svg viewBox=\"0 0 1 1\"><linearGradient></linearGradient><path d=\"x\"></path></svg>" },
        .{ .src = "<svg><foreignobject><div>x</div></foreignobject></svg>", .want = "<svg><foreignObject><div>x</div></foreignObject></svg>" },
        .{ .src = "<svg><p>x", .want = "<svg></svg><p>x</p>" },
        .{ .src = "<svg><title><b>x</b></title></svg>", .want = "<svg><title><b>x</b></title></svg>" },
        .{ .src = "<math><mi>x</mi><mo/></math>", .want = "<math><mi>x</mi><mo></mo></math>" },
        .{ .src = "<svg><![CDATA[a<b]]></svg>", .want = "<svg>a&lt;b</svg>" },
        .{ .src = "<![CDATA[x]]>", .want = "<!--[CDATA[x]]-->" },
        .{ .src = "<svg/>x", .want = "<svg></svg>x" },
        .{ .src = "<math><annotation-xml encoding='text/html'><div>x</div></annotation-xml></math>", .want = "<math><annotation-xml encoding=\"text/html\"><div>x</div></annotation-xml></math>" },
    });
    const f = try Fix.parse("<svg><circle/></svg><math><mi></mi></math>");
    defer f.done();
    const b = f.doc.body().?;
    try expect(b.first_child.?.ns == .svg);
    try expect(b.first_child.?.first_child.?.ns == .svg);
    try expect(b.last_child.?.ns == .mathml);
    try expect(b.last_child.?.first_child.?.ns == .mathml);
}

test "tree: frameset is tolerated" {
    const f = try Fix.parse("<html><frameset><frame src=a><frame src=b></frameset></html>");
    defer f.done();
    try expect(f.doc.body().?.isTag("frameset"));
    try expect(f.doc.body().?.firstElementChild().?.isTag("frame"));
}

test "tree: head content and stray tags" {
    const f = try Fix.parse("<head><meta charset=x></head> <link rel=a><body class=a><body id=b>x");
    defer f.done();
    try eq("<html><head><meta charset=\"x\"><link rel=\"a\"></head> <body class=\"a\" id=\"b\">x</body></html>", try f.all());
}

test "fragments" {
    const f = try Fix.parse("<div id=d></div>");
    defer f.done();
    const d = f.doc.getElementById("d").?;
    const a = f.arena.allocator();
    const frag = try html.parseFragment(f.doc, d, "<p>a<b>c</p>d");
    try expect(frag.kind == .fragment);
    try eq("<p>a<b>c</b></p><b>d</b>", try html.serialize(a, frag, false));

    const table = try f.doc.createElement("table");
    const rows = try html.parseFragment(f.doc, table, "<tr><td>x");
    try eq("<tbody><tr><td>x</td></tr></tbody>", try html.serialize(a, rows, false));

    const tr = try f.doc.createElement("tr");
    const cells = try html.parseFragment(f.doc, tr, "<td>x</td>");
    try eq("<td>x</td>", try html.serialize(a, cells, false));

    const ta = try f.doc.createElement("textarea");
    const raw = try html.parseFragment(f.doc, ta, "<b>x</b>");
    try eq("&lt;b&gt;x&lt;/b&gt;", try html.serialize(a, raw, false));

    const svg = try f.doc.createElementNs("svg", .svg);
    const inner = try html.parseFragment(f.doc, svg, "<circle/>");
    try expect(inner.first_child.?.ns == .svg);

    const empty = try html.parseFragment(f.doc, d, "");
    try expect(empty.first_child == null);
}

test "serialization escapes and void elements" {
    const f = try Fix.parse("<!--c--><div a='&quot;&lt;'>&lt;&amp;<br><img src=x></div><style>a>b</style>");
    defer f.done();
    const a = f.arena.allocator();
    try eq("<div a=\"&quot;&lt;\">&lt;&amp;<br><img src=\"x\"></div><style>a>b</style>", try f.body());
    const d = f.doc.body().?.firstElementChild().?;
    const outer = try html.serialize(a, d, true);
    try expect(std.mem.startsWith(u8, outer, "<div a="));
    try expect(std.mem.endsWith(u8, outer, "</div>"));
    try eq("<br>", try html.serialize(a, d.firstElementChild().?, true));
}

test "encoding" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try eq("abc", try html.toUtf8(a, "\xEF\xBB\xBFabc", ""));
    try eq("é", try html.toUtf8(a, "\xE9", "text/html; charset=ISO-8859-1"));
    try eq("€", try html.toUtf8(a, "\x80", "text/html; charset=windows-1252"));
    try eq("<meta charset=latin1>é", try html.toUtf8(a, "<meta charset=latin1>\xE9", ""));
    try eq("<meta http-equiv=content-type content='text/html; charset=windows-1252'>é", try html.toUtf8(a, "<meta http-equiv=content-type content='text/html; charset=windows-1252'>\xE9", ""));
    try eq("a\u{FFFD}b", try html.toUtf8(a, "a\xFFb", "text/html; charset=utf-8"));
    try eq("\u{FFFD}", try html.toUtf8(a, "\xE2\x82", "text/html; charset=utf-8"));
    try eq("é", try html.toUtf8(a, "é", ""));
    try eq("é", try html.toUtf8(a, "\xE9", ""));
    try eq("AB", try html.toUtf8(a, "\xFF\xFEA\x00B\x00", ""));
    try eq("😀", try html.toUtf8(a, "\xFE\xFF\xD8\x3D\xDE\x00", ""));
    try eq("<!-- <meta charset=latin1> -->é", try html.toUtf8(a, "<!-- <meta charset=latin1> -->é", ""));
}

test "garbage neither crashes nor hangs" {
    const nasty = [_][]const u8{
        "",                                     "<",                                           "</",                                     "<!",                      "<!-",                                    "<!--",                             "<!doctype",                                "<!doctype ",                               "<!doctype x public",             "<!doctype x public '",
        "<a",                                   "<a ",                                         "<a b",                                   "<a b=",                   "<a b='",                                 "<a b=c",                           "&",                                        "&#",                                       "&#x",                            "&#xZ",
        "&am",                                  "<![CDATA[",                                   "\x00",                                   "<\x00>",                  "<svg><![CDATA[",                         "<svg></",                          "<math><mi><svg><title><div></math>",       "<table><td></tr></tbody></table></table>", "<table><select><table><select>", "</table></tr></td></body></html>",
        "<html><html><head><head><body><body>", "</html></html>x</body>y",                     "<frameset></frameset></frameset>x",      "<frameset><frameset>",    "<select><select><select>",               "<template></template></template>", "<template><template><tr><td><template>",   "<table><template><td></table>",            "<a><a><a><a><a><a><a>",          "<b><i><u><s><p></b></i></u></s></p>",
        "<p><table><p><table><p>",              "<li><li><dd><dt></li>",                       "<title>",                                "<title>x",                "<style>",                                "<script>",                         "<script><!--",                             "<script><!--<script>",                     "<textarea>",                     "<xmp>",
        "<iframe>",                             "<noscript>",                                  "<plaintext>",                            "<a href='x",              "<div a=\"x",                             "<div\x00a>",                       "<svg><foreignobject><svg><foreignobject>", "<svg><desc><table><tr><td><svg>",          "<math><annotation-xml><svg><p>", "<option><optgroup></option></optgroup>",
        "<select><input><select>",              "<caption><col><colgroup><tbody><td><th><tr>", "<body><frameset>",                       "<table><caption><table>", "<table><colgroup><template></colgroup>", "<form><form></form></form>",       "<table><form><form>",                      "<template><form></form>",                  "<head></head></head><head>",     "<a><table><a></table>",
        "<a><div><a></div></a>",                "<svg></p></br></svg>",                        "<body></body></html></body><!-- --><b>", "\xFF\xFE\x80<\xC0>",      "<!doctype html><!doctype html>",
    };
    for (nasty) |s| {
        const f = try Fix.parse(s);
        defer f.done();
        _ = try f.all();
        const frag = try html.parseFragment(f.doc, f.doc.node, s);
        _ = frag;
        const t = try f.doc.createElement("template");
        _ = try html.parseFragment(f.doc, t, s);
        const tb = try f.doc.createElement("table");
        _ = try html.parseFragment(f.doc, tb, s);
        const sel = try f.doc.createElement("select");
        _ = try html.parseFragment(f.doc, sel, s);
    }
    // Repeats of tags that build deep or wide structures.
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const repeats = [_][]const u8{ "<div>", "<b>", "<a>", "<table>", "<td>", "<select>", "<svg>", "<template>", "</b>", "<p>", "<li>", "<font>", "<table><tr><td>" };
    for (repeats) |r| {
        var src: std.ArrayList(u8) = .empty;
        for (0..3000) |_| try src.appendSlice(ar.allocator(), r);
        const f = try Fix.parse(src.items);
        defer f.done();
        const s = try html.serialize(std.testing.allocator, f.doc.node, false);
        std.testing.allocator.free(s);
    }
    // Pseudo-random bytes drawn from the characters that steer the parser.
    var rng = std.Random.DefaultPrng.init(42);
    const pieces = [_][]const u8{
        "<",        ">",      "/",       "!",          "-",         "--",    "=",     "\"",       "'",    " ",    "&",       ";",        "#",    "a",      "b",      "p",      "div",     "table",   "td",        "tr",         "svg",
        "math",     "select", "option",  "template",   "script",    "style", "title", "textarea", "<b>",  "</b>", "<table>", "</table>", "<tr>", "<td>",   "</td>",  "<p>",    "</p>",    "<svg>",   "</svg>",    "<template>", "</template>",
        "<select>", "<a>",    "</a>",    "<frameset>", "<![CDATA[", "]]>",   "<!--",  "-->",      "\x00", "\n",   "<math>",  "<mi>",     "<li>", "<html>", "<head>", "<body>", "</body>", "</html>", "<caption>", "<col>",      "<colgroup>",
        "<input>",  "<form>", "</form>", "<button>",   "<nobr>",
    };
    for (0..400) |_| {
        var src: std.ArrayList(u8) = .empty;
        const n = rng.random().uintLessThan(usize, 120);
        for (0..n) |_| try src.appendSlice(ar.allocator(), pieces[rng.random().uintLessThan(usize, pieces.len)]);
        const f = try Fix.parse(src.items);
        defer f.done();
        const s = try html.serialize(std.testing.allocator, f.doc.node, false);
        std.testing.allocator.free(s);
        checkLinks(f.doc.node);
    }
}

/// Every child points at its parent and its siblings agree.
fn checkLinks(root: *dom.Node) void {
    var n: ?*dom.Node = root;
    while (n) |at| : (n = at.nextInTree(root)) {
        var prev: ?*dom.Node = null;
        var c = at.first_child;
        while (c) |k| : (c = k.next) {
            std.debug.assert(k.parent == at);
            std.debug.assert(k.prev == prev);
            prev = k;
        }
        std.debug.assert(at.last_child == prev);
    }
}
