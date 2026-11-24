//! Toasts, as GPUI Kit's notifications: messages stacked in a corner, each
//! with a status, a title and a line, that slide in, go by themselves
//! after a while (unless the pointer rests on them), and slide out; the
//! rest glide into the space left. The app keeps a `Toaster`, pushes to it,
//! and draws it once a frame, last.
const std = @import("std");
const ui = @import("../ui/ui.zig");
const kit = @import("kit.zig");
const motion = ui.motion;

pub const layer_toast = 40;

pub const Toast = struct {
    status: kit.Status = .neutral,
    title: []const u8 = "",
    message: []const u8 = "",
    /// Seconds it stays; 0 until closed.
    duration: f32 = 4,
};

const Entry = struct {
    id: u64,
    toast: Toast,
    /// The text, owned.
    text: []u8,
    /// When it went up (the view's clock), and whether it's on its way out.
    since: ?f64 = null,
    leaving: bool = false,
};

pub const Corner = enum { top_right, bottom_right, bottom_left, top_left };

pub const Toaster = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Entry) = .empty,
    next: u64 = 1,
    corner: Corner = .bottom_right,
    width: f32 = 340,
    /// Toasts of Liquid Glass.
    glass: bool = false,

    pub fn deinit(ts: *Toaster) void {
        for (ts.items.items) |e| ts.gpa.free(e.text);
        ts.items.deinit(ts.gpa);
    }

    /// Shows `t` (its strings are copied).
    pub fn push(ts: *Toaster, t: Toast) void {
        const text = std.mem.concat(ts.gpa, u8, &.{ t.title, t.message }) catch return;
        var copy = t;
        copy.title = text[0..t.title.len];
        copy.message = text[t.title.len..];
        ts.items.append(ts.gpa, .{ .id = ts.next, .toast = copy, .text = text }) catch return ts.gpa.free(text);
        ts.next += 1;
    }

    /// Draws the toasts, over everything; call it last in the frame.
    pub fn view(ts: *Toaster, c: *ui.Context) void {
        const t = kit.tokens(c);
        const top = ts.corner == .top_right or ts.corner == .top_left;
        const right = ts.corner == .top_right or ts.corner == .bottom_right;
        const x = if (right) c.size.w - ts.width - 16 else 16;
        var y: f32 = if (top) 16 else c.size.h - 16;
        // Newest nearest the corner.
        var order = std.ArrayList(usize).initCapacity(c.alloc(), ts.items.items.len) catch return;
        var k = ts.items.items.len;
        while (k > 0) {
            k -= 1;
            order.appendAssumeCapacity(k);
        }
        var gone: ?usize = null;
        for (order.items) |idx| {
            const e = &ts.items.items[idx];
            const since = e.since orelse blk: {
                e.since = c.time;
                break :blk c.time;
            };
            const key = c.print("toast-{d}", .{e.id});
            c.next_key = key;
            const box_id = c.peekId(null);
            c.next_key = null;
            const resting = c.hot == box_id or std.mem.indexOfScalar(u64, c.hot_path.items, box_id) != null;
            if (e.toast.duration > 0 and !resting and c.time - since > e.toast.duration) e.leaving = true;
            if (e.toast.duration > 0 and !e.leaving) c.frameIn(@floatCast(@max(0.05, e.toast.duration - (c.time - since))));
            const h = if (c.rects.get(box_id)) |r| r.h else 64;
            const at_y = if (top) y else y - h;
            const f = motion.present(c, key, !e.leaving, .{
                .initial = .{ .x = if (right) 40 else -40, .opacity = 0 },
                .exit = .{ .x = if (right) 40 else -40, .opacity = 0 },
                .layout = true,
                .transition = .{ .spring = motion.Spring.snappy },
            }) orelse {
                gone = idx;
                continue;
            };
            const col = kit.statusColor(t, e.toast.status);
            var d = ui.div(c).fixed().offset(x, at_y).w(ts.width).layer(layer_toast).row().gap(10).itemsStart().p(12).rounded(t.radius + 2).shadow(.{ .color = t.shadow.alpha(0.9), .blur = 22, .y = 8 }).occlude();
            d = (if (ts.glass) d.rounded(t.radius + 8).glass(.{}) else d.bg(t.popover).border(t.border)).motion(f);
            defer d.end();
            if (e.toast.status != .neutral) ui.icon(c, kit.statusIcon(e.toast.status), .{ .size = 15, .color = col });
            {
                const words = ui.div(c).column().grow().gap(2);
                defer words.end();
                if (e.toast.title.len > 0) ui.text(c, e.toast.title, .{ .size = 13, .weight = .semibold, .color = t.foreground });
                if (e.toast.message.len > 0) ui.text(c, e.toast.message, .{ .size = 12.5, .color = t.muted, .wrap = true });
            }
            if (kit.iconButton(c, "xmark", .{ .size = .xs }).clicked) e.leaving = true;
            const step = h + 8;
            y = if (top) y + step else y - step;
        }
        // One gone a frame is plenty.
        if (gone) |idx| {
            ts.gpa.free(ts.items.items[idx].text);
            _ = ts.items.orderedRemove(idx);
        }
    }
};
