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

const Login = struct {
    name: ui.TextBuffer = .{},
    secret: ui.TextBuffer = .{},
    fn view(l: *Login, c: *ui.Context) void {
        ui.column(c, .{ .gap = 8, .padding = .all(8) });
        defer ui.end(c);
        _ = ui.textField(c, &l.name, .{ .placeholder = "Name" });
        _ = ui.textField(c, &l.secret, .{ .placeholder = "Password", .password = true });
    }
};

test "a password field's text isn't told to a screen reader, a plain field's is" {
    var l: Login = .{};
    l.name.set("ada");
    l.secret.set("hunter2");
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&l, Login.view), .{});
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const els = try elements(&t, arena.allocator());
    try testing.expectEqual(@as(usize, 2), els.len);
    try testing.expectEqual(access.Role.text_field, els[0].role);
    try testing.expectEqualStrings("ada", els[0].value);
    try testing.expectEqual(access.Role.text_field, els[1].role);
    try testing.expectEqualStrings("Password", els[1].label);
    try testing.expectEqualStrings("", els[1].value);
}

const CaptionedLogin = struct {
    user: ui.TextBuffer = .{},
    secret: ui.TextBuffer = .{},

    fn view(s: *CaptionedLogin, c: *ui.Context) void {
        ui.column(c, .{ .gap = 8, .padding = .all(8) });
        defer ui.end(c);
        {
            ui.row(c, .{ .gap = 8, .align_items = .center });
            defer ui.end(c);
            ui.text(c, "Username", .{});
            _ = ui.textField(c, &s.user, .{ .width = .{ .px = 160 } });
        }
        {
            ui.row(c, .{ .gap = 8, .align_items = .center });
            defer ui.end(c);
            ui.text(c, "Password", .{});
            _ = ui.textField(c, &s.secret, .{ .password = true, .width = .{ .px = 160 } });
        }
    }
};

test "text fields without placeholders take their row caption instead of typed text or bullets" {
    var form: CaptionedLogin = .{};
    defer {
        form.user.deinit();
        form.secret.deinit();
    }
    form.user.set("ada");
    form.secret.set("hunter2");
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&form, CaptionedLogin.view), .{});
    defer t.deinit();
    t.frame();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const els = try elements(&t, arena.allocator());
    try testing.expectEqual(@as(usize, 2), els.len);
    try testing.expectEqual(access.Role.text_field, els[0].role);
    try testing.expectEqualStrings("Username", els[0].label);
    try testing.expectEqualStrings("ada", els[0].value);
    try testing.expectEqual(access.Role.text_field, els[1].role);
    try testing.expectEqualStrings("Password", els[1].label);
    try testing.expectEqualStrings("", els[1].value);
}

const Lists = struct {
    fn row(c: *ui.Context, role: access.Role, label: []const u8, selected: bool) void {
        const r = ui.div(c).p(4).control();
        defer r.end();
        access.describe(c, r.index, .{ .role = role, .label = label, .selected = selected });
        _ = r.clicked();
        ui.text(c, label, .{});
    }

    fn view(_: *Lists, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .gap = 4, .padding = .all(8) });
        defer ui.end(c);
        ui.text(c, "Library", .{ .size = 30, .weight = .bold });
        ui.text(c, "Recent", .{ .size = 22, .weight = .bold });
        const title = ui.div(c).p(2);
        access.describe(c, title.index, .{ .role = .static_text, .label = "Shelves", .header = true, .level = 3 });
        ui.text(c, "Shelves", .{});
        title.end();
        {
            const tabs = ui.div(c).row().gap(4);
            defer tabs.end();
            access.describe(c, tabs.index, .{ .role = .list, .label = "Views" });
            row(c, .tab, "Grid", true);
            row(c, .tab, "Table", false);
        }
        {
            const results = ui.div(c).column().gap(4);
            defer results.end();
            access.describe(c, results.index, .{ .role = .list, .label = "Results" });
            row(c, .row, "Atlas", true);
            row(c, .row, "Bestiary", false);
        }
        row(c, .button, "Done", false);
    }
};

test "headings carry a level, and a list keeps its rows and tabs as elements" {
    var p: Lists = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Lists.view), .{ .width = 400, .height = 500 });
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const els = try elements(&t, arena.allocator());
    // Library, Recent, Shelves, Views, Grid, Table, Results, Atlas, Bestiary, Done.
    try testing.expectEqual(@as(usize, 10), els.len);
    try testing.expectEqual(@as(u8, 1), els[0].level);
    try testing.expectEqual(@as(u8, 2), els[1].level);
    try testing.expect(els[2].header);
    try testing.expectEqual(@as(u8, 3), els[2].level);
    const views = els[3];
    try testing.expectEqual(access.Role.list, views.role);
    try testing.expectEqualStrings("Views", views.label);
    for (els[4..6], [_][]const u8{ "Grid", "Table" }) |e, label| {
        try testing.expectEqual(access.Role.tab, e.role);
        try testing.expectEqualStrings(label, e.label);
        try testing.expectEqual(views.id, e.container);
    }
    try testing.expect(els[4].selected and !els[5].selected);
    const results = els[6];
    try testing.expectEqual(access.Role.list, results.role);
    for (els[7..9]) |e| {
        try testing.expectEqual(access.Role.row, e.role);
        try testing.expectEqual(results.id, e.container);
    }
    try testing.expectEqual(@as(u64, 0), els[9].container);
    try testing.expectEqual(@as(u64, 0), els[0].container);
}

const Clipped = struct {
    fn view(_: *Clipped, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .gap = 4, .padding = .all(8) });
        defer ui.end(c);
        // A list with no area of its own, whose rows still show below it.
        const empty = ui.div(c).column().h(0);
        access.describe(c, empty.index, .{ .role = .list, .label = "Empty" });
        Lists.row(c, .row, "Stray", false);
        empty.end();
        {
            const outer = ui.div(c).column().p(2);
            defer outer.end();
            access.describe(c, outer.index, .{ .role = .list, .label = "Outer" });
            const inner = ui.div(c).column().h(0);
            access.describe(c, inner.index, .{ .role = .list, .label = "Inner" });
            Lists.row(c, .row, "Nested", false);
            inner.end();
        }
    }
};

test "rows of a list that is not published name no container, or the one around it" {
    var p: Clipped = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Clipped.view), .{ .width = 400, .height = 300 });
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const els = try elements(&t, arena.allocator());
    var outer: u64 = 0;
    for (els) |e| {
        try testing.expect(!std.mem.eql(u8, e.label, "Empty") and !std.mem.eql(u8, e.label, "Inner"));
        if (std.mem.eql(u8, e.label, "Outer")) outer = e.id;
    }
    try testing.expect(outer != 0);
    var seen: u32 = 0;
    for (els) |e| {
        if (std.mem.eql(u8, e.label, "Stray")) {
            try testing.expectEqual(@as(u64, 0), e.container);
            seen += 1;
        }
        if (std.mem.eql(u8, e.label, "Nested")) {
            try testing.expectEqual(outer, e.container);
            seen += 1;
        }
        // Every container named is published.
        if (e.container != 0) {
            var found = false;
            for (els) |o| found = found or o.id == e.container;
            try testing.expect(found);
        }
    }
    try testing.expectEqual(@as(u32, 2), seen);
}

const Results = struct {
    query: ui.TextBuffer = .{},
    window: bool = false,
    hide_box: bool = false,
    disabled_pick: bool = false,
    fn view(p: *Results, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .gap = 4, .padding = .all(8) });
        defer ui.end(c);
        _ = ui.textField(c, &p.query, .{ .placeholder = "Find", .width = .fill });
        const field = c.focus;
        const list = ui.div(c).column().wFull();
        if (p.hide_box) access.hide(c, list.index);
        access.describe(c, list.index, .{ .role = .listbox, .label = "Results" });
        access.controls(c, field, c.node(list.index).id);
        ui.text(c, "Recent", .{});
        const labels = [_][]const u8{ "Alpha", "Beta", "Gamma" };
        for (labels, 0..) |l, k| {
            const row = ui.div(c).row().p(4).control();
            access.describe(c, row.index, .{
                .role = .option,
                .label = l,
                .selected = k == 1,
                .enabled = !(p.disabled_pick and k == 1),
                .position = if (p.window) @intCast(k + 11) else 0,
                .set_size = if (p.window) 40 else 0,
            });
            ui.text(c, l, .{});
            row.end();
        }
        list.end();
        const legacy = ui.div(c).row().p(4).control();
        c.addA11y(legacy.index, .row, "Legacy", "", true, true);
        ui.text(c, "Legacy", .{});
        legacy.end();
    }
};

fn find(els: []const access.Element, label: []const u8) access.Element {
    for (els) |e| if (std.mem.eql(u8, e.label, label)) return e;
    unreachable;
}

test "a listbox publishes its options with their place, and a field its active option" {
    var p: Results = .{};
    defer p.query.deinit();
    p.query.focus();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Results.view), .{});
    defer t.deinit();
    t.frame();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const els = try elements(&t, arena.allocator());
    const box = find(els, "Results");
    try testing.expectEqual(access.Role.listbox, box.role);
    try testing.expectEqual(@as(u64, 0), box.container);
    // The heading inside it is its child too, but not an option.
    const recent = find(els, "Recent");
    try testing.expectEqual(box.id, recent.container);
    try testing.expectEqual(@as(u32, 0), recent.position);
    const beta = find(els, "Beta");
    try testing.expectEqual(box.id, beta.container);
    try testing.expectEqual(@as(u32, 2), beta.position);
    try testing.expectEqual(@as(u32, 3), beta.set_size);
    var field: ?access.Element = null;
    for (els) |e| if (e.role == .text_field) {
        field = e;
    };
    try testing.expectEqual(box.id, field.?.controls);
    try testing.expectEqual(beta.id, field.?.active_descendant);
    // Rows outside any listbox are unchanged.
    const legacy = find(els, "Legacy");
    try testing.expectEqual(access.Role.row, legacy.role);
    try testing.expectEqual(@as(u64, 0), legacy.container);
    try testing.expectEqual(@as(u32, 0), legacy.position);
    try testing.expect(legacy.selected);
}

test "a window of results keeps its place; a disabled or hidden choice is not active" {
    var p: Results = .{ .window = true };
    defer p.query.deinit();
    p.query.focus();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Results.view), .{});
    defer t.deinit();
    t.frame();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var els = try elements(&t, arena.allocator());
    try testing.expectEqual(@as(u32, 12), find(els, "Beta").position);
    try testing.expectEqual(@as(u32, 40), find(els, "Beta").set_size);
    p.disabled_pick = true;
    t.frame();
    els = try elements(&t, arena.allocator());
    for (els) |e| if (e.role == .text_field) try testing.expectEqual(@as(u64, 0), e.active_descendant);
    p.hide_box = true;
    t.frame();
    els = try elements(&t, arena.allocator());
    for (els) |e| {
        try testing.expect(e.role != .listbox and e.role != .option);
        if (e.role == .text_field) try testing.expectEqual(@as(u64, 0), e.active_descendant);
    }
}

const Long = struct {
    clip: bool = false,
    fn view(p: *Long, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .gap = 4, .padding = .all(8) });
        defer ui.end(c);
        const box = if (p.clip) ui.div(c).column().wFull().h(90).clip() else ui.div(c).column().wFull().maxH(90).scrollY();
        defer box.end();
        access.describe(c, box.index, .{ .role = .listbox, .label = "Commands" });
        for (0..30) |k| {
            ui.key(c, c.print("long-{d}", .{k}));
            const row = ui.div(c).row().p(4).control();
            // A hidden option is not one of the set.
            if (k == 0 and p.clip) access.hide(c, row.index);
            access.describe(c, row.index, .{ .role = .option, .label = c.print("Command {d}", .{k + 1}), .selected = k == 0 });
            ui.text(c, c.print("Command {d}", .{k + 1}), .{});
            row.end();
        }
    }
};

/// The options published, in order, checked against their listbox.
fn shownOptions(els: []const access.Element, box: u64, set_size: u32) !struct { first: u32, count: u32 } {
    var first: u32 = 0;
    var count: u32 = 0;
    for (els) |e| if (e.role == .option) {
        try testing.expectEqual(box, e.container);
        try testing.expectEqual(set_size, e.set_size);
        if (count == 0) first = e.position else try testing.expectEqual(first + count, e.position);
        count += 1;
    };
    return .{ .first = first, .count = count };
}

test "options scrolled out of view still count toward each option's place and the set size" {
    var p: Long = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Long.view), .{ .width = 300, .height = 300 });
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var els = try elements(&t, arena.allocator());
    const box = find(els, "Commands").id;
    const top = try shownOptions(els, box, 30);
    try testing.expectEqual(@as(u32, 1), top.first);
    try testing.expect(top.count > 0 and top.count < 30);
    t.scroll(100, 60, -200);
    t.settle(2);
    els = try elements(&t, arena.allocator());
    const scrolled = try shownOptions(els, box, 30);
    try testing.expect(scrolled.first > 1);
    try testing.expect(scrolled.count > 0 and scrolled.count < 30);
}

test "options clipped by their listbox count; a hidden one does not" {
    var p: Long = .{ .clip = true };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Long.view), .{ .width = 300, .height = 300 });
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const els = try elements(&t, arena.allocator());
    const shown = try shownOptions(els, find(els, "Commands").id, 29);
    try testing.expectEqual(@as(u32, 1), shown.first);
    try testing.expectEqualStrings("Command 2", find(els, "Command 2").label);
    try testing.expect(shown.count < 29);
}
