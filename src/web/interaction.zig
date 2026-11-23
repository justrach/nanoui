//! Synchronous browser boundary. JS copies published data before returning.
const std = @import("std");
const web = @import("web.zig");
const ui = @import("../ui/ui.zig");

extern "nanoui_web" fn semantics_enabled() bool;
extern "nanoui_web" fn publish_semantics(bytes: [*]const u8, len: usize) void;

const Item = struct {
    id: u64,
    role: ui.access.Role,
    label: []const u8,
    rect: ui.Rect,
    selected: bool,
    enabled: bool,
    header: bool,
    password: bool,
    file_picker: ?@import("file_bridge.zig").Descriptor,
};
const Focus = struct {
    id: u64,
    rect: ui.Rect,
    selection: []const u8,
    password: bool,
};
var text_bytes: [64 * 1024]u8 = undefined;

pub fn publish(s: *web.Surface) void {
    if (!semantics_enabled()) return;
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var tree: std.ArrayList(ui.access.Element) = .empty;
    ui.access.tree(&s.ctx, a, &tree) catch return;
    const items = a.alloc(Item, tree.items.len) catch return;
    var buttons = s.files.buttons.valueIterator();
    while (buttons.next()) |button| button.published = false;
    for (items, tree.items) |*item, el| item.* = .{
        .id = el.id,
        .role = el.role,
        .label = el.label,
        .rect = el.rect,
        .selected = el.selected,
        .enabled = el.enabled,
        .header = el.header,
        .password = el.password,
        .file_picker = if (el.role == .button and el.enabled) s.files.descriptor(el.id) else null,
    };
    s.files.discardStale(s.gpa);
    const focused: ?Focus = if (s.ctx.focused_text) |f| blk: {
        const lo = @min(f.text.len, @min(f.anchor, f.caret));
        const hi = @min(f.text.len, @max(f.anchor, f.caret));
        break :blk .{
            .id = f.id,
            .rect = f.caret_rect,
            .selection = if (s.ctx.focused_password) "" else f.text[lo..hi],
            .password = s.ctx.focused_password,
        };
    } else null;
    var out: std.Io.Writer.Allocating = .init(a);
    std.json.Stringify.value(.{
        .items = items,
        .focus = focused,
        .focused_id = s.ctx.focus,
        .announcement = s.ctx.access.announcement[0..s.ctx.access.announcement_len],
    }, .{ .emit_nonportable_numbers_as_strings = true }, &out.writer) catch return;
    s.ctx.access.announcement_len = 0;
    publish_semantics(out.written().ptr, out.written().len);
}

export fn nanoui_web_text_buffer() [*]u8 {
    return &text_bytes;
}

export fn nanoui_web_text(id: u64, len: usize, cut: bool) void {
    const s = web.active orelse return;
    const f = s.ctx.focused_text orelse return;
    if (s.ctx.focus != id or f.id != id or len > text_bytes.len) return;
    if (cut) {
        const lo = @min(f.anchor, f.caret);
        const hi = @max(f.anchor, f.caret);
        if (s.ctx.focused_password or hi > f.text.len or lo == hi or
            !std.mem.eql(u8, f.text[lo..hi], text_bytes[0..len])) return;
        s.text_op[0] = .{ .command = .cut };
    } else {
        const bytes = text_bytes[0..len];
        if (!std.unicode.utf8ValidateSlice(bytes) or len == 0) return;
        s.text_op[0] = .{ .insert = bytes };
    }
    s.ctx.input.ops = &s.text_op;
    s.requestFrame();
}

export fn nanoui_web_access(id: u64, activate: bool) void {
    const s = web.active orelse return;
    // Check the current frame because the action waits in the host input queue.
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    var tree: std.ArrayList(ui.access.Element) = .empty;
    ui.access.tree(&s.ctx, arena.allocator(), &tree) catch return;
    for (tree.items) |item| {
        if (item.id != id or !item.enabled) continue;
        switch (item.role) {
            .text_field => if (activate) return,
            .button, .tab, .checkbox, .switch_toggle, .radio_button, .row, .menu_button, .link => {},
            else => return,
        }
        if (activate) s.ctx.a11yPress(id) else s.ctx.focus = id;
        s.requestFrame();
        return;
    }
}
