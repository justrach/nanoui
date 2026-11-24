//! Dialogs and sheets: a panel over the page, which dims behind it. A
//! dialog grows in at the center with a title, a description, what the
//! app puts in it, and OK and Cancel; a sheet slides in from an edge.
//! Escape, the ✕, Cancel or (if allowed) a click on the dimming closes
//! them, setting the app's `open` to false; they leave with motion.
const std = @import("std");
const ui = @import("../ui/ui.zig");
const kit = @import("kit.zig");
const motion = ui.motion;

pub const layer_backdrop = 10;
pub const layer_panel = 11;

pub const Options = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    width: f32 = 440,
    /// The buttons at the bottom ("" leaves one out).
    ok: []const u8 = "OK",
    cancel: []const u8 = "Cancel",
    ok_variant: kit.Variant = .primary,
    /// A click on the dimming closes it.
    overlay_closable: bool = true,
    close_button: bool = true,
};

/// What a dialog's buttons did this frame.
pub const Result = enum { none, ok, cancel };

/// An open dialog: draw its content, then `end`, which says whether OK or
/// Cancel was chosen (then it closes).
pub const Dialog = struct {
    c: *ui.Context,
    open: *bool,
    opts: Options,
    panel: ui.Div,
    body: ui.Div,

    pub fn end(d: Dialog) Result {
        const c = d.c;
        d.body.end();
        defer d.panel.end();
        if (d.opts.ok.len == 0 and d.opts.cancel.len == 0) return .none;
        const f = ui.div(c).row().wFull().gap(8).justifyEnd().pt(4);
        defer f.end();
        if (d.opts.cancel.len > 0 and kit.button(c, d.opts.cancel, .{}).clicked) {
            close(c, d.open);
            return .cancel;
        }
        if (d.opts.ok.len > 0 and kit.button(c, d.opts.ok, .{ .variant = d.opts.ok_variant }).clicked) {
            close(c, d.open);
            return .ok;
        }
        return .none;
    }
};

fn close(c: *ui.Context, open: *bool) void {
    open.* = false;
    c.changed = true;
}

/// The dimming behind a panel; true when it was clicked.
fn backdrop(c: *ui.Context, key: []const u8, show: bool) bool {
    const t = kit.tokens(c);
    const f = motion.present(c, key, show, .{ .initial = .{ .opacity = 0 }, .exit = .{ .opacity = 0 }, .transition = .{ .tween = .{ .duration = 0.18 } } }) orelse return false;
    const d = ui.div(c).fixed().w(c.size.w).h(c.size.h).layer(layer_backdrop).bg(t.overlay).occlude().motion(f);
    const it = d.interaction();
    d.end();
    return it.clicked and show;
}

/// A dialog keyed `id` while `open.*`; null once closed and gone.
pub fn dialog(c: *ui.Context, id: []const u8, open: *bool, opts: Options) ?Dialog {
    const t = kit.tokens(c);
    if (open.* and c.shortcut(.{ .key = ui.Shortcut.escape })) close(c, open);
    if (backdrop(c, c.print("{s}-backdrop", .{id}), open.*) and opts.overlay_closable) close(c, open);
    const f = motion.present(c, id, open.*, .{
        .initial = .{ .opacity = 0, .scale = 0.95, .y = 8 },
        .exit = .{ .opacity = 0, .scale = 0.97 },
        .transition = .{ .spring = motion.Spring.snappy },
    }) orelse return null;
    const panel_id = c.peekId(null);
    const h = if (c.rects.get(panel_id)) |r| r.h else 200;
    const w = @min(opts.width, c.size.w - 32);
    const panel = ui.div(c).fixed().offset((c.size.w - w) / 2, @max(16, (c.size.h - h) / 2 - c.size.h * 0.06)).w(w).layer(layer_panel).column().gap(14).p(22).rounded(14).bg(t.popover).border(t.border).shadow(.{ .color = t.shadow.alpha(1), .blur = 40, .y = 16 }).occlude().motion(f);
    {
        const head = ui.div(c).row().wFull().gap(8).itemsStart();
        defer head.end();
        const words = ui.div(c).column().grow().gap(5);
        if (opts.title.len > 0) ui.text(c, opts.title, .{ .size = 16, .weight = .semibold, .color = t.foreground });
        if (opts.description.len > 0) ui.text(c, opts.description, .{ .size = 13, .color = t.muted, .wrap = true });
        words.end();
        if (opts.close_button and kit.iconButton(c, "xmark", .{ .size = .xs }).clicked) close(c, open);
    }
    const body = ui.div(c).column().wFull().gap(10);
    return .{ .c = c, .open = open, .opts = opts, .panel = panel, .body = body };
}

pub const Side = enum { left, right, bottom };

/// A panel slid in from `side` while `open.*`: draw in it, then `end` it.
pub fn sheet(c: *ui.Context, id: []const u8, open: *bool, opts: struct { side: Side = .right, size: f32 = 360, title: []const u8 = "" }) ?ui.Div {
    const t = kit.tokens(c);
    if (open.* and c.shortcut(.{ .key = ui.Shortcut.escape })) close(c, open);
    if (backdrop(c, c.print("{s}-backdrop", .{id}), open.*)) close(c, open);
    const away: motion.Target = switch (opts.side) {
        .left => .{ .x = -opts.size },
        .right => .{ .x = opts.size },
        .bottom => .{ .y = opts.size },
    };
    const f = motion.present(c, id, open.*, .{ .initial = away, .exit = away, .transition = .{ .spring = .{ .stiffness = 320, .damping = 34 } } }) orelse return null;
    var d = switch (opts.side) {
        .left => ui.div(c).fixed().offset(0, 0).w(opts.size).h(c.size.h),
        .right => ui.div(c).fixed().offset(c.size.w - opts.size, 0).w(opts.size).h(c.size.h),
        .bottom => ui.div(c).fixed().offset(0, c.size.h - opts.size).w(c.size.w).h(opts.size),
    };
    d = d.layer(layer_panel).column().gap(12).p(20).bg(t.popover).border(t.border).shadow(.{ .color = t.shadow.alpha(1), .blur = 30 }).clip().occlude().motion(f);
    if (opts.title.len > 0) {
        const head = ui.div(c).row().wFull().itemsCenter();
        defer head.end();
        ui.text(c, opts.title, .{ .size = 16, .weight = .semibold, .color = t.foreground });
        ui.spacer(c);
        if (kit.iconButton(c, "xmark", .{ .size = .xs }).clicked) close(c, open);
    }
    return d;
}
