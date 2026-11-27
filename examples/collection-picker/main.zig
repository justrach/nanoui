//! One collection picker for a native window and a browser canvas: a
//! trigger opens a search field and a result list. Typing filters, the
//! arrows move the selection, Enter chooses, and Escape closes. Focus
//! returns to the trigger either way. A second button reads one small
//! text file through the native dialog or the browser's file input.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const files = nanoui.file_picker;
const browser = @import("builtin").os.tag == .wasi;
const file_options: files.Options = .{ .extensions = &.{"txt"}, .max_bytes = 32 * 1024 };

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
    allocator: std.mem.Allocator,
    io: std.Io,
    window: ?*nanoui.Window = null,
    file_pending: bool = false,
    file_name: ui.TextBuffer = .{},
    file_size: usize = 0,
    file_preview: ui.TextBuffer = .{},
    file_message: []const u8 = "",
    query: ui.TextBuffer = .{},
    open: bool = false,
    trigger: u64 = 0,
    selected: usize = 0,
    chosen: ?usize = null,
    results: [entries.len]usize = undefined,
    count: usize = 0,

    fn deinit(s: *Picker) void {
        s.query.deinit();
        s.file_name.deinit();
        s.file_preview.deinit();
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

    fn fileResult(ctx: ?*anyopaque, result: files.Result) void {
        const s: *Picker = @ptrCast(@alignCast(ctx.?));
        s.file_name.clear();
        s.file_preview.clear();
        s.file_message = switch (result) {
            .picked => |file| blk: {
                s.file_name.set(file.name);
                s.file_size = file.bytes.len;
                const first = file.bytes[0 .. std.mem.indexOfScalar(u8, file.bytes, '\n') orelse file.bytes.len];
                if (first.len <= 120 and std.unicode.utf8ValidateSlice(first)) s.file_preview.set(first);
                break :blk "";
            },
            .cancelled => "No file chosen",
            .failed => |failure| switch (failure) {
                .too_large => "The file exceeds 32 KiB",
                else => "Could not open the file",
            },
        };
    }

    fn openNative(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Picker = @ptrCast(@alignCast(ctx.?));
        defer s.file_pending = false;
        if (s.window == null) return;
        const chosen = files.open(s.allocator, s.io, file_options) catch |err| blk: {
            fileResult(s, .{ .failed = if (err == error.FileTooLarge) .too_large else .io });
            break :blk null;
        };
        if (chosen) |file| {
            defer file.deinit(s.allocator);
            fileResult(s, .{ .picked = file.file });
        } else if (s.file_message.len == 0) {
            fileResult(s, .cancelled);
        }
        if (s.window) |win| win.redraw();
    }

    fn closed(ctx: *anyopaque, _: *nanoui.Window) void {
        const s: *Picker = @ptrCast(@alignCast(ctx));
        s.window = null;
    }

    fn fileControl(s: *Picker, c: *ui.Context) void {
        ui.key(c, "choose-text-file");
        const control = ui.div(c).row().p(14).rounded(6).bg(c.theme.surface).control();
        defer control.end();
        const label = "Choose text file";
        ui.access.describe(c, control.index, .{ .label = label, .enabled = !s.file_pending });
        const click = c.interact(control.index, .{ .focusable = true }).clicked;
        if (comptime browser) {
            files.bind(c, control.index, file_options, s, fileResult) catch {
                s.file_message = "File selection is unavailable";
            };
        } else if (click and !s.file_pending and s.window != null) {
            s.file_message = "";
            // A dialog runs its own loop: on Apple platforms open it after this event,
            // outside GCD's main queue, where other main-queue work can run.
            if (@hasDecl(nanoui.App, "soon")) {
                nanoui.App.soon(s, openNative);
                s.file_pending = true;
            } else {
                s.file_pending = nanoui.App.onMain(s, openNative);
                if (!s.file_pending) s.file_message = "Could not open the file";
            }
        }
        ui.label(c, label);
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
            if (browser or files.native) s.fileControl(c) else ui.label(c, "File selection is not available on this device");
            if (s.file_name.text().len > 0) ui.label(c, c.print("{s} ({d} bytes)", .{ s.file_name.text(), s.file_size }));
            if (s.file_preview.text().len > 0) ui.label(c, s.file_preview.text());
            if (s.file_message.len > 0) ui.label(c, s.file_message);
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
        if (result.changed) s.update();
        if (result.submitted and s.count != 0) {
            s.choose(c, s.results[s.selected]);
            return;
        }
        if (s.count == 0) ui.label(c, "No matching collections");
        for (s.results[0..s.count], 0..) |index, rank| {
            ui.key(c, entries[index].id);
            const row = ui.div(c).row().p(14).wFull().rounded(6)
                .bg(if (rank == s.selected) c.theme.accent.alpha(0.18) else c.theme.surface).control();
            defer row.end();
            ui.access.describe(c, row.index, .{ .label = entries[index].label, .selected = rank == s.selected });
            if (c.interact(row.index, .{ .focusable = true }).clicked) s.choose(c, index);
            ui.label(c, entries[index].label);
        }
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
    var picker: Picker = .{ .allocator = init.gpa, .io = init.io };
    defer picker.deinit();
    if (comptime browser) {
        _ = nanoui.web.registerBundledFonts();
        _ = try nanoui.web.mount(.init(&picker, Picker.view), .{});
        nanoui.web.run();
    }
    const app = try nanoui.App.create(init, .{ .name = "Collection Picker" });
    defer app.destroy();
    picker.window = try app.newWindow(.{
        .title = "Collection Picker",
        .width = 520,
        .height = 460,
        .content = .{ .view = .init(&picker, Picker.view) },
        .on_close = .{ .ctx = &picker, .func = Picker.closed },
    });
    try app.run();
}

test "picker composes a query, chooses by keyboard and returns focus" {
    var s: Picker = .{ .allocator = std.testing.allocator, .io = std.testing.io };
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
    for (tree.items) |item| {
        if (item.role == .button and std.mem.eql(u8, item.label, "日本語の資料")) break;
    } else return error.MissingAccessibleResult;

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
