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
const catalog = @import("catalog.zig");
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

    for (0..catalog.page_count) |i| {
        g.page = i;
        t.settle(2);
        try testing.expect(t.ctx.nodes.items.len > 4);
        // The desktop shows the Kit demo as its components' pages.
        if (i == catalog.kit_demo) try testing.expectEqual(@as(usize, catalog.first_component), g.page);
        // Glass, Motion and the components that move on their own (a
        // spinner, a skeleton's breath, an indeterminate bar) keep drawing.
        const id = if (catalog.component(g.page)) |comp| comp.id else "";
        const moving = i == 4 or i == 5 or std.mem.eql(u8, id, "spinner") or std.mem.eql(u8, id, "skeleton") or std.mem.eql(u8, id, "progress");
        if (!moving) {
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

test "controls scroll probe reports received and consumed deltas" {
    var g: Gallery = .{};
    defer g.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&g, Gallery.view), .{ .width = 960, .height = 1200 });
    defer t.deinit();
    t.settle(1);

    const prompt = t.findText("Mouse wheel or two-finger trackpad.").?;
    const x = prompt.x + prompt.w / 2;
    const y = prompt.y + prompt.h / 2;
    t.moveTo(x, y);
    t.ctx.input.precise = true;
    t.ctx.input.scroll_phase = .began;
    t.scroll(x, y, -32);
    try testing.expectEqual(@as(f32, -32), g.scroll_received_y);
    try testing.expectEqual(@as(f32, 32), g.scroll_consumed_y);
    try testing.expect(g.scroll_precise);
    try testing.expectEqualStrings("began", g.scroll_phase);
    try testing.expect(t.hasText("Input x 0.0 y -32.0"));
    try testing.expect(t.hasText("Mode precise | phase began"));

    t.scroll(x, y, -300);
    try testing.expectEqual(@as(f32, -300), g.scroll_received_y);
    try testing.expectEqual(@as(f32, 148), g.scroll_consumed_y);
    try testing.expectEqual(@as(f32, 180), g.scroll_probe_y);
    t.scroll(x, y, -40);
    try testing.expectEqual(@as(f32, -40), g.scroll_received_y);
    try testing.expectEqual(@as(f32, 0), g.scroll_consumed_y);

    t.hscroll(x, y, -18);
    try testing.expectEqual(@as(f32, -18), g.scroll_received_x);
    try testing.expectEqual(@as(f32, 18), g.scroll_consumed_x);
    try testing.expectEqual(@as(f32, 18), g.scroll_probe_x);

    t.ctx.input.precise = false;
    t.ctx.input.scroll_phase = .none;
    t.scroll(x, y, 15);
    try testing.expectEqual(@as(f32, 15), g.scroll_received_y);
    try testing.expectEqual(@as(f32, -15), g.scroll_consumed_y);
    try testing.expectEqual(@as(f32, 165), g.scroll_probe_y);
    try testing.expect(!g.scroll_precise);
    try testing.expectEqualStrings("none", g.scroll_phase);

    g.page = 0;
    g.open = true;
    t.resize(390, 844);
    t.settle(2);
    try testing.expect(t.hasText("Scroll input"));
}

test "the sidebar files components in groups that open, and a jump opens the group it lands in" {
    var g: Gallery = .{};
    defer g.deinit();
    initGallery(&g);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&g, Gallery.view), .{ .width = 1040, .height = 760 });
    defer t.deinit();
    t.settle(2);
    try testing.expect(t.hasText("FOUNDATIONS") and t.hasText("COMPONENTS") and t.hasText("DEMOS"));
    // Shut, a group's members are not drawn.
    try testing.expect(!t.hasText("Icon button"));
    try t.clickText("Buttons");
    t.settle(30);
    try t.clickText("Icon button");
    t.settle(2);
    try testing.expectEqual(catalog.find("icon-button"), g.page);
    try testing.expect(t.containsText("src/kit/button.zig"));
    // A page reached another way (the palette, the command line) opens its group.
    g.page = catalog.find("dialog").?;
    t.settle(30);
    try testing.expect(t.hasText("Sheet"));
}

test "the foundations list the theme's colors and filter the icons" {
    var g: Gallery = .{ .page = catalog.colors };
    defer g.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&g, Gallery.view), .{ .width = 1040, .height = 760 });
    defer t.deinit();
    t.settle(2);
    try testing.expect(t.hasText("accent") and t.hasText("#0a84ff"));
    g.page = catalog.icons;
    t.settle(2);
    try testing.expect(t.containsText(c_count(&g)));
    g.foundations.icon_search.set("chevron");
    t.settle(2);
    try testing.expect(t.hasText("chevron.down"));
    try testing.expect(!t.hasText("trash"));
}

fn c_count(_: *Gallery) []const u8 {
    const S = struct {
        var buf: [32]u8 = undefined;
    };
    return std.fmt.bufPrint(&S.buf, "{d} icons", .{ui.icons.all.len}) catch "";
}

test {
    _ = catalog;
}
