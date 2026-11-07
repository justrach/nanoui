//! Against numbers Chromium gives for the same markup: shadow trees, used-value
//! `min()`, `aspect-ratio`, containers, counters, balance, columns, grids' corners.
const std = @import("std");
const u = @import("tests_util.zig");
const box = @import("box.zig");
const dom = @import("../dom.zig");
const html = @import("../html/html.zig");
const css = @import("../css/css.zig");
const layout = @import("layout.zig");
const gpa = std.testing.allocator;

const Page = struct {
    arena: std.heap.ArenaAllocator,
    doc: *dom.Document,
    engine: css.Engine,
    tree: box.Tree,

    fn make(source: []const u8, sheet: []const u8) !*Page {
        const p = try gpa.create(Page);
        p.arena = std.heap.ArenaAllocator.init(gpa);
        const a = p.arena.allocator();
        p.doc = try dom.Document.create(a);
        try html.parseDocument(p.doc, source);
        p.engine = css.Engine.init(gpa, p.doc);
        const s = try css.parseSheet(a, sheet, "https://x.test/s.css");
        p.engine.setSheets(&.{s});
        // Shadow trees' `<style>`s, as the loader finds them.
        var at: ?*dom.Node = p.doc.node;
        var roots: std.ArrayList(*dom.Node) = .empty;
        var lists: std.ArrayList([]const *const css.Sheet) = .empty;
        while (at) |n| : (at = n.nextDeep(p.doc.node)) {
            if (!n.isTag("style")) continue;
            var up = n.parent;
            while (up) |x| : (up = x.parent) if (x.is_shadow) {
                const text = try n.textContent(a);
                const one = try a.alloc(*const css.Sheet, 1);
                one[0] = try css.parseSheet(a, text, "https://x.test/");
                try roots.append(a, x);
                try lists.append(a, one);
                break;
            };
        }
        p.engine.setScopedSheets(roots.items, lists.items);
        p.engine.setViewport(.{ .width = 800, .height = 600 });
        try p.engine.restyleAll();
        p.tree = try layout.run(a, p.doc, .{ .width = 800, .height = 600 }, u.measurer);
        var passes: u8 = 0;
        while (passes < 4 and layout.updateContainers(&p.engine)) : (passes += 1) {
            p.tree = try layout.run(a, p.doc, .{ .width = 800, .height = 600 }, u.measurer);
        }
        return p;
    }

    fn done(p: *Page) void {
        p.engine.deinit();
        p.arena.deinit();
        gpa.destroy(p);
    }

    fn rect(p: *Page, id: []const u8, x: f32, y: f32, w: f32, h: f32) !void {
        const n = find(p, id) orelse {
            std.debug.print("no element {s}\n", .{id});
            return error.TestFailed;
        };
        const r = layout.rectOf(n) orelse {
            std.debug.print("no box for {s}\n", .{id});
            return error.TestFailed;
        };
        std.debug.print("", .{});
        errdefer std.debug.print("#{s}: got {d} {d} {d} {d}, want {d} {d} {d} {d}\n", .{ id, r.x, r.y, r.w, r.h, x, y, w, h });
        try u.close(x, r.x, "x");
        try u.close(y, r.y, "y");
        try u.close(w, r.w, "w");
        try u.close(h, r.h, "h");
    }

    /// Any element by id, shadow trees included.
    fn find(p: *Page, id: []const u8) ?*dom.Node {
        var at: ?*dom.Node = p.doc.node;
        while (at) |n| : (at = n.nextDeep(p.doc.node)) {
            if (n.attr("id")) |v| if (std.mem.eql(u8, v, id)) return n;
        }
        return null;
    }
};

const reset = "body{margin:0}";

test "a shadow tree: :host, ::slotted, its own rules, and none from outside" {
    const p = try Page.make(
        \\<!doctype html><x-a id=h><template shadowrootmode=open><style>:host{display:block;height:30px} div{height:9px;width:50px} ::slotted(p){height:11px;width:20px}</style><div id=s></div><slot></slot></template><p id=l>x</p></x-a>
        \\<div id=out style="width:60px"></div>
    , reset ++ "div{height:7px} p{margin:0} x-a div{height:77px}");
    defer p.done();
    try p.rect("h", 0, 0, 800, 30);
    try p.rect("s", 0, 0, 50, 9);
    try p.rect("l", 0, 9, 20, 11);
    try p.rect("out", 0, 30, 60, 7);
    // Not a child, and nothing walks into it from the host's side.
    const host = p.find("h").?;
    try std.testing.expect(host.firstElementChild() == p.find("l").?);
    try std.testing.expect(p.doc.getElementById("s") == null);
}

test "a template's content is outside the tree" {
    const p = try Page.make("<!doctype html><template id=t><p id=in>x</p></template><div id=d></div>", reset);
    defer p.done();
    try std.testing.expect(p.doc.getElementById("in") == null);
    try std.testing.expectEqualStrings("<p id=\"in\">x</p>", try html.serialize(p.arena.allocator(), p.doc.getElementById("t").?, false));
}

test "min(), max() and clamp() with percentages take the reference they get" {
    const p = try Page.make(
        \\<!doctype html><div style="width:400px">
        \\<div id=a style="width:min(100%,500px)"></div><div id=b style="width:min(50%,100px)"></div><div id=c style="width:max(50%,100px)"></div>
        \\<div id=d style="width:clamp(100px,50%,150px)"></div><div id=e style="width:calc(min(100%,500px) - 20px)"></div><div id=f style="margin-left:max(10%,10px);width:50px"></div>
        \\<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,150px),1fr));gap:10px"><div id=g1 style="height:1px"></div><div id=g2 style="height:1px"></div></div>
        \\<div style="display:flex"><div id=h style="flex:0 0 min(50%,100px)"></div></div></div>
    , reset);
    defer p.done();
    try p.rect("a", 0, 0, 400, 0);
    try p.rect("b", 0, 0, 100, 0);
    try p.rect("c", 0, 0, 200, 0);
    try p.rect("d", 0, 0, 150, 0);
    try p.rect("e", 0, 0, 380, 0);
    try p.rect("f", 40, 0, 50, 0);
    try p.rect("g1", 0, 0, 195, 1);
    try p.rect("g2", 205, 0, 195, 1);
    try p.rect("h", 0, 1, 100, 0);
}

test "aspect-ratio on every kind of box" {
    const p = try Page.make(
        \\<!doctype html>
        \\<div id=a style="width:200px;aspect-ratio:2/1"></div>
        \\<img id=b style="width:100px;aspect-ratio:3/1;display:block"><img id=c style="height:30px;aspect-ratio:3/1;display:block">
        \\<div id=k style="aspect-ratio:1;width:100px"><div style="height:200px"></div></div>
        \\<div id=m style="width:100px;aspect-ratio:1;overflow:hidden"><div style="height:200px"></div></div>
        \\<div style="width:200px"><div id=o style="padding:10px;aspect-ratio:2;box-sizing:border-box"></div><div id=q style="padding:10px;aspect-ratio:2"></div></div>
    , reset);
    defer p.done();
    try p.rect("a", 0, 0, 200, 100);
    try p.rect("b", 0, 100, 100, 100.0 / 3.0);
    try p.rect("c", 0, 100 + 100.0 / 3.0, 90, 30);
    const y = 130 + 100.0 / 3.0;
    try p.rect("k", 0, y, 100, 200);
    try p.rect("m", 0, y + 200, 100, 100);
    try p.rect("o", 0, y + 300, 200, 100);
    try p.rect("q", 0, y + 400, 200, 110);
}

test "@container and cq units ask the real container" {
    const p = try Page.make(
        \\<!doctype html><div style="container-type:inline-size;width:300px" id=q1><div id=q2></div><div id=q3></div><div id=q4></div></div>
        \\<div style="container:foo/inline-size;width:100px" id=q5><div style="container-type:inline-size;width:50px"><div id=q6></div><div id=q7></div></div></div>
    , reset ++
        \\@container (min-width:200px){#q2{height:33px}} @container (min-width:500px){#q3{height:44px}} #q4{width:50cqw;height:10cqi}
        \\@container foo (width<=100px){#q6{height:55px}} @container bar (width<=100px){#q7{height:66px}}
    );
    defer p.done();
    try p.rect("q2", 0, 0, 300, 33);
    try p.rect("q3", 0, 33, 300, 0);
    try p.rect("q4", 0, 33, 150, 30);
    try p.rect("q6", 0, 63, 50, 55);
    try p.rect("q7", 0, 118, 50, 0);
}

test "containment: what's in a container doesn't size it" {
    const p = try Page.make(
        \\<!doctype html><div id=a style="display:inline-block;container-type:inline-size"><div style="width:100px;height:10px"></div></div>
        \\<div id=b style="contain:size;height:auto"><div style="height:50px"></div></div>
    , reset);
    defer p.done();
    const a = layout.rectOf(p.find("a").?).?;
    try u.close(0, a.w, "w");
    const b = layout.rectOf(p.find("b").?).?;
    try u.close(0, b.h, "h");
}

test "a picture with a percentage height of a parent that has one, as its width's source" {
    const p = try Page.make(
        \\<!doctype html><div style="display:flex"><h1 id=h style="display:grid;height:26px;margin:0"><svg id=s viewBox="0 0 104 26" style="width:auto;height:100%"></svg></h1></div>
    , reset);
    defer p.done();
    const h = layout.rectOf(p.find("h").?).?;
    try u.close(104, h.w, "the holder takes its width");
    const s = layout.rectOf(p.find("s").?).?;
    try u.close(104, s.w, "w");
    try u.close(26, s.h, "h");
}

/// The text of the first `::before` under a box.
fn pseudoText(b: *box.Box) ?[]const u8 {
    var k = b.first_child;
    while (k) |x| : (k = x.next) {
        if (x.pseudo and x.runs.len > 0) return x.runs[0].text;
        if (x.node == null) if (pseudoText(x)) |t| return t;
    }
    return null;
}

fn textOf(n: *dom.Node) []const u8 {
    return pseudoText(@ptrCast(@alignCast(n.box.?))) orelse "";
}

test "counters: reset, increment, nesting and counters()" {
    const p = try Page.make(
        \\<!doctype html><div id=c style="counter-reset:s"><h3 id=c1>a</h3><h3 id=c2>b</h3></div>
        \\<ol class=n><li id=n1>one<ol class=n><li id=n2>two</li></ol></li><li id=n3>three</li></ol>
    ,
        \\h3{counter-increment:s} h3::before{content:"#" counter(s) ": "}
        \\.n{counter-reset:x} .n li{counter-increment:x;list-style:none} .n li::before{content:counters(x,".") " "}
    );
    defer p.done();
    try u.eqText("#1: ", textOf(p.find("c1").?));
    try u.eqText("#2: ", textOf(p.find("c2").?));
    try u.eqText("1 ", textOf(p.find("n1").?));
    try u.eqText("1.1 ", textOf(p.find("n2").?));
    try u.eqText("2 ", textOf(p.find("n3").?));
}

test "text-wrap: balance evens the lines without adding one" {
    // Every character 8 wide: "aaaa bbbb cccc dddd eeee ffff" fits 3 words a line at 200.
    const p = try Page.make("<!doctype html><div id=b style=\"width:200px;text-wrap:balance;line-height:16px\">aaaa bbbb cccc dddd eeee ffff</div><div id=g style=\"width:200px;line-height:16px\">aaaa bbbb cccc dddd eeee ffff gggg</div>", reset);
    defer p.done();
    const runs = @as(*box.Box, @ptrCast(@alignCast(p.find("b").?.box.?))).runs;
    try std.testing.expectEqual(@as(usize, 2), runs.len);
    try u.eqText("aaaa bbbb cccc", runs[0].text);
    try u.eqText("dddd eeee ffff", runs[1].text);
    try p.rect("b", 0, 0, 200, 32);
}

test "columns take their share of the width and the content evens out" {
    const p = try Page.make(
        \\<!doctype html><div id=mc2 style="column-count:3;width:300px;column-gap:0"><div id=m1 style="height:50px"></div><div id=m2 style="height:50px"></div><div id=m3 style="height:50px"></div></div>
        \\<div style="column-width:100px;width:320px" id=mc3><div id=m4 style="height:30px"></div><div id=m5 style="height:30px"></div></div>
    , reset);
    defer p.done();
    try p.rect("mc2", 0, 0, 300, 50);
    try p.rect("m1", 0, 0, 100, 50);
    try p.rect("m2", 100, 0, 100, 50);
    try p.rect("m3", 200, 0, 100, 50);
    try p.rect("mc3", 0, 50, 320, 30);
    try p.rect("m4", 0, 50, 152, 30);
    try p.rect("m5", 168, 50, 152, 30);
}

test "grid: names, dense, repeats of several tracks, fit-content" {
    const p = try Page.make(
        \\<!doctype html>
        \\<div style="display:grid;grid-template-columns:[a] 100px [b c] 50px [d];width:300px"><div id=d style="grid-column:c/d;height:5px"></div><div id=e style="grid-column:a/b;height:5px"></div></div>
        \\<div style="display:grid;grid-auto-flow:dense;grid-template-columns:repeat(3,50px);width:150px"><div id=f style="grid-column:span 2;height:5px"></div><div id=g style="grid-column:span 2;height:5px"></div><div id=h style="height:5px"></div></div>
        \\<div style="display:grid;grid-template-columns:repeat(2,10px 20px);width:400px"><div id=l style="height:5px"></div><div id=m style="height:5px"></div><div id=n style="height:5px"></div></div>
        \\<div style="display:grid;grid-template-columns:repeat(auto-fill,10px 20px);width:100px"><div id=p style="height:5px"></div><div id=q style="height:5px"></div><div id=r style="grid-column:-2;height:5px"></div></div>
        \\<div style="display:grid;grid-template-columns:[full-start] 10px [main-start] 100px [main-end] 10px [full-end];width:300px"><div id=v style="grid-column:main;height:5px"></div><div id=w style="grid-column:full;height:5px"></div></div>
        \\<div style="display:grid;grid-template-columns:fit-content(100px) fit-content(30px) 1fr;width:400px"><div id=i>aa</div><div id=j>aa aa aa aa aa aa</div><div id=k>c</div></div>
    , reset);
    defer p.done();
    try p.rect("d", 100, 0, 50, 5);
    try p.rect("e", 0, 5, 100, 5); // Before the cursor: the next row.
    try p.rect("f", 0, 10, 100, 5);
    try p.rect("g", 0, 15, 100, 5);
    try p.rect("h", 100, 10, 50, 5); // Back in the hole; without `dense` it'd stay under.
    try p.rect("l", 0, 20, 10, 5);
    try p.rect("m", 10, 20, 20, 5);
    try p.rect("n", 30, 20, 10, 5);
    try p.rect("p", 0, 25, 10, 5);
    try p.rect("q", 10, 25, 20, 5);
    try p.rect("r", 70, 25, 20, 5);
    try p.rect("v", 10, 30, 100, 5);
    try p.rect("w", 0, 35, 120, 5);
    const i = layout.rectOf(p.find("i").?).?;
    const j = layout.rectOf(p.find("j").?).?;
    try u.close(16, i.w, "fit-content under its limit is its content");
    try u.close(30, j.w, "fit-content over its limit stops there");
}

test "border-collapse: each line's winner, halved between the boxes beside it" {
    const p = try Page.make(
        \\<!doctype html><table style="border-collapse:collapse;width:200px" id=tb><tr><td id=t1 style="border:3px solid;padding:0;height:10px"></td><td id=t2 style="border:5px solid;padding:0"></td></tr></table>
    , reset);
    defer p.done();
    // Chromium: a row of 13 (10 and half of 3 on each side), and half of 5 above and
    // below it, the widest of the first and last rows.
    const t = layout.rectOf(p.find("tb").?).?;
    try u.close(200, t.w, "table w");
    try u.close(18, t.h, "table h");
    const a = layout.rectOf(p.find("t1").?).?;
    const b = layout.rectOf(p.find("t2").?).?;
    try u.close(1.5, a.x, "a x");
    try u.close(2.5, a.y, "a y");
    try u.close(a.x + a.w, b.x, "they meet");
    try u.close(197.5, b.x + b.w, "b's right");
    try u.close(a.h, b.h, "one row");
}

test "an item spanning flexible tracks has no automatic minimum size" {
    const p = try Page.make(
        \\<!doctype html><div style="display:grid;grid-template-columns:repeat(4,1fr);width:400px"><div id=a style="grid-column:1/5"><div style="width:900px;height:5px"></div></div></div>
        \\<div style="display:grid;grid-template-columns:1fr;width:400px"><div id=b><div style="width:900px;height:5px"></div></div></div>
    , reset);
    defer p.done();
    try p.rect("a", 0, 0, 400, 5);
    try p.rect("b", 0, 5, 900, 5);
}

test "aspect-ratio and a height say an inline-block's width" {
    const p = try Page.make("<!doctype html><div id=o style=\"display:inline-block\"><div id=b style=\"aspect-ratio:9/16;height:320px\"></div></div>", reset);
    defer p.done();
    try p.rect("b", 0, 0, 180, 320);
}

test "env() of what a window has none of is nothing" {
    const p = try Page.make("<!doctype html><div id=a style=\"--s:env(safe-area-inset-left);padding-left:max(22px,var(--s));height:1px\"></div>", reset);
    defer p.done();
    try std.testing.expectEqual(@as(f32, 22), @as(*box.Box, @ptrCast(@alignCast(p.find("a").?.box.?))).padding.left);
}

test "subgrid: columns and rows from the grid around it" {
    const p = try Page.make(
        \\<!doctype html><div style="display:grid;grid-template-columns:100px 100px;width:200px"><div id=s style="display:grid;grid-template-columns:subgrid;grid-column:1/3"><div id=s1 style="height:5px"></div><div id=s2 style="height:5px"></div></div></div>
        \\<div style="display:grid;grid-template-rows:repeat(2,auto);grid-template-columns:100px 100px;width:200px"><div id=t style="display:grid;grid-template-rows:subgrid;grid-row:span 2"><div id=t1 style="height:25px"></div><div id=t2 style="height:5px"></div></div><div id=u style="display:grid;grid-template-rows:subgrid;grid-row:span 2"><div id=u1 style="height:5px"></div><div id=u2 style="height:35px"></div></div></div>
    , reset);
    defer p.done();
    try p.rect("s", 0, 0, 200, 5);
    try p.rect("s1", 0, 0, 100, 5);
    try p.rect("s2", 100, 0, 100, 5);
    try p.rect("t", 0, 5, 100, 60);
    try p.rect("t1", 0, 5, 100, 25);
    try p.rect("t2", 0, 30, 100, 5);
    try p.rect("u", 100, 5, 100, 60);
    try p.rect("u1", 100, 5, 100, 5);
    try p.rect("u2", 100, 30, 100, 35);
}

test "an absolute child of a flex container stands as its only item would" {
    const p = try Page.make(
        \\<!doctype html><div style="display:flex;position:relative;width:300px;height:100px;justify-content:center;align-items:center"><div id=a style="position:absolute;width:10px;height:10px"></div></div>
        \\<div style="display:flex;flex-direction:column;align-items:flex-end;justify-content:flex-end;width:100px;height:50px"><div id=b style="position:absolute;width:10px;height:10px"></div></div>
        \\<label style="display:inline-block;width:100px;height:40px"><span id=s style="display:inline-block;width:20px;height:20px"></span><span id=c style="position:absolute;width:1px;height:1px"></span><div id=d style="position:absolute;width:1px;height:1px"></div></label>
    , reset);
    defer p.done();
    try p.rect("a", 145, 45, 10, 10);
    try p.rect("b", 90, 140, 10, 10);
    const s = layout.rectOf(p.find("s").?).?;
    try p.rect("c", 20, s.y, 1, 1);
    const d = layout.rectOf(p.find("d").?).?;
    try u.close(0, d.x, "a block's static place starts the next line");
}

test "an inline with nothing in it, on a line with nothing on it, has no height" {
    const p = try Page.make("<!doctype html><div id=w>text<span id=a></span></div><div><span id=b></span></div>", reset);
    defer p.done();
    const a = layout.rectOf(p.find("a").?).?;
    try u.close(32, a.x, "after the text");
    try u.close(16, a.h, "on a line it has the line's");
    const b = layout.rectOf(p.find("b").?).?;
    try u.close(0, b.h, "on none it has none");
}

test "a closed details shows only its summary, whatever display the rest has" {
    const p = try Page.make("<!doctype html><details id=d><summary id=s>x</summary><div id=i style=\"display:block;height:50px\"></div></details><details open id=e><summary>y</summary><div id=j style=\"height:50px\"></div></details>", reset);
    defer p.done();
    try std.testing.expect(layout.rectOf(p.find("i").?) == null);
    const j = layout.rectOf(p.find("j").?).?;
    try u.close(50, j.h, "h");
}

test "a block in a link: the link's rect takes in the line the block stands on" {
    const p = try Page.make("<!doctype html><div style=\"width:100px\"><a id=a href=x><div id=d style=\"width:10px;height:10px;margin:3px 2px\"></div></a></div>", reset);
    defer p.done();
    const a = layout.rectOf(p.find("a").?).?;
    try u.close(100, a.w, "w");
    try u.close(3, a.y, "y");
    try u.close(10, a.h, "h");
}
