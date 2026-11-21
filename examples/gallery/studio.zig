//! The Studio page of the gallery: a multi-pane workspace powered by
//! `ui.dock`, combining a folded tool-call timeline, live theme/zoom
//! inspector, and vector frame-budget chart (`ui.canvas`). On compact
//! windows it switches smoothly to segmented `kit.tabs`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const phone = @import("phone.zig");
const Appearance = @import("main.zig").Appearance;

pub const Panel = enum(ui.dock.PanelId) {
    transcript = 0,
    inspector = 1,
    telemetry = 2,
};

pub const catalog = [_]ui.dock.PanelInfo{
    .{ .title = "Transcript", .min_w = 200, .min_h = 140 },
    .{ .title = "Inspector", .min_w = 180, .min_h = 120 },
    .{ .title = "Telemetry", .min_w = 180, .min_h = 120 },
};

const zooms = [_]f32{ 0.9, 1.0, 1.15 };

pub const Demo = struct {
    ready: bool = false,
    tree: ui.dock.Tree = ui.dock.Tree.init(&catalog),
    dock_state: ui.dock.State = .{},
    solo: bool = false,
    mobile_tab: usize = 0,
    tools_open: bool = false,
    draft: ui.TextBuffer = .{},
    replies: [6][96]u8 = undefined,
    reply_lens: [6]usize = .{ 0, 0, 0, 0, 0, 0 },
    reply_count: usize = 0,
    zoom_idx: usize = 1,
    appearance_ptr: ?*Appearance = null,

    pub fn deinit(s: *Demo) void {
        s.draft.deinit();
    }

    pub fn resetLayout(s: *Demo) void {
        s.tree = ui.dock.Tree.init(&catalog);
        _ = s.tree.insert(@backingInt(Panel.transcript), null);
        _ = s.tree.split(@backingInt(Panel.inspector), @backingInt(Panel.transcript), .right);
        _ = s.tree.split(@backingInt(Panel.telemetry), @backingInt(Panel.inspector), .bottom);
        s.solo = false;
        s.ready = true;
    }

    pub fn toggleSolo(s: *Demo) void {
        s.solo = !s.solo;
    }

    pub fn view(s: *Demo, c: *ui.Context, appearance: *Appearance) void {
        if (!s.ready or s.tree.panelCount() == 0) s.resetLayout();
        s.appearance_ptr = appearance;
        defer s.appearance_ptr = null;

        const th = c.theme;
        const compact = phone.compact(c);
        const pad: f32 = if (compact) 16 else 24;
        const outer = ui.div(c).column().grow().sizeFull().p(pad).gap(12);
        defer outer.end();
        {
            const head = ui.div(c).row().wFull().itemsCenter().gap(8);
            defer head.end();
            // Beside the sidebar the page's heading names it.
            if (compact) ui.heading(c, "Studio");
            ui.spacer(c);
            if (!compact) {
                if (kit.button(c, if (s.solo) "Exit solo" else "Solo pane", .{
                    .variant = if (s.solo) .primary else .outline,
                    .size = .sm,
                }).clicked) {
                    s.toggleSolo();
                    c.changed = true;
                }
                if (kit.button(c, "Reset dock", .{ .variant = .ghost, .size = .sm }).clicked) {
                    s.resetLayout();
                    c.changed = true;
                }
            }
        }
        if (compact) {
            _ = kit.tabs(c, &.{ "Transcript", "Inspector", "Telemetry" }, &s.mobile_tab, .{ .variant = .segmented, .size = .sm });
            const card = ui.div(c).column().wFull().grow().rounded(12).bg(th.surface).border(th.border).clip();
            defer card.end();
            const panels = [_]Panel{ .transcript, .inspector, .telemetry };
            s.panelContent(c, panels[@min(s.mobile_tab, panels.len - 1)]);
            return;
        }
        const host = ui.div(c).column().wFull().grow().rounded(10).border(th.border).clip();
        const host_rect = host.interaction().rect;
        defer host.end();
        if (host_rect == null) c.changed = true;
        ui.dock.view(c, &s.tree, &s.dock_state, .{
            .background = th.border.alpha(0.45),
            .panel = th.surface,
            .header = th.background,
            .border = th.border,
            .radius = 8,
            .glow = th.accent,
            .solo = if (s.solo) @backingInt(Panel.transcript) else null,
        }, s, Hooks);
    }

    const Hooks = struct {
        pub fn tab(s: *Demo, c: *ui.Context, id: ui.dock.PanelId, t: ui.dock.TabState) void {
            const th = c.theme;
            const icon_name = switch (@as(Panel, @fromBackingInt(@intCast(id)))) {
                .transcript => "bubble.left.and.bubble.right",
                .inspector => "slider.horizontal.below.rectangle",
                .telemetry => "waveform.path.ecg",
            };
            const row = ui.div(c).row().px(8).h(26).gap(6).itemsCenter().rounded(6);
            defer row.end();
            const fg = if (t.active) th.text else th.muted;
            ui.icon(c, icon_name, .{ .size = 12, .frame = 14, .color = fg });
            ui.text(c, s.tree.title(id), .{
                .size = 12.5,
                .weight = if (t.active) .semibold else .regular,
                .color = fg,
            });
        }

        pub fn content(s: *Demo, c: *ui.Context, id: ui.dock.PanelId, _: ui.Rect) void {
            s.panelContent(c, @fromBackingInt(@intCast(id)));
        }
    };

    fn panelContent(s: *Demo, c: *ui.Context, p: Panel) void {
        switch (p) {
            .transcript => s.transcriptPanel(c),
            .inspector => s.inspectorPanel(c),
            .telemetry => s.telemetryPanel(c),
        }
    }

    fn transcriptPanel(s: *Demo, c: *ui.Context) void {
        const th = c.theme;
        const wrap = ui.div(c).column().sizeFull().p(12).gap(10);
        defer wrap.end();
        {
            const thread = ui.div(c).column().wFull().grow().scrollY().gap(10);
            defer thread.end();
            {
                const prompt = ui.div(c).column().wFull().p(10).gap(4).rounded(8).bg(th.background).border(th.border);
                defer prompt.end();
                ui.text(c, "Prompt", .{ .size = 11, .weight = .semibold, .color = th.muted });
                ui.text(c, "Audit frame pacing and accessibility labels across surfaces.", .{ .wrap = true });
            }
            {
                const fold = ui.div(c).row().wFull().px(10).py(7).gap(8).rounded(8).bg(th.background).border(th.border).hover(th.surface_hover).itemsCenter().control();
                defer fold.end();
                if (fold.clicked()) {
                    s.tools_open = !s.tools_open;
                    c.changed = true;
                }
                ui.icon(c, "chevron.right", .{
                    .size = 11,
                    .frame = 14,
                    .color = th.muted,
                    .rotation = if (s.tools_open) std.math.pi * 0.5 else 0,
                });
                ui.text(c, "Ran 3 checks", .{ .size = 12.5, .weight = .medium });
                ui.spacer(c);
                ui.text(c, "18 ms", .{ .size = 12, .color = th.muted, .tabular = true });
            }
            if (s.tools_open) {
                const steps = [_]struct { name: []const u8, detail: []const u8, ok: bool }{
                    .{ .name = "access.tree · verified 0 unlabeled controls", .detail = "4 ms", .ok = true },
                    .{ .name = "dock.layout · 3 groups within min bounds", .detail = "6 ms", .ok = true },
                    .{ .name = "frame_pace · idle wakeup count = 0", .detail = "8 ms", .ok = false },
                };
                const rail_col = ui.div(c).column().wFull().gap(0);
                defer rail_col.end();
                for (steps, 0..) |st, i| {
                    ui.key(c, c.print("step-{d}", .{i}));
                    const item = kit.timelineItem(c, .{
                        .height = 38,
                        .first = i == 0,
                        .last = i + 1 == steps.len,
                        .color = if (st.ok) th.success else th.accent,
                    });
                    defer item.end();
                    ui.text(c, st.name, .{ .size = 12, .color = th.text, .truncate = .ellipsis });
                    ui.spacer(c);
                    ui.text(c, st.detail, .{ .size = 11.5, .color = th.muted, .tabular = true });
                }
            }
            ui.text(c, "All checks passed. Drag any tab onto another pane's edge to split, or drop on center to stack.", .{ .size = 13, .color = th.muted, .wrap = true });
            for (0..s.reply_count) |i| {
                ui.key(c, c.print("note-{d}", .{i}));
                const msg = s.replies[i][0..s.reply_lens[i]];
                const note = ui.div(c).row().wFull().px(10).py(7).gap(8).rounded(8).bg(th.accent.alpha(0.08)).itemsCenter();
                defer note.end();
                ui.icon(c, "checkmark.circle", .{ .size = 13, .color = th.accent });
                ui.text(c, c.print("Queued note: {s}", .{msg}), .{ .size = 12.5, .wrap = true });
            }
        }
        {
            const bar = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer bar.end();
            const r = ui.textField(c, &s.draft, .{ .placeholder = "Append a note to transcript…", .width = .fill });
            const send = kit.button(c, "Send", .{ .variant = .primary, .size = .sm }).clicked;
            if (r.submitted or send) {
                const text = std.mem.trim(u8, s.draft.text(), " \t\n");
                if (text.len > 0) s.pushReply(text);
                s.draft.clear();
                c.changed = true;
            }
        }
    }

    fn pushReply(s: *Demo, text: []const u8) void {
        if (s.reply_count == s.replies.len) {
            for (0..s.replies.len - 1) |i| {
                s.replies[i] = s.replies[i + 1];
                s.reply_lens[i] = s.reply_lens[i + 1];
            }
            s.reply_count -= 1;
        }
        const n = @min(text.len, s.replies[0].len);
        @memcpy(s.replies[s.reply_count][0..n], text[0..n]);
        s.reply_lens[s.reply_count] = n;
        s.reply_count += 1;
    }

    fn inspectorPanel(s: *Demo, c: *ui.Context) void {
        const th = c.theme;
        const sc = ui.div(c).column().sizeFull().scrollY().p(10).gap(10);
        defer sc.end();
        if (s.appearance_ptr) |app| {
            const sec = ui.div(c).column().wFull().gap(4);
            defer sec.end();
            ui.text(c, "Appearance", .{ .size = 12, .weight = .semibold });
            var choice: usize = @backingInt(app.*);
            if (ui.segmented(c, &.{ "Light", "Dark", "System" }, &choice)) {
                app.* = @fromBackingInt(@intCast(choice));
                c.changed = true;
            }
        }
        {
            const sec = ui.div(c).column().wFull().gap(4);
            defer sec.end();
            ui.text(c, "Interface zoom", .{ .size = 12, .weight = .semibold });
            if (ui.segmented(c, &.{ "90%", "100%", "115%" }, &s.zoom_idx)) {
                c.setZoom(zooms[@min(s.zoom_idx, zooms.len - 1)]);
                c.changed = true;
            }
        }
        {
            const tk = kit.tokens(c);
            const sec = ui.div(c).column().wFull().gap(6);
            defer sec.end();
            ui.text(c, "Theme tokens", .{ .size = 12, .weight = .semibold });
            const swatches = [_]struct { name: []const u8, col: ui.Color }{
                .{ .name = "Surface", .col = th.surface },
                .{ .name = "Accent", .col = th.accent },
                .{ .name = "Success", .col = th.success },
                .{ .name = "Warning", .col = tk.warning },
                .{ .name = "Danger", .col = th.danger },
            };
            const row = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer row.end();
            for (swatches) |sw| {
                const chip = ui.div(c).column().gap(3).itemsCenter();
                defer chip.end();
                const dot = ui.div(c).w(20).h(20).rounded(5).bg(sw.col).border(th.border);
                dot.end();
                ui.text(c, sw.name, .{ .size = 10, .color = th.muted });
            }
        }
    }

    fn telemetryPanel(s: *Demo, c: *ui.Context) void {
        const th = c.theme;
        const wrap = ui.div(c).column().sizeFull().p(12).gap(8);
        defer wrap.end();
        {
            const head = ui.div(c).row().wFull().itemsCenter().gap(8);
            defer head.end();
            ui.text(c, "Frame budget (120 Hz · 8.33 ms)", .{ .size = 12.5, .weight = .semibold });
            ui.spacer(c);
            kit.tag(c, c.renderer, .{ .size = .xs, .pill = true });
        }
        const cv = ui.canvas(c, .{ .width = .fill, .height = .{ .px = 96 }, .radius = 8, .background = th.background });
        if (cv.size.w > 16 and cv.size.h > 16) {
            const samples = [_]f32{ 4.2, 4.8, 5.1, 4.5, 6.2, 5.4, 4.9, 4.6, 5.8, 5.0, 4.4, 4.7 };
            const max_ms: f32 = 10.0;
            const pad_x: f32 = 10;
            const pad_y: f32 = 10;
            const plot_w = cv.size.w - 2 * pad_x;
            const plot_h = cv.size.h - 2 * pad_y;
            const budget_y = pad_y + plot_h * (1.0 - 8.33 / max_ms);
            cv.line(.{ .x = pad_x, .y = budget_y }, .{ .x = cv.size.w - pad_x, .y = budget_y }, .{
                .width = 1,
                .color = th.muted.alpha(0.55),
                .dash = .{ 4, 4 },
            });
            var pts: [samples.len]ui.Point = undefined;
            for (samples, 0..) |ms, i| {
                const frac = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(samples.len - 1));
                pts[i] = .{
                    .x = pad_x + plot_w * frac,
                    .y = pad_y + plot_h * (1.0 - std.math.clamp(ms / max_ms, 0, 1)),
                };
            }
            cv.polyline(&pts, .{ .width = 2, .color = th.accent });
            cv.circle(pts[pts.len - 1], 3.5, th.accent);
        }
        ui.text(c, c.print("{d} boxes · {d} dock groups", .{ c.nodes.items.len, s.dock_state.layout.group_count }), .{
            .size = 11.5,
            .color = th.muted,
            .tabular = true,
        });
    }
};
