//! The chrome of a reference page (a foundation or a component): a heading
//! that stays put, naming the page, its call and its file, and a column
//! under it that scrolls, in labelled sections.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const pad: f32 = 28;
/// The heading's height, so the rule under it lines up with the sidebar's
/// rule under its search field.
pub const head_h: f32 = 80;

/// Something drawn at the heading's right: a search field, a reset button.
pub const Actions = struct {
    ctx: *anyopaque,
    draw: *const fn (*anyopaque, *ui.Context) void,

    pub fn of(ptr: anytype, comptime f: fn (@TypeOf(ptr), *ui.Context) void) Actions {
        return .{ .ctx = ptr, .draw = struct {
            fn draw(p: *anyopaque, c: *ui.Context) void {
                f(@ptrCast(@alignCast(p)), c);
            }
        }.draw };
    }
};

/// Opens the page: its heading, then the scrolling column the sections go
/// in. Close it with `end`.
pub fn begin(c: *ui.Context, title: []const u8, subtitle: []const u8, actions: ?Actions) void {
    heading(c, title, subtitle, actions);
    ui.scroll(c, .{ .grow = 1, .width = .fill, .height = .fill, .padding = .{ .left = pad, .right = pad, .top = 24, .bottom = pad }, .gap = 28 });
}

/// Opens a demo's page: the same heading, then a column the demo fills as it
/// likes (its own scrolling, a virtual list, a dock). Close it with `end`.
pub fn beginDemo(c: *ui.Context, title: []const u8, subtitle: []const u8) void {
    heading(c, title, subtitle, null);
    // A row, so a demo's own grow() takes the width, as beside the sidebar.
    ui.row(c, .{ .grow = 1, .width = .fill, .height = .fill, .clip = true });
}

/// A demo's own title, drawn only on a phone: beside the sidebar the page's
/// heading names it.
pub fn demoTitle(c: *ui.Context, title: []const u8) void {
    if (@import("phone.zig").compact(c)) ui.heading(c, title);
}

fn heading(c: *ui.Context, title: []const u8, subtitle: []const u8, actions: ?Actions) void {
    const th = c.theme;
    ui.column(c, .{ .grow = 1, .height = .fill, .clip = true });
    {
        const head = ui.div(c).row().wFull().h(head_h).px(pad).gap(16).itemsCenter();
        defer head.end();
        {
            const words = ui.div(c).column().grow().gap(5);
            defer words.end();
            ui.text(c, title, .{ .size = 22, .weight = .bold });
            ui.text(c, subtitle, .{ .size = 12, .mono = true, .color = th.muted, .truncate = .ellipsis });
        }
        if (actions) |a| a.draw(a.ctx, c);
    }
    ui.divider(c);
}

/// The size a page's body has: the window's, less the sidebar and the
/// heading beside it (a phone shows neither).
pub fn bodySize(c: *ui.Context) struct { w: f32, h: f32 } {
    if (@import("phone.zig").compact(c)) return .{ .w = c.size.w, .h = c.size.h };
    return .{ .w = c.size.w - @import("sidebar.zig").width, .h = c.size.h - head_h - 1 };
}

pub fn end(c: *ui.Context) void {
    ui.end(c);
    ui.end(c);
}

/// A labelled group of examples: `VARIANTS`, `SIZES`, `STATES`.
pub fn section(c: *ui.Context, label: []const u8) ui.Div {
    const s = ui.div(c).column().wFull().gap(12);
    var buf: [48]u8 = undefined;
    const caps = std.ascii.upperString(buf[0..@min(label.len, buf.len)], label[0..@min(label.len, buf.len)]);
    ui.text(c, c.print("{s}", .{caps}), .{ .size = 11, .weight = .semibold, .color = c.theme.muted });
    return s;
}

pub fn row(c: *ui.Context) ui.Div {
    return ui.div(c).row().gap(10).itemsCenter();
}

/// A caption under or beside an example.
pub fn note(c: *ui.Context, str: []const u8) void {
    ui.text(c, str, .{ .size = 11.5, .color = c.theme.muted });
}

/// The width a page's content has, beside the sidebar.
pub fn contentWidth(c: *const ui.Context, sidebar: f32) f32 {
    return @max(120, c.size.w - sidebar - 2 * pad);
}
