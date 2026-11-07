//! The control panel: whether agents may act, in one app or on the whole
//! screen, and the switch that stops them, the permissions macOS needs, the command that adds nanocua to an
//! agent, and every call agents made, newest first.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const policy = @import("policy.zig");
const control = @import("control.zig");
const App = @import("app.zig").App;
const mac = @import("app.zig").mac;

pub fn view(a: *App, c: *ui.Context) void {
    const k = theme.colors(a.dark orelse nanoui.isDark());
    a.refreshPerms();
    const page = ui.div(c).column().sizeFull().p(20).gap(14).bg(k.page);
    defer page.end();
    header(c, a, k);
    question(c, a, k);
    permissions(c, a, k);
    agents(c, a, k);
    activity(c, a, k);
}

fn card(c: *ui.Context, k: theme.Colors) ui.Div {
    return ui.div(c).column().wFull().p(14).gap(10).bg(k.card).border(k.border).rounded(12);
}

fn title(c: *ui.Context, k: theme.Colors, s: []const u8) void {
    ui.text(c, s, .{ .size = 13, .weight = .semibold, .color = k.secondary });
}

fn header(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = a.hub.policy;
    const row = ui.div(c).row().wFull().itemsCenter().gap(10);
    defer row.end();
    {
        const col = ui.div(c).column().gap(3).grow();
        defer col.end();
        {
            const r = ui.div(c).row().itemsCenter().gap(8);
            defer r.end();
            ui.text(c, "nanocua", .{ .size = 20, .weight = .bold, .color = k.text });
            if (p.stopped) ui.badge(c, "Stopped", k.red) else if (p.allow_input) ui.badge(c, "Acting", k.green) else ui.badge(c, "Looking only", k.yellow);
            if (p.allow_whole_screen and !p.stopped) ui.badge(c, "Whole screen", k.red);
        }
        ui.text(c, "Lets AI agents see and use this computer, as far as you allow here.", .{ .size = 12, .color = k.secondary, .wrap = true });
    }
    if (p.stopped) {
        if (ui.button(c, "Resume", .{ .variant = .primary }).clicked) a.fromPanel(.@"resume", true);
    } else if (ui.button(c, "Stop", .{ .variant = .danger }).clicked) a.setStopped(true);
}

pub const screen_hint = "Turn on nanocua in the list System Settings opened. Not there? Drag nanocua.app from the Finder window into it.";

/// What a program asked for from outside. Only this click turns it on.
fn question(c: *ui.Context, a: *App, k: theme.Colors) void {
    const now = a.hub.clock();
    a.settleRequest();
    if (now < a.ignored_until) {
        c.frameIn(@floatCast(a.ignored_until - now));
        ui.text(c, ignored_click, .{ .size = 12, .color = k.red, .wrap = true });
    }
    const r = a.gate.request orelse return;
    const armed = a.gate.armed(now);
    c.frameIn(@floatCast(if (armed) r.at + control.lifetime - now else r.at + control.armed_after - now));
    const d = ui.div(c).column().wFull().p(14).gap(10).bg(k.card).border(k.accent).borderW(2).rounded(12);
    defer d.end();
    ui.text(c, c.print("A request from {s}", .{r.from()}), .{ .size = 13, .weight = .semibold, .color = k.accent });
    ui.text(c, r.want.question(), .{ .size = 14, .color = k.text, .wrap = true });
    const row = ui.div(c).row().itemsCenter().gap(8);
    defer row.end();
    if (ui.button(c, "Allow", .{ .variant = .primary, .disabled = !armed }).clicked) a.answer(true);
    if (ui.button(c, "Deny", .{}).clicked) a.answer(false);
}

pub const ignored_click = "That click came from a program, so it was ignored. Only your own mouse or trackpad turns things on.";

fn permissions(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (comptime !mac) return;
    const d = card(c, k);
    defer d.end();
    title(c, k, "Permissions");
    permission(c, a, k, "Accessibility", "To read apps' controls, click and type", a.perms.accessibility, .accessibility);
    permission(c, a, k, "Screen Recording", "For screenshots", a.perms.screen, .screen);
    if (a.asked_screen and !a.perms.screen)
        ui.text(c, screen_hint, .{ .size = 12, .color = k.accent, .wrap = true });
}

fn permission(c: *ui.Context, a: *App, k: theme.Colors, name: []const u8, what: []const u8, on: bool, which: App.Ask) void {
    const row = ui.div(c).row().wFull().itemsCenter().gap(10);
    defer row.end();
    {
        const col = ui.div(c).column().gap(2).grow();
        defer col.end();
        ui.text(c, name, .{ .size = 14, .weight = .medium, .color = k.text });
        ui.text(c, what, .{ .size = 12, .color = k.secondary });
    }
    if (on) ui.badge(c, "Allowed", k.green) else {
        if (ui.button(c, "Allow…", .{ .size = 13 }).clicked) a.request(which);
    }
}

fn agents(c: *ui.Context, a: *App, k: theme.Colors) void {
    const d = card(c, k);
    defer d.end();
    title(c, k, "Agents");
    var input = a.hub.policy.allow_input;
    if (ui.toggle(c, "Allow input: clicks, typing, keys, opening apps", &input)) a.fromPanel(.input, input);
    var whole = a.hub.policy.allow_whole_screen;
    if (ui.toggle(c, "Allow whole screen: your pointer and keyboard, pictures of everything", &whole)) a.fromPanel(.whole_screen, whole);
    ui.text(c, "Off, agents work inside one app at a time, in the background.", .{ .size = 12, .color = k.secondary, .wrap = true });
    if (a.listen_error) |e| {
        ui.text(c, e, .{ .size = 12, .color = k.red, .wrap = true });
    } else {
        const n = a.server.clients();
        const waiting = a.hub.pending;
        ui.text(c, if (n == 0) "No agent connected" else c.print("{d} agent{s} connected{s}", .{
            n, if (n == 1) "" else "s", if (waiting > 0) c.print(", {d} call{s} running", .{ waiting, if (waiting == 1) "" else "s" }) else "",
        }), .{ .size = 13, .color = k.text });
    }
    ui.text(c, "Add nanocua to an agent as an MCP server (stdio) that runs:", .{ .size = 12, .color = k.secondary, .wrap = true });
    {
        const r = ui.div(c).row().wFull().itemsCenter().gap(8);
        defer r.end();
        {
            const well = ui.div(c).row().grow().px(10).py(7).bg(k.well).rounded(8);
            defer well.end();
            ui.text(c, a.command, .{ .size = 12, .mono = true, .color = k.text, .truncate = .ellipsis });
        }
        const now = a.hub.clock();
        if (ui.button(c, if (now < a.copied_until) "Copied" else "Copy", .{ .size = 13 }).clicked) {
            c.clipboard.write(c.clipboard.ctx, a.command);
            a.copied_until = now + 2;
        }
    }
    if (comptime mac) {
        if (a.hotkey != null) {
            const r = ui.div(c).row().itemsCenter().gap(6);
            defer r.end();
            ui.text(c, "Stop everything from anywhere:", .{ .size = 12, .color = k.secondary });
            ui.kbd(c, @import("mac/hotkey.zig").label);
        } else ui.text(c, "The stop key couldn't be set up: use Stop above, or `graff computer stop`.", .{ .size = 12, .color = k.secondary, .wrap = true });
    }
}

fn activity(c: *ui.Context, a: *App, k: theme.Colors) void {
    const log = &a.hub.log;
    const d = card(c, k).grow();
    defer d.end();
    {
        const r = ui.div(c).row().wFull().itemsCenter().gap(8);
        defer r.end();
        title(c, k, "Activity");
        if (log.calls > 0) ui.text(c, c.print("{d} call{s}, {d} refused", .{ log.calls, if (log.calls == 1) "" else "s", log.denied }), .{ .size = 12, .color = k.secondary });
        ui.spacer(c);
        if (log.len > 0 and ui.button(c, "Clear", .{ .variant = .ghost, .size = 12 }).clicked) log.clear();
    }
    if (log.len == 0) {
        ui.text(c, "Nothing yet. Every call an agent makes shows here.", .{ .size = 12, .color = k.secondary });
        return;
    }
    const list = ui.div(c).column().wFull().grow().scrollY().gap(2);
    defer list.end();
    var i: usize = 0;
    while (log.newest(i)) |e| : (i += 1) {
        ui.key(c, c.print("{d}", .{e.seq}));
        entry(c, k, e);
    }
}

fn entry(c: *ui.Context, k: theme.Colors, e: *const policy.Entry) void {
    const col = ui.div(c).column().wFull().gap(2).py(5);
    defer col.end();
    {
        const r = ui.div(c).row().wFull().itemsCenter().gap(8);
        defer r.end();
        ui.text(c, @tagName(e.tool), .{ .size = 13, .weight = .medium, .mono = true, .color = k.text });
        ui.text(c, e.summary(), .{ .size = 12, .mono = true, .color = k.secondary, .truncate = .ellipsis });
        ui.spacer(c);
        if (e.status != .running) ui.text(c, c.print("{d:.0} ms", .{e.ms}), .{ .size = 11, .color = k.secondary });
        switch (e.status) {
            .running => ui.badge(c, "running", k.accent),
            .ok => ui.badge(c, "done", k.green),
            .failed => ui.badge(c, "failed", k.red),
            .denied => ui.badge(c, "refused", k.yellow),
        }
    }
    if (e.detail().len > 0 and e.status != .ok)
        ui.text(c, e.detail(), .{ .size = 11, .color = k.secondary, .truncate = .ellipsis });
}
