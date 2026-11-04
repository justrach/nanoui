//! A big page under a big sheet, in Debug, under the leak-checking allocator:
//! restyling must stay fast, and the generations must free what they own.
const std = @import("std");
const dom = @import("../dom.zig");
const html = @import("../html/html.zig");
const css = @import("css.zig");

const gpa = std.testing.allocator;

fn monotonicNow() u64 {
    return std.c.mach_absolute_time();
}

test "5000 elements under 500 rules, repeatedly" {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const a = ar.allocator();

    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "<!doctype html><html><head><title>t</title></head><body>");
    var count: usize = 0;
    var id: usize = 0;
    while (count < 5000) {
        // Sections of a list, a table row of text and some inline runs.
        const w = try std.fmt.allocPrint(a,
            \\<section class="c{d} box"><ul class="list"><li class="item c{d}"><a class="c{d} link" href="#">a</a></li><li class="item">b</li></ul><p class="text c{d}" style="margin:1px">x<span class="c{d}">y</span></p><div id="i{d}" class="row"><span>z</span></div></section>
        , .{ id % 200, (id + 1) % 200, (id + 2) % 200, (id + 3) % 200, (id + 4) % 200, id });
        try src.appendSlice(a, w);
        count += 9;
        id += 1;
    }
    try src.appendSlice(a, "</body></html>");

    var sheet_src: std.ArrayList(u8) = .empty;
    try sheet_src.appendSlice(a, ":root { --gap: 4px; --fg: #333; } *, ::before, ::after { box-sizing: border-box; --tw-a: 0; --tw-b: 1px; }\n");
    for (0..200) |i| {
        const r = try std.fmt.allocPrint(a,
            \\.c{d} {{ margin: {d}px; padding: var(--gap) calc(var(--gap) * 2); color: rgb({d} 0 0); }}
            \\.box > .c{d}:hover {{ color: red; }}
            \\
        , .{ i, i % 7, i % 255, i });
        try sheet_src.appendSlice(a, r);
    }
    for (0..98) |i| {
        const r = try std.fmt.allocPrint(a, "section:nth-child({d}n) .item a.c{d} {{ border: 1px solid var(--fg); }}\n", .{ i + 2, i });
        try sheet_src.appendSlice(a, r);
    }
    try sheet_src.appendSlice(a, "a::before { content: 'x'; } .link:hover::after { content: 'y'; } p span { font-weight: bold; }\n");

    const doc = try dom.Document.create(a);
    try html.parseDocument(doc, src.items);
    var elements: usize = 0;
    var at: ?*dom.Node = doc.node;
    while (at) |n| : (at = n.nextInTree(doc.node)) if (n.kind == .element) {
        elements += 1;
    };
    try std.testing.expect(elements >= 5000);

    const sheet = try css.parseSheet(a, sheet_src.items, "");
    try std.testing.expect(sheet.rules.len >= 500);

    var engine = css.Engine.init(gpa, doc);
    defer engine.deinit();
    engine.setSheets(&.{sheet});
    engine.setViewport(.{ .width = 1200, .height = 800 });

    const start = monotonicNow();
    for (0..3) |_| try engine.restyleAll();
    const elapsed_ns = machToNs(monotonicNow() - start);
    std.debug.print("\n{d} elements, {d} rules: 3 restyles in {d} ms (Debug)\n", .{ elements, sheet.rules.len, elapsed_ns / 1_000_000 });
    // 10 seconds per restyle would mean something has gone quadratic.
    try std.testing.expect(elapsed_ns < 30 * std.time.ns_per_s);

    // Hovering costs only what it touches.
    const target = doc.getElementById("i5").?;
    doc.hover = target;
    const up = engine.invalidatedByState(target);
    if (up) |u| _ = try engine.restyleSubtree(u);
    doc.hover = null;
    try std.testing.expect(engine.hoverSensitive());

    const link = (try css.querySelector(doc.node, "a.link", a)).?;
    try std.testing.expect(link.before != null);
    try std.testing.expect(link.computed.?.box_sizing == .border_box);
}

fn machToNs(ticks: u64) u64 {
    var info: std.c.mach_timebase_info_data = undefined;
    _ = std.c.mach_timebase_info(&info);
    return ticks * info.numer / info.denom;
}
