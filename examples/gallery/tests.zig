//! Offscreen `ui.Tester` tests for the gallery: every page at desktop and
//! phone sizes (and idle quiescence), the `⌘K` command palette, the Studio
//! dock + folded tool timeline + composer, and captioned password field
//! accessibility redaction.
const std = @import("std");
const testing = std.testing;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const main_mod = @import("main.zig");
const phone = @import("phone.zig");
const Gallery = main_mod.Gallery;

fn initGallery(g: *Gallery) void {
    g.add("Write a UI toolkit in Zig");
    g.add("Draw it with Metal");
    g.add("Ship it");
    g.items[1].done = true;
}

test "every gallery page builds and settles at desktop and phone sizes" {
    var g: Gallery = .{};
    defer g.deinit();
    initGallery(&g);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&g, Gallery.view), .{ .width = 960, .height = 640 });
    defer t.deinit();

    for (0..phone.pages.len) |i| {
        g.page = i;
        t.settle(2);
        try testing.expect(t.ctx.nodes.items.len > 4);
        // Pages 4 (Glass), 5 (Motion), and 6 (Kit) run continuous keyframe showcases.
        if (i != 4 and i != 5 and i != 6) {
            try testing.expect(!t.ctx.animating);
            try testing.expect(t.ctx.frame_in == null);
        }
    }

    t.resize(390, 844);
    t.settle(2);
    try testing.expect(t.hasText("Studio"));
    try t.clickText("Studio");
    t.settle(2);
    try testing.expect(g.open);
    try testing.expectEqual(@as(usize, 7), g.page);
    try testing.expect(t.hasText("Transcript"));

    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    t.settle(2);
    try testing.expect(!g.open);
}

test "command palette opens on shortcut, filters, navigates, and closes on escape" {
    var g: Gallery = .{};
    defer g.deinit();
    initGallery(&g);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&g, Gallery.view), .{ .width = 960, .height = 640 });
    defer t.deinit();
    t.settle(1);

    try testing.expect(t.shortcut(.{ .key = 'k', .cmd = true }));
    t.settle(1);
    try testing.expect(g.palette.open);
    try testing.expect(t.hasText("Jump to a page or run an action…"));

    t.typeText("studio");
    t.frame();
    _ = t.shortcut(.{ .key = ui.Shortcut.enter });
    t.settle(1);
    try testing.expect(!g.palette.open);
    try testing.expectEqual(@as(usize, 7), g.page);

    try testing.expect(t.shortcut(.{ .key = 'k', .cmd = true }));
    t.settle(1);
    try testing.expect(g.palette.open);
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    t.settle(1);
    try testing.expect(!g.palette.open);
}

test "studio folded tool timeline expands and composer appends note" {
    var g: Gallery = .{ .page = 7 };
    defer g.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&g, Gallery.view), .{ .width = 960, .height = 640 });
    defer t.deinit();
    t.settle(2);

    try testing.expect(t.hasText("Ran 3 checks"));
    try testing.expect(!t.hasText("access.tree · verified 0 unlabeled controls"));
    try testing.expect(!t.ctx.animating);
    try testing.expect(t.ctx.frame_in == null);

    try t.clickText("Ran 3 checks");
    t.settle(1);
    try testing.expect(t.hasText("access.tree · verified 0 unlabeled controls"));

    try t.clickText("Append a note to transcript…");
    t.typeText("ship it");
    try t.clickText("Send");
    t.settle(1);
    try testing.expect(t.hasText("Queued note: ship it"));
}

test "controls password field has caption label and redacts value in accessibility tree" {
    var g: Gallery = .{ .page = 0 };
    defer g.deinit();
    g.secret.set("s3cr3t");
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&g, Gallery.view), .{ .width = 960, .height = 960 });
    defer t.deinit();
    t.settle(1);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var els: std.ArrayList(ui.access.Element) = .empty;
    try ui.access.tree(&t.ctx, arena.allocator(), &els);

    var found_password = false;
    for (els.items) |el| {
        if (el.role == .text_field and std.mem.eql(u8, el.label, "Password")) {
            found_password = true;
            try testing.expectEqualStrings("", el.value);
        }
        try testing.expect(std.mem.indexOf(u8, el.value, "s3cr3t") == null);
    }
    try testing.expect(found_password);
}
