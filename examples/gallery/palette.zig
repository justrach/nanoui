//! Command palette overlay for the gallery (`⌘K` on Apple systems,
//! `Ctrl+K` elsewhere, plus `⌘1`..`⌘9` page jumps), following the modal scrim
//! layering and cross-platform shortcut rules from `nanoui.kit`. Its
//! behaviour comes from `kit.picker`: the highlight follows an entry (not a
//! row number) as the query narrows, keys that compose input-method text stay
//! with the field, and closing returns focus to where it was.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const motion = ui.motion;
const picker = kit.picker;
const phone = @import("phone.zig");

const Kind = enum {
    page,
    theme_light,
    theme_dark,
    theme_system,
    reset_dock,
    toggle_solo,
};

const Entry = struct {
    title: []const u8,
    subtitle: []const u8,
    icon: []const u8,
    shortcut: []const u8 = "",
    kind: Kind,
    page: usize = 0,
};

const actions = [_]Entry{
    .{ .title = "Theme: Light", .subtitle = "Switch gallery to light theme", .icon = "sun.max", .kind = .theme_light },
    .{ .title = "Theme: Dark", .subtitle = "Switch gallery to dark theme", .icon = "moon.fill", .kind = .theme_dark },
    .{ .title = "Theme: System", .subtitle = "Follow operating system appearance", .icon = "circle.lefthalf.filled", .kind = .theme_system },
    .{ .title = "Studio: Reset dock layout", .subtitle = "Restore default 3-pane workspace split", .icon = "rectangle.split.3x1", .kind = .reset_dock },
    .{ .title = "Studio: Toggle solo pane", .subtitle = "Focus or unfocus Transcript pane", .icon = "arrow.up.left.and.arrow.down.right", .kind = .toggle_solo },
};

const total_entries = phone.pages.len + actions.len;

const page_shortcuts = blk: {
    var labels: [phone.pages.len][]const u8 = undefined;
    for (0..phone.pages.len) |i| {
        const key_str = [_]u8{'1' + @as(u8, @intCast(i))};
        labels[i] = ui.keys.label("⌘" ++ key_str);
    }
    break :blk labels;
};

pub const Palette = struct {
    open: bool = false,
    query: ui.TextBuffer = .{},
    /// The highlighted entry's index in the catalog (its id), not its row.
    active: ?picker.Id = null,
    composition: picker.Composition = .{},
    /// What had focus when the palette opened; it gets it back on close.
    return_focus: u64 = 0,
    /// Counts the opens, keying the list, so each opens scrolled to the top.
    opens: u32 = 0,

    pub fn deinit(p: *Palette) void {
        p.query.deinit();
    }

    pub fn toggle(p: *Palette, c: *ui.Context) void {
        if (p.open) {
            p.close(c);
            return;
        }
        p.open = true;
        p.opens +%= 1;
        p.return_focus = c.focus;
        p.query.clear();
        p.active = null;
        p.composition = .{};
        p.query.focus();
        c.changed = true;
    }

    pub fn close(p: *Palette, c: *ui.Context) void {
        p.open = false;
        c.focus = p.return_focus;
        c.changed = true;
    }

    fn entryAt(i: usize) Entry {
        if (i < phone.pages.len) {
            return .{
                .title = phone.pages[i][0],
                .subtitle = phone.blurbs[i],
                .icon = phone.pages[i][1],
                .shortcut = page_shortcuts[i],
                .kind = .page,
                .page = i,
            };
        }
        return actions[i - phone.pages.len];
    }

    fn collectMatches(p: *const Palette, out: *[total_entries]picker.Id) usize {
        const q = std.mem.trim(u8, p.query.text(), " \t\n");
        var n: usize = 0;
        for (0..total_entries) |i| {
            const e = entryAt(i);
            if (q.len == 0 or
                std.ascii.findIgnoreCase(e.title, q) != null or
                std.ascii.findIgnoreCase(e.subtitle, q) != null)
            {
                out[n] = i;
                n += 1;
            }
        }
        return n;
    }

    /// Runs before page/sidebar construction so `⌘K`, navigation arrows, and
    /// Escape inside the palette preempt underlying widgets.
    pub fn handleShortcuts(p: *Palette, g: anytype, c: *ui.Context) void {
        if (c.shortcut(.{ .key = 'k', .cmd = true })) {
            p.toggle(c);
            return;
        }
        if (p.open) {
            var matches: [total_entries]picker.Id = undefined;
            const ids = matches[0..p.collectMatches(&matches)];
            _ = picker.reconcile(&p.active, ids, .first);
            // Keys that compose, commit or cancel input-method text are the field's.
            if (!p.composition.begin(c).quiet()) return;
            const intent = picker.keys(c, .{ .consume = true }) orelse return;
            switch (intent) {
                .dismiss => p.close(c),
                .next, .previous => {
                    _ = picker.step(&p.active, ids, if (intent == .next) .next else .previous, .wrap);
                    c.changed = true;
                },
                .activate => if (p.active) |id| p.runEntry(g, c, @intCast(id)),
            }
            return;
        }
        if (c.focused_text == null) {
            inline for (0..phone.pages.len) |i| {
                if (c.shortcut(.{ .key = '1' + @as(u21, i), .cmd = true })) {
                    g.page = i;
                    if (phone.compact(c)) g.open = true;
                    return;
                }
            }
        }
    }

    pub fn overlay(p: *Palette, g: anytype, c: *ui.Context) void {
        const th = c.theme;
        const tk = kit.tokens(c);
        // The scrim and the card come and go together: each is asked every
        // frame, so neither is left behind when the other has gone, and a
        // closing card fades in the scrim's time rather than on a spring.
        const leave: motion.Transition = .{ .tween = .{ .duration = 0.14 } };
        if (motion.present(c, "gallery-palette-scrim", p.open, .{
            .initial = .{ .opacity = 0 },
            .exit = .{ .opacity = 0 },
            .transition = if (p.open) .{ .tween = .{ .duration = 0.14 } } else leave,
        })) |sf| {
            const bd = ui.div(c).fixed().offset(0, 0).w(c.size.w).h(c.size.h).layer(10).bg(tk.overlay).motion(sf);
            const bit = bd.interaction();
            bd.end();
            if (bit.clicked and p.open) p.close(c);
        }
        const f = motion.present(c, "gallery-palette", p.open, .{
            .initial = .{ .opacity = 0, .scale = 0.97, .y = -8 },
            .exit = .{ .opacity = 0, .scale = 0.97, .y = -8 },
            .transition = if (p.open) .{ .spring = motion.Spring.snappy } else leave,
        }) orelse return;

        const w = @min(480, @max(280, c.size.w - 32));
        const x = (c.size.w - w) / 2;
        const y = @max(44, c.size.h * 0.13);
        const card = ui.div(c).fixed().offset(x, y).w(w).layer(11).column().rounded(12)
            .bg(th.surface).border(th.border)
            .shadow(.{ .color = .{ .a = if (th.dark) 0.48 else 0.18 }, .blur = 28, .y = 10 })
            .clip().motion(f);
        defer card.end();

        var matches: [total_entries]picker.Id = undefined;
        const count = p.collectMatches(&matches);

        {
            const top = ui.div(c).row().wFull().px(14).py(10).gap(10).itemsCenter();
            defer top.end();
            ui.icon(c, "magnifyingglass", .{ .size = 14, .color = th.muted });
            const tf = ui.textField(c, &p.query, .{
                .placeholder = "Jump to a page or run an action…",
                .bare = true,
                .width = .fill,
                .size = 15,
            });
            _ = p.composition.end(c, &p.query);
            if (tf.changed) p.active = null;
            _ = picker.reconcile(&p.active, matches[0..count], .first);
            if (tf.submitted) if (p.active) |id| p.runEntry(g, c, @intCast(id));
            if (kit.button(c, "Esc", .{ .variant = .ghost, .size = .xs }).clicked) p.close(c);
        }
        kit.separator(c, .{});
        {
            ui.key(c, c.print("pal-list-{d}", .{p.opens}));
            const list = ui.div(c).column().wFull().maxH(280).scrollY().p(6).gap(2);
            defer list.end();
            for (matches[0..count]) |id| {
                const idx: usize = @intCast(id);
                const e = entryAt(idx);
                picker.rowKey(c, 0, id);
                const hot = p.active == id;
                var row = ui.div(c).row().wFull().px(10).py(8).gap(10).rounded(8).itemsCenter().control();
                row = if (hot) row.bg(th.accent.alpha(0.14)) else row.hover(th.surface_hover);
                defer row.end();
                ui.access.describe(c, row.index, .{ .label = e.title, .value = e.subtitle, .selected = hot });
                if (row.clicked()) p.runEntry(g, c, idx);
                ui.icon(c, e.icon, .{ .size = 14, .frame = 18, .color = if (hot) th.accent else th.muted });
                {
                    const col = ui.div(c).column().grow().gap(1);
                    defer col.end();
                    ui.text(c, e.title, .{ .size = 13.5, .weight = .medium, .color = th.text });
                    ui.text(c, e.subtitle, .{ .size = 11.5, .color = th.muted, .truncate = .ellipsis });
                }
                if (e.shortcut.len > 0) kit.kbd(c, e.shortcut);
            }
            if (count == 0) {
                const empty = ui.div(c).wFull().p(16).itemsCenter().justifyCenter();
                defer empty.end();
                ui.text(c, "No matching commands.", .{ .size = 13, .color = th.muted });
            }
        }
        kit.separator(c, .{});
        {
            const foot = ui.div(c).row().wFull().px(12).py(8).gap(12).itemsCenter().bg(th.background.alpha(0.55));
            defer foot.end();
            kit.kbd(c, "↑↓");
            ui.text(c, "Navigate", .{ .size = 11.5, .color = th.muted });
            kit.kbd(c, "↵");
            ui.text(c, "Run", .{ .size = 11.5, .color = th.muted });
            ui.spacer(c);
            kit.kbd(c, "Esc");
            ui.text(c, "Close", .{ .size = 11.5, .color = th.muted });
        }
    }

    fn runEntry(p: *Palette, g: anytype, c: *ui.Context, idx: usize) void {
        const e = entryAt(idx);
        switch (e.kind) {
            .page => {
                g.page = e.page;
                if (phone.compact(c)) g.open = true;
            },
            .theme_light => g.appearance = .light,
            .theme_dark => g.appearance = .dark,
            .theme_system => g.appearance = .system,
            .reset_dock => {
                g.page = 7;
                if (phone.compact(c)) g.open = true;
                g.studio.resetLayout();
            },
            .toggle_solo => {
                g.page = 7;
                if (phone.compact(c)) g.open = true;
                g.studio.toggleSolo();
            },
        }
        p.close(c);
    }
};
