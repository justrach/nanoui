//! One collection picker for a native window and a browser canvas: a
//! trigger opens a search field and a result list. Typing filters, the
//! arrows move the selection, Enter chooses, and Escape closes. Focus
//! returns to the trigger either way.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const browser = @import("builtin").os.tag == .wasi;

const Entry = struct { id: []const u8, label: []const u8 };
const entries = [_]Entry{
    .{ .id = "art", .label = "Art history" },
    .{ .id = "coffee", .label = "Café notebooks" },
    .{ .id = "design", .label = "Design references" },
    .{ .id = "japan", .label = "日本語の資料" },
    .{ .id = "music", .label = "Music scores" },
};

/// Case-insensitive for ASCII; other text matches exactly.
fn matches(label: []const u8, query: []const u8) bool {
    if (query.len > label.len) return false;
    var i: usize = 0;
    while (i + query.len <= label.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(label[i..][0..query.len], query)) return true;
    }
    return false;
}

const Picker = struct {
    query: ui.TextBuffer = .{},
    open: bool = false,
    trigger: u64 = 0,
    selected: usize = 0,
    chosen: ?usize = null,
    results: [entries.len]usize = undefined,
    count: usize = 0,

    fn deinit(s: *Picker) void {
        s.query.deinit();
    }

    fn update(s: *Picker) void {
        s.count = 0;
        s.selected = 0;
        for (entries, 0..) |entry, i| if (matches(entry.label, s.query.text())) {
            s.results[s.count] = i;
            s.count += 1;
        };
    }

    fn show(s: *Picker, c: *ui.Context) void {
        s.open = true;
        s.query.clear();
        s.query.focus();
        s.update();
        c.changed = true;
    }

    fn close(s: *Picker, c: *ui.Context) void {
        s.open = false;
        c.focus = s.trigger;
        c.changed = true;
    }

    fn choose(s: *Picker, c: *ui.Context, index: usize) void {
        s.chosen = index;
        ui.access.announce(c, entries[index].label);
        s.close(c);
    }

    fn view(s: *Picker, c: *ui.Context) void {
        c.focus_ring = .{ .color = c.theme.accent };
        const column = ui.div(c).column().wFull().p(18).gap(10);
        defer column.end();
        ui.label(c, "Collections");
        {
            ui.key(c, "open collections");
            const trigger = ui.div(c).row().p(14).rounded(6).bg(c.theme.surface).control();
            defer trigger.end();
            s.trigger = c.node(trigger.index).id;
            if (s.open) ui.access.hide(c, trigger.index) else ui.access.describe(c, trigger.index, .{ .label = "Choose collection" });
            if (c.interact(trigger.index, .{ .focusable = !s.open }).clicked and !s.open) s.show(c);
            ui.label(c, "Choose collection");
        }
        if (s.chosen) |index| ui.label(c, entries[index].label);
        if (!s.open) {
            if (c.shortcut(.{ .key = 'k', .cmd = true })) s.show(c);
            return;
        }
        // Claiming the Escape shortcut also takes Android's Back, which
        // otherwise sends the app to the background when no field has focus.
        if (c.shortcut(.{ .key = ui.Shortcut.escape }) or c.input.key == .escape) {
            c.input.key = null;
            s.close(c);
            return;
        }
        if (c.input.key == .down or c.input.key == .up) {
            if (s.count != 0) {
                s.selected = if (c.input.key == .down)
                    (s.selected + 1) % s.count
                else
                    (s.selected + s.count - 1) % s.count;
            }
            c.input.key = null;
        }
        const result = ui.textField(c, &s.query, .{ .placeholder = "Search collections", .width = .fill });
        const field = c.focus;
        if (result.changed) s.update();
        if (result.submitted and s.count != 0) {
            s.choose(c, s.results[s.selected]);
            return;
        }
        if (s.count == 0) ui.label(c, "No matching collections");
        // The results are a list box of options. Focus stays in the query,
        // which names the highlighted option as its active descendant.
        const results = ui.div(c).column().wFull().gap(10);
        ui.access.describe(c, results.index, .{ .role = .listbox, .label = "Collections" });
        if (result.focused) ui.access.controls(c, field, c.node(results.index).id);
        for (s.results[0..s.count], 0..) |index, rank| {
            ui.key(c, entries[index].id);
            const row = ui.div(c).row().p(14).wFull().rounded(6)
                .bg(if (rank == s.selected) c.theme.accent.alpha(0.18) else c.theme.surface).control();
            defer row.end();
            ui.access.describe(c, row.index, .{ .role = .option, .label = entries[index].label, .selected = rank == s.selected });
            if (c.interact(row.index, .{ .focusable = true }).clicked) s.choose(c, index);
            ui.label(c, entries[index].label);
        }
        results.end();
        // Touch screens have no Escape key.
        ui.key(c, "cancel");
        const cancel = ui.div(c).row().p(14).rounded(6).bg(c.theme.surface).control();
        defer cancel.end();
        ui.access.describe(c, cancel.index, .{ .label = "Cancel" });
        if (c.interact(cancel.index, .{ .focusable = true }).clicked) s.close(c);
        ui.label(c, "Cancel");
    }
};

pub fn main(init: std.process.Init) !void {
    var picker: Picker = .{};
    defer picker.deinit();
    if (comptime browser) {
        _ = nanoui.web.registerBundledFonts();
        _ = try nanoui.web.mount(.init(&picker, Picker.view), .{});
        nanoui.web.run();
    }
    const app = try nanoui.App.create(init, .{ .name = "Collection Picker" });
    defer app.destroy();
    _ = try app.newWindow(.{
        .title = "Collection Picker",
        .width = 520,
        .height = 460,
        .content = .{ .view = .init(&picker, Picker.view) },
    });
    try app.run();
}

test "picker composes a query, chooses by keyboard and returns focus" {
    var s: Picker = .{};
    defer s.deinit();
    var tester: ui.Tester = undefined;
    try tester.init(std.testing.allocator, .init(&s, Picker.view), .{ .width = 360, .height = 440 });
    defer tester.deinit();
    try tester.clickText("Choose collection");
    tester.textOps(&.{.{ .set_marked = .{ .text = "に", .sel_start = 3, .sel_len = 0 } }});
    tester.textOps(&.{.{ .insert = "日本" }});
    tester.settle(3);
    try std.testing.expectEqualStrings("日本", s.query.text());
    try std.testing.expectEqual(@as(usize, 1), s.count);

    var tree: std.ArrayList(ui.access.Element) = .empty;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try ui.access.tree(&tester.ctx, arena.allocator(), &tree);
    const option = for (tree.items) |item| {
        if (item.role == .option and item.container != 0 and std.mem.eql(u8, item.label, "日本語の資料")) break item;
    } else return error.MissingAccessibleResult;
    // The query keeps focus and names the highlighted option.
    for (tree.items) |item| {
        if (item.role == .text_field and item.active_descendant == option.id) break;
    } else return error.MissingActiveDescendant;

    tester.key(.enter);
    tester.settle(3);
    try std.testing.expectEqual(@as(?usize, 3), s.chosen);
    try std.testing.expectEqual(s.trigger, tester.ctx.focus);

    try tester.clickText("Choose collection");
    tester.typeText("CAF");
    tester.key(.down);
    tester.settle(3);
    try std.testing.expectEqual(@as(usize, 1), s.count);
    tester.key(.escape);
    tester.settle(3);
    try std.testing.expect(!s.open);
    try std.testing.expectEqual(s.trigger, tester.ctx.focus);
    try std.testing.expectEqual(@as(?usize, 3), s.chosen);

    // Android's Back arrives as the Escape shortcut, field focused or not.
    try tester.clickText("Choose collection");
    try std.testing.expect(tester.shortcut(.{ .key = ui.Shortcut.escape }));
    tester.settle(3);
    try std.testing.expect(!s.open);
    try std.testing.expectEqual(s.trigger, tester.ctx.focus);

    try tester.clickText("Choose collection");
    try tester.clickText("Cancel");
    tester.settle(3);
    try std.testing.expect(!s.open);
    try std.testing.expectEqual(s.trigger, tester.ctx.focus);
}
