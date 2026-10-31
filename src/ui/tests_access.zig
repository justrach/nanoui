//! The shared accessibility tree (`access.zig`): what VoiceOver reads on
//! every platform, made from the frame.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const access = ui.access;

const Page = struct {
    on: bool = false,
    clicks: u32 = 0,
    star: u64 = 0,
    fn view(p: *Page, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .gap = 8, .padding = .all(8) });
        defer ui.end(c);
        ui.text(c, "Settings", .{ .size = 24, .weight = .bold });
        ui.text(c, "Pick what syncs.", .{});
        _ = ui.checkbox(c, "Photos", &p.on);
        // A box that takes clicks, with only text in it: a button.
        const card = ui.div(c).px(8).py(4).control();
        if (card.clicked()) p.clicks += 1;
        ui.text(c, "Open stop", .{});
        ui.text(c, "2 min", .{});
        card.end();
        // An icon alone: its name in words.
        const star = ui.div(c).p(4).control();
        p.star = star.id();
        _ = star.clicked();
        ui.icon(c, "star.fill", .{});
        star.end();
        // A decoration, left out.
        const deco = ui.div(c).p(2);
        access.hide(c, deco.index);
        ui.text(c, "~~~", .{});
        deco.end();
    }
};

fn elements(t: *ui.Tester, arena: std.mem.Allocator) ![]access.Element {
    var out: std.ArrayList(access.Element) = .empty;
    try access.tree(&t.ctx, arena, &out);
    return out.items;
}

test "the tree reads text, headings, controls and implied buttons in order" {
    var p: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{});
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const els = try elements(&t, arena.allocator());
    try testing.expectEqual(@as(usize, 5), els.len);
    try testing.expectEqualStrings("Settings", els[0].label);
    try testing.expect(els[0].header);
    try testing.expectEqual(access.Role.static_text, els[0].role);
    try testing.expectEqualStrings("Pick what syncs.", els[1].label);
    try testing.expect(!els[1].header);
    try testing.expectEqual(access.Role.checkbox, els[2].role);
    try testing.expectEqualStrings("Photos", els[2].label);
    try testing.expectEqual(access.Role.button, els[3].role);
    try testing.expectEqualStrings("Open stop, 2 min", els[3].label);
    try testing.expect(els[3].implied);
    try testing.expectEqualStrings("Favorite", els[4].label);
    for (els) |e| try testing.expect(e.rect.w > 0 and e.rect.h > 0);
}

test "activating an element clicks it on the next frame" {
    var p: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{});
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const els = try elements(&t, arena.allocator());
    t.ctx.a11yPress(els[3].id);
    t.frame();
    try testing.expectEqual(@as(u32, 1), p.clicks);
    // An edge: the frame after has none.
    t.frame();
    try testing.expectEqual(@as(u32, 1), p.clicks);
    t.ctx.a11yPress(els[2].id);
    t.frame();
    try testing.expect(p.on);
}

const Described = struct {
    fn view(_: *Described, c: *ui.Context) void {
        const b = ui.div(c).p(8).control();
        access.describe(c, b.index, .{ .label = "Close", .hint = "Goes back to the map" });
        ui.text(c, "x", .{});
        b.end();
        // Rows scrolled out of view are not read.
        ui.scroll(c, .{ .height = .{ .px = 40 }, .width = .fill });
        defer ui.end(c);
        for (0..20) |i| ui.text(c, c.print("Row {d}", .{i}), .{});
    }
};

test "describe labels a box; scrolled-out text is left out" {
    var d: Described = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&d, Described.view), .{});
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const els = try elements(&t, arena.allocator());
    try testing.expectEqualStrings("Close", els[0].label);
    try testing.expectEqualStrings("Goes back to the map", els[0].hint);
    try testing.expect(!els[0].implied);
    try testing.expect(els.len > 1 and els.len < 8);
    try testing.expectEqualStrings("Row 0", els[1].label);
}

test "Dynamic Type scales text with the view's zoom" {
    try testing.expectEqual(@as(f32, 1), access.textScaleOf("UICTContentSizeCategoryL"));
    try testing.expectApproxEqAbs(@as(f32, 23.0 / 17.0), access.textScaleOf("UICTContentSizeCategoryXXXL"), 1e-6);
    try testing.expectEqual(@as(f32, 1), access.textScaleOf("nonsense"));
    try testing.expectEqualStrings("Back", access.iconWords("chevron.left"));
    try testing.expectEqualStrings("Favorite", access.iconWords("star.circle.fill"));
    try testing.expectEqualStrings("", access.iconWords("tram"));
}

test "announce keeps the last message of a frame" {
    var p: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{});
    defer t.deinit();
    access.announce(&t.ctx, "first");
    access.announce(&t.ctx, "Stop starred");
    try testing.expectEqualStrings("Stop starred", t.ctx.access.announcement[0..t.ctx.access.announcement_len]);
}

const Volume = struct {
    v: f32 = 0.5,
    fn view(s: *Volume, c: *ui.Context) void {
        ui.row(c, .{ .gap = 8 });
        defer ui.end(c);
        ui.text(c, "Volume", .{});
        _ = ui.slider(c, &s.v, .{});
    }
};

test "a slider is named by the text before it and steps a tenth" {
    var s: Volume = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Volume.view), .{});
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const els = try elements(&t, arena.allocator());
    try testing.expectEqual(@as(usize, 1), els.len);
    try testing.expectEqualStrings("Volume", els[0].label);
    try testing.expectEqualStrings("50%", els[0].value);
    try testing.expect(els[0].adjustable);
    t.ctx.a11yStep(els[0].id, 1);
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, 0.6), s.v, 0.001);
}
