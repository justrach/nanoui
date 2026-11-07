//! The demo as VoiceOver reads it, on any platform (`zig build test`).
const std = @import("std");
const ui = @import("nanoui").ui;
const access = ui.access;
const Demo = @import("view.zig").Demo;
const testing = std.testing;

fn read(t: *ui.Tester, arena: std.mem.Allocator) ![]access.Element {
    var out: std.ArrayList(access.Element) = .empty;
    try access.tree(&t.ctx, arena, &out);
    return out.items;
}

fn find(els: []const access.Element, label: []const u8) ?access.Element {
    for (els) |e| if (std.mem.startsWith(u8, e.label, label)) return e;
    return null;
}

test "the stops read as headings, sentences and controls, the decoration left out" {
    var d: Demo = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&d, Demo.view), .{ .width = 480, .height = 900 });
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const els = try read(&t, arena.allocator());
    try testing.expect(els[0].header);
    try testing.expectEqualStrings("Nearby stops", els[0].label);
    const suntec = find(els, "Suntec City").?;
    try testing.expectEqualStrings("Suntec City, stop 02151, next bus in 2 minutes", suntec.label);
    try testing.expectEqualStrings("Stars or unstars the stop", suntec.hint);
    try testing.expectEqual(access.Role.button, suntec.role);
    // The card's own texts are read as part of it, not again.
    try testing.expect(find(els, "2 min") == null);
    try testing.expect(find(els, "· · ·") == null);
    try testing.expect(find(els, "Settings").?.header);
    try testing.expectEqual(access.Role.slider, find(els, "Text size").?.role);
    try testing.expectEqual(access.Role.checkbox, find(els, "Arrival alerts").?.role);
}

test "pressing a stop through accessibility stars it and says so" {
    var d: Demo = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&d, Demo.view), .{ .width = 480, .height = 900 });
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const suntec = find(try read(&t, arena.allocator()), "Suntec City").?;
    t.ctx.access.announcement_len = 0;
    t.ctx.a11yPress(suntec.id);
    t.frame();
    try testing.expect(d.stops[0].starred);
    try testing.expectEqualStrings("Suntec City starred", t.ctx.access.announcement[0..t.ctx.access.announcement_len]);
    t.frame();
    const after = find(try read(&t, arena.allocator()), "Suntec City").?;
    try testing.expect(after.selected);
    try testing.expectEqualStrings("Starred", after.value);
}

test "a new page tells VoiceOver to start again at its top" {
    var d: Demo = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&d, Demo.view), .{ .width = 480, .height = 900 });
    defer t.deinit();
    t.ctx.access.screen_changed = false;
    try t.clickText("About");
    t.frame();
    try testing.expect(d.page == .about);
    try testing.expect(t.ctx.access.screen_changed);
}

test "the note field takes composed text: pinyin, then its characters" {
    var d: Demo = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&d, Demo.view), .{ .width = 480, .height = 900 });
    defer t.deinit();
    try t.clickText("Any language: 你好, こんにちは");
    t.textOps(&.{.{ .set_marked = .{ .text = "ni hao", .sel_start = 6, .sel_len = 0 } }});
    try testing.expectEqualStrings("ni hao", t.ctx.focused_text.?.text);
    t.textOps(&.{.{ .insert = "你好" }});
    try testing.expectEqualStrings("你好", d.note.text());
}
