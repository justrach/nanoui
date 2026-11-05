//! Fonts in pages through the whole browser: `@font-face` from `data:` addresses, so
//! no network and no window. The fonts are made here, each glyph a box of a known
//! advance, so a text's width says which font drew it.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("shell/browser.zig").Browser;
const dom = @import("dom.zig");
const box = @import("layout/box.zig");
const webfonts = @import("webfonts.zig");
const Page = @import("page.zig").Page;
const testing = std.testing;

const Run = struct {
    b: Browser,
    t: ui.Tester = undefined,

    fn start(r: *Run) !void {
        r.b = .{ .gpa = testing.allocator };
        try r.b.init();
        try r.t.init(testing.allocator, ui.View.init(&r.b, Browser.view), .{ .width = 900, .height = 600, .scale = 1 });
    }

    fn stop(r: *Run) void {
        r.settle();
        r.t.deinit();
        r.b.deinit();
    }

    fn settle(r: *Run) void {
        var waited: u32 = 0;
        while (waited < 400) : (waited += 1) {
            r.t.frame();
            if (!r.b.tabs.items[r.b.current].loading()) break;
            nanoui.runFor(0.005);
        }
        r.t.frame();
        r.t.frame();
    }

    fn open(r: *Run, url: []const u8) void {
        r.b.tabs.items[r.b.current].go(url);
        r.settle();
    }

    fn page(r: *Run) *Page {
        return r.b.tabs.items[r.b.current].page.?;
    }

    fn boxOf(r: *Run, id: []const u8) ?*box.Box {
        const tree = r.page().tree orelse return null;
        return find(tree.root, id);
    }

    fn widthOf(r: *Run, id: []const u8) f32 {
        const b = r.boxOf(id) orelse return -1;
        return b.w;
    }

    fn heightOf(r: *Run, id: []const u8) f32 {
        const b = r.boxOf(id) orelse return -1;
        return b.h;
    }
};

fn find(b: *box.Box, id: []const u8) ?*box.Box {
    if (b.node) |n| if (n.attr("id")) |v| if (std.mem.eql(u8, v, id)) return b;
    var c = b.first_child;
    while (c) |k| : (c = k.next) if (find(k, id)) |hit| return hit;
    return null;
}

/// A `data:` address of a page with these fonts declared and this body.
fn pageUrl(a: std.mem.Allocator, faces: []const u8, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "data:text/html,<!doctype html><style>{s}</style><body style='margin:0'>{s}", .{ faces, body });
}

/// A CSS `url()` of a font's bytes.
fn fontUrl(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(bytes.len));
    return std.fmt.allocPrint(a, "url(\"data:font/ttf;base64,{s}\")", .{enc.encode(out, bytes)});
}

fn fixture(a: std.mem.Allocator, advance: u16) ![]const u8 {
    return fontUrl(a, try ui.test_font.build(a, .{ .family = "Fixture", .advance = advance, .ranges = &.{ .{ 0x20, 0x7e }, .{ 0x410, 0x44f } } }));
}

test "a page's @font-face draws its text, with the fallback's width gone" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const faces = try std.fmt.allocPrint(a, "@font-face{{font-family:Probe;src:{s}}}", .{try fixture(a, 500)});
    r.open(try pageUrl(a, faces, "<div style='display:inline-block;font:20px Probe, serif' id=a>abcd</div>"));
    try testing.expectApproxEqAbs(@as(f32, 40), r.widthOf("a"), 0.01);
    // Scoped to the page: nothing else finds it by that name.
    try testing.expect(!r.t.text.hasFamily("Probe"));
    // Its line takes the real font's metrics: 800 and 200 of 1000.
    try testing.expectApproxEqAbs(@as(f32, 20), r.heightOf("a"), 0.01);
}

test "only the faces the text falls in are asked for, and each character goes to its own" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const faces = try std.fmt.allocPrint(a,
        \\@font-face{{font-family:Split;src:{s};unicode-range:U+0-7F}}
        \\@font-face{{font-family:Split;src:{s};unicode-range:U+410-44F}}
        \\@font-face{{font-family:Split;src:{s};unicode-range:U+4E00-9FFF}}
    , .{ try fixture(a, 500), try fixture(a, 1000), try fixture(a, 2000) });
    r.open(try pageUrl(a, faces, "<div style='display:inline-block;font:10px Split' id=a>ab\u{430}</div>"));
    try testing.expectApproxEqAbs(@as(f32, 20), r.widthOf("a"), 0.01);
    const list = r.page().faces.list.items;
    try testing.expectEqual(@as(usize, 3), list.len);
    try testing.expectEqual(webfonts.Face.State.here, list[0].state);
    try testing.expectEqual(webfonts.Face.State.here, list[1].state);
    try testing.expectEqual(webfonts.Face.State.idle, list[2].state);
}

test "weights and styles pick their files, and what's missing is made up" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const faces = try std.fmt.allocPrint(a,
        \\@font-face{{font-family:W;src:{s};font-weight:400;font-style:normal}}
        \\@font-face{{font-family:W;src:{s};font-weight:700;font-style:normal}}
        \\@font-face{{font-family:W;src:{s};font-weight:400;font-style:italic}}
    , .{ try fixture(a, 500), try fixture(a, 1000), try fixture(a, 1500) });
    const body =
        \\<div style='display:inline-block;font:10px W' id=regular>aa</div><br>
        \\<div style='display:inline-block;font:bold 10px W' id=bold>aa</div><br>
        \\<div style='display:inline-block;font:italic 10px W' id=italic>aa</div><br>
        \\<div style='display:inline-block;font:500 10px W' id=medium>aa</div>
    ;
    r.open(try pageUrl(a, faces, body));
    try testing.expectApproxEqAbs(@as(f32, 10), r.widthOf("regular"), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 20), r.widthOf("bold"), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 30), r.widthOf("italic"), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10), r.widthOf("medium"), 0.01);
}

test "a bad source falls through to the next, and text draws meanwhile" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const faces = try std.fmt.allocPrint(a, "@font-face{{font-family:S;src:url('data:font/woff2,notafont') format('woff2'),url(x.eot) format('embedded-opentype'),{s}}}", .{try fixture(a, 500)});
    r.open(try pageUrl(a, faces, "<div style='display:inline-block;font:10px S' id=a>abcd</div>"));
    try testing.expectApproxEqAbs(@as(f32, 20), r.widthOf("a"), 0.01);
}

test "a font that comes later swaps in with a layout pass, unless it's too late for optional" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    r.open(try pageUrl(a, "@font-face{font-family:L;src:url('data:,x')}@font-face{font-family:O;font-display:optional;src:url('data:,x')}",
        \\<div style='display:inline-block;font:10px L' id=late>abcd</div><br>
        \\<div style='display:inline-block;font:10px O' id=opt>abcd</div>
    ));
    const before = r.widthOf("late");
    try testing.expect(before > 0);
    const list = r.page().faces.list.items;
    try testing.expectEqual(webfonts.Face.State.failed, list[0].state);
    // As a request's answer would come: no frame asked for it.
    const bytes = try ui.test_font.build(a, .{ .advance = 1500 });
    list[0].state = .loading;
    list[0].asked_at_ms = 0;
    list[1].state = .loading;
    list[1].asked_at_ms = 0;
    webfonts.arrived(r.page(), list[0], 200, bytes);
    webfonts.arrived(r.page(), list[1], 200, bytes);
    try testing.expect(r.page().doc.layout_dirty);
    r.t.frame();
    r.t.frame();
    try testing.expectApproxEqAbs(@as(f32, 60), r.widthOf("late"), 0.01);
    try testing.expectApproxEqAbs(before, r.widthOf("opt"), 0.01);
}

test "ch and ex come from the real font" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const faces = try std.fmt.allocPrint(a, "@font-face{{font-family:U;src:{s}}}", .{try fixture(a, 800)});
    r.open(try pageUrl(a, faces, "<div style='font:10px U;width:2ch;height:2ex' id=a>x</div>"));
    // `0` is 800 of 1000 wide; the font's x height is 450.
    try testing.expectApproxEqAbs(@as(f32, 16), r.widthOf("a"), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 9), r.heightOf("a"), 0.01);
}

test "an icon font's ligature draws its glyph, and spaced letters are letters" {
    if (nanoui.ui.portable) return error.SkipZigTest;
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try ui.test_font.build(a, .{ .family = "Icons", .ligature = "home", .ligature_advance = 1400 });
    const faces = try std.fmt.allocPrint(a, "@font-face{{font-family:Icons;src:{s}}}", .{try fontUrl(a, bytes)});
    const body =
        \\<span style='display:inline-block;font:10px Icons' id=icon>home</span><br>
        \\<span style='display:inline-block;font:10px Icons;letter-spacing:1px' id=spaced>home</span>
    ;
    r.open(try pageUrl(a, faces, body));
    try testing.expectApproxEqAbs(@as(f32, 14), r.widthOf("icon"), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 24), r.widthOf("spaced"), 0.01);
}

test "line-height normal is Chromium's on the Mac, the classic faces' ascent raised" {
    if (nanoui.ui.portable or builtin.os.tag != .macos) return error.SkipZigTest;
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Measured from Chromium: the height of a line at 10 and 16 pixels.
    const body =
        \\<div style='font:10px Times' id=t10>x</div><div style='font:16px Times' id=t16>x</div>
        \\<div style='font:10px Helvetica' id=h10>x</div><div style='font:18px Times' id=t18>x</div>
        \\<div style='font:10px Arial' id=a10>x</div><div style='font:16px Arial' id=a16>x</div>
        \\<div style='font:16px sans-serif' id=sans>x</div><div style='font-family:serif;font-size:13px' id=serif>x</div>
        \\<pre style='margin:0' id=pre>x</pre>
    ;
    r.open(try pageUrl(a, "", body));
    try testing.expectEqual(@as(f32, 13), r.heightOf("t10"));
    try testing.expectEqual(@as(f32, 18), r.heightOf("t16"));
    try testing.expectEqual(@as(f32, 22), r.heightOf("t18"));
    try testing.expectEqual(@as(f32, 12), r.heightOf("h10"));
    try testing.expectEqual(@as(f32, 11), r.heightOf("a10"));
    try testing.expectEqual(@as(f32, 18), r.heightOf("a16"));
    try testing.expectEqual(@as(f32, 18), r.heightOf("sans"));
    try testing.expectEqual(@as(f32, 15), r.heightOf("serif"));
    // The `monospace` quirk: 13px, in Courier here.
    try testing.expectEqual(@as(f32, 13), r.boxOf("pre").?.style.font_size);
    try testing.expectEqual(@as(f32, 15), r.heightOf("pre"));
}

test "an absolute size stays through monospace, the default's proportion doesn't" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\<code id=plain>x</code>
        \\<div style='font-size:20px'><code id=px>x</code><div style='font-size:50%'><code id=half>x</code></div></div>
        \\<div style='font-size:2em'><code id=em>x</code></div>
        \\<code style='font-size:medium' id=kw>x</code>
        \\<code style='font-size:20px;font-family:monospace' id=own>x</code>
        \\<code style='font-family:monospace, serif' id=two><span style='font-family:monospace' id=inner>x</span></code>
    ;
    r.open(try pageUrl(a, "", body));
    const size = struct {
        fn f(rr: *Run, id: []const u8) f32 {
            const b = rr.boxOf(id) orelse return -1;
            return b.style.font_size;
        }
    }.f;
    try testing.expectEqual(@as(f32, 13), size(&r, "plain"));
    try testing.expectEqual(@as(f32, 20), size(&r, "px"));
    try testing.expectEqual(@as(f32, 10), size(&r, "half"));
    // 2em of the default isn't absolute: then it's in proportion.
    try testing.expectEqual(@as(f32, 26), size(&r, "em"));
    try testing.expectEqual(@as(f32, 13), size(&r, "kw"));
    try testing.expectEqual(@as(f32, 20), size(&r, "own"));
    // A list isn't the bare generic.
    try testing.expectEqual(@as(f32, 16), size(&r, "two"));
    try testing.expectEqual(@as(f32, 13), size(&r, "inner"));
}

test "a page's fonts go when it does" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const faces = try std.fmt.allocPrint(a, "@font-face{{font-family:Gone;src:{s}}}", .{try fixture(a, 500)});
    r.open(try pageUrl(a, faces, "<div style='font:10px Gone'>x</div>"));
    const scope = try a.dupe(u8, r.page().faces.scope);
    var name: [64]u8 = undefined;
    const family = try std.fmt.bufPrint(&name, "{s}Gone", .{scope});
    try testing.expect(r.t.text.hasFamily(family));
    r.open("data:text/html,<p>next");
    r.t.frame();
    r.t.frame();
    try testing.expect(!r.t.text.hasFamily(family));
}

test "a family name of bare words is one name, and is asked for" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const parser = @import("css/parser.zig");
    const family = @import("css/font_family.zig");
    const s = try parser.parseSheet(arena.allocator(), "@font-face{font-family:Optimistic   Display;src:url(a.woff2)}@font-face{font-family:Solo;src:url(b.woff2)}@font-face{font-family:\"Quoted Name\";src:url(c.woff2)}@font-face{font-family:a 1;src:url(d.woff2)}", "https://x.test/");
    try std.testing.expectEqualStrings("Optimistic Display", family.faceFamily(s.font_faces[0].decls).?);
    try std.testing.expectEqualStrings("Solo", family.faceFamily(s.font_faces[1].decls).?);
    try std.testing.expectEqualStrings("Quoted Name", family.faceFamily(s.font_faces[2].decls).?);
    try std.testing.expect(family.faceFamily(s.font_faces[3].decls) == null);
}
