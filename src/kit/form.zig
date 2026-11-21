//! Choosing and entering: radio groups, selects (a button that opens a
//! list, moved through with the arrow keys), number inputs with − and +,
//! and fields: a label over a control with a hint or an error under it.
const std = @import("std");
const ui = @import("../ui/ui.zig");
const kit = @import("kit.zig");
const overlay = @import("overlay.zig");

/// One of `options`; true when `selected.*` changed.
pub fn radioGroup(c: *ui.Context, options: []const []const u8, selected: *usize, opts: struct { horizontal: bool = false, disabled: bool = false }) bool {
    const t = kit.tokens(c);
    const g = if (opts.horizontal) ui.div(c).row().gap(16).itemsCenter() else ui.div(c).column().gap(8);
    defer g.end();
    var changed = false;
    for (options, 0..) |label, i| {
        ui.key(c, c.print("radio-{d}", .{i}));
        const on = i == selected.*;
        const r = ui.div(c).row().gap(8).itemsCenter().control();
        const it = r.interaction();
        if (opts.disabled) c.node(r.index).style.opacity = 0.45;
        defer r.end();
        if (it.clicked and !on and !opts.disabled) {
            selected.* = i;
            changed = true;
            c.changed = true;
        }
        const ring = ui.div(c).w(16).h(16).roundedFull().circular().center().border(if (on) t.primary else t.border).borderW(if (on) 5 else 1.5).bg(t.surface);
        ring.end();
        ui.text(c, label, .{ .size = 13, .color = t.foreground });
    }
    return changed;
}

/// A button showing `options[selected.*]` that opens the list; true when
/// the choice changed. Up and Down move through the open list, Return
/// takes it.
pub fn select(c: *ui.Context, id: []const u8, options: []const []const u8, selected: *?usize, opts: struct { placeholder: []const u8 = "Choose…", width: f32 = 200, disabled: bool = false }) bool {
    const t = kit.tokens(c);
    const state = c.state(SelectState, id);
    ui.key(c, c.print("{s}-button", .{id}));
    const label = if (selected.*) |i| (if (i < options.len) options[i] else opts.placeholder) else opts.placeholder;
    const b = ui.div(c).row().w(opts.width).h(kit.Size.md.height()).px(10).gap(6).itemsCenter().rounded(t.radius).bg(t.surface).border(if (state.open) t.primary else t.border).control();
    const it = b.interaction();
    if (opts.disabled) c.node(b.index).style.opacity = 0.45;
    {
        defer b.end();
        ui.text(c, label, .{ .size = 13, .color = if (selected.* == null) t.muted else t.foreground });
        ui.spacer(c);
        ui.icon(c, "chevron.up.chevron.down", .{ .size = 10, .color = t.muted });
    }
    if (it.clicked and !opts.disabled) {
        state.open = !state.open;
        state.hot = selected.* orelse 0;
        c.changed = true;
    }
    var changed = false;
    const p = overlay.popover(c, c.print("{s}-list", .{id}), &state.open, it.rect, .{ .width = opts.width, .padding = 4, .gap = 4 }) orelse return false;
    defer p.end();
    if (state.open) {
        if (c.shortcut(.{ .key = ui.Shortcut.down })) state.hot = @min(state.hot + 1, options.len -| 1);
        if (c.shortcut(.{ .key = ui.Shortcut.up })) state.hot -|= 1;
        if (c.shortcut(.{ .key = ui.Shortcut.enter }) and options.len > 0) {
            changed = selected.* != state.hot;
            selected.* = state.hot;
            state.open = false;
        }
    }
    for (options, 0..) |o, i| {
        ui.key(c, c.print("opt-{d}", .{i}));
        const row = ui.div(c).row().wFull().h(28).px(8).gap(8).itemsCenter().rounded(t.radius - 2).control();
        const ri = row.interaction();
        if (ri.hovered) state.hot = i;
        if (i == state.hot) c.node(row.index).style.background = t.surface_hover;
        defer row.end();
        const box = ui.div(c).w(12).center();
        if (selected.* == i) ui.icon(c, "checkmark", .{ .size = 10, .weight = .semibold, .color = t.primary });
        box.end();
        ui.text(c, o, .{ .size = 13, .color = t.foreground });
        if (ri.clicked) {
            changed = selected.* != i;
            selected.* = i;
            state.open = false;
        }
    }
    if (changed or !state.open) c.changed = true;
    return changed;
}

const SelectState = struct { open: bool = false, hot: usize = 0 };

/// A number with − and + either side; true when it changed.
pub fn numberInput(c: *ui.Context, value: *f64, opts: struct { min: f64 = -std.math.inf(f64), max: f64 = std.math.inf(f64), step: f64 = 1, decimals: u8 = 0, width: f32 = 140 }) bool {
    const t = kit.tokens(c);
    const r = ui.div(c).row().w(opts.width).h(kit.Size.md.height()).itemsCenter().rounded(t.radius).bg(t.surface).border(t.border).clip();
    defer r.end();
    const before = value.*;
    ui.key(c, "minus");
    if (kit.iconButton(c, "minus", .{ .size = .sm, .disabled = value.* <= opts.min }).clicked) value.* = @max(opts.min, value.* - opts.step);
    {
        const mid = ui.div(c).grow().center();
        defer mid.end();
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ value.*, opts.decimals }) catch "";
        ui.text(c, c.print("{s}", .{s}), .{ .size = 13, .mono = true, .color = t.foreground });
    }
    ui.key(c, "plus");
    if (kit.iconButton(c, "plus", .{ .size = .sm, .disabled = value.* >= opts.max }).clicked) value.* = @min(opts.max, value.* + opts.step);
    if (value.* != before) c.changed = true;
    return value.* != before;
}

/// A form field: its label, then the control (draw it, then `end`), then a
/// hint, or the error in red.
pub const Field = struct {
    c: *ui.Context,
    box: ui.Div,
    hint: []const u8,
    err: []const u8,
    pub fn end(f: Field) void {
        const t = kit.tokens(f.c);
        if (f.err.len > 0) {
            ui.text(f.c, f.err, .{ .size = 11.5, .color = t.danger });
        } else if (f.hint.len > 0) ui.text(f.c, f.hint, .{ .size = 11.5, .color = t.muted });
        f.box.end();
    }
};

pub fn field(c: *ui.Context, label: []const u8, opts: struct { hint: []const u8 = "", err: []const u8 = "", required: bool = false }) Field {
    const t = kit.tokens(c);
    const box = ui.div(c).column().gap(5);
    {
        const r = ui.div(c).row().gap(3);
        defer r.end();
        ui.text(c, label, .{ .size = 12.5, .weight = .medium, .color = t.foreground });
        if (opts.required) ui.text(c, "*", .{ .size = 12.5, .color = t.danger });
    }
    return .{ .c = c, .box = box, .hint = opts.hint, .err = opts.err };
}
