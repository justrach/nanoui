//! The window's view: the tabs and the page are the whole of it. ⌘L to go
//! somewhere, ⌘K to find a tab, ⌘S to hide the tabs altogether, ⌘D for two
//! pages side by side.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Page = @import("../page.zig").Page;
const Tab = @import("tab.zig").Tab;
const strip = @import("strip.zig");
const omnibox = @import("omnibox.zig");
const switcher = @import("switcher.zig");
const address = @import("address.zig");
const search = @import("search.zig");
const Suggest = @import("suggest.zig").Suggest;
const theme = @import("theme.zig");
const box = @import("../layout/box.zig");
const m = theme.metrics;

const max_offers = 8;

pub const Browser = struct {
    gpa: std.mem.Allocator,
    window: ?*nanoui.Window = null,
    tabs: std.ArrayList(*Tab) = .empty,
    current: usize = 0,
    /// Addresses of closed tabs, the newest last: ⇧⌘T.
    closed: std.ArrayList([]u8) = .empty,
    tabs_hidden: bool = false,
    /// The other page of a split, beside the current one.
    split: ?*Tab = null,
    /// The address field raised over the page.
    address_open: bool = false,
    box: omnibox.Omnibox = .{},
    engine: search.Engine = .google,
    /// Null where nothing should reach an engine as it's typed: in tests.
    suggest: ?*Suggest = null,
    /// Remembers the engine across runs: `main` says so, tests don't.
    keep_engine: bool = false,
    /// In tests, where a search goes instead of the engine.
    search_base: ?[]const u8 = null,
    /// ⌘K.
    finder: switcher.Switcher = .{},
    /// ⌘F.
    find_open: bool = false,
    find_field: ui.TextBuffer = .{},
    find_wants_focus: bool = false,
    /// Places been, for the field's offers.
    visited: std.ArrayList(omnibox.Offer) = .empty,
    /// The window's title, last set.
    title_set: u64 = 0,
    /// The frame drew and something it didn't own moved on: draw another.
    dirty: bool = false,
    /// The context of the last frame, and the page's size in it: pages measure
    /// text with it when a script asks for geometry outside a frame.
    context: ?*ui.Context = null,
    page_size: [2]f32 = .{ 1280, 800 },
    /// Pages let go of in this frame: what it has drawn may still read their
    /// strings, so they are freed when the next one starts.
    retired: std.ArrayList(*Page) = .empty,

    pub fn init(b: *Browser) !void {
        try b.newTab(null);
    }

    /// What a real run has and a test doesn't: the chosen engine, and suggestions.
    pub fn connect(b: *Browser) !void {
        b.engine = search.load(b.gpa);
        b.keep_engine = true;
        b.suggest = try Suggest.create(b.gpa, b, redrawn);
    }

    pub fn deinit(b: *Browser) void {
        if (b.suggest) |s| s.release();
        for (b.tabs.items) |t| t.destroy();
        b.tabs.deinit(b.gpa);
        if (b.split) |t| t.destroy();
        for (b.closed.items) |s| b.gpa.free(s);
        b.closed.deinit(b.gpa);
        for (b.visited.items) |o| {
            b.gpa.free(o.url);
            b.gpa.free(o.title);
        }
        b.visited.deinit(b.gpa);
        b.freeRetired();
        b.retired.deinit(b.gpa);
    }

    fn retire(ctx: *anyopaque, page: *Page) void {
        const b: *Browser = @ptrCast(@alignCast(ctx));
        b.retired.append(b.gpa, page) catch {
            page.busy -= 1;
            page.maybeFree();
        };
    }

    fn freeRetired(b: *Browser) void {
        for (b.retired.items) |page| {
            page.busy -= 1;
            page.maybeFree();
        }
        b.retired.clearRetainingCapacity();
    }

    fn host(b: *Browser) Page.Host {
        return .{ .ctx = b, .navigate = navigated, .redraw = redrawn, .loaded = pageLoaded, .uiContext = uiContext, .viewport = viewport, .urlChanged = urlChanged, .history = historyAsked, .retire = retire };
    }

    pub fn redrawn(ctx: *anyopaque) void {
        const b: *Browser = @ptrCast(@alignCast(ctx));
        b.dirty = true;
        if (b.window) |w| w.redraw();
    }

    /// A page asks to go somewhere: a link, a form, `location.href`.
    fn navigated(ctx: *anyopaque, page: *Page, to: Page.Navigation) void {
        const b: *Browser = @ptrCast(@alignCast(ctx));
        const t = b.tabOf(page) orelse return;
        const dest = b.gpa.dupe(u8, to.url) catch return;
        defer b.gpa.free(dest);
        if (to.new_tab) {
            b.newTab(dest) catch {};
            return;
        }
        const body = b.gpa.dupe(u8, to.body) catch return;
        defer b.gpa.free(body);
        // After this frame's work on the page that asked: it is about to go.
        if (to.post) t.post(dest, body) else t.go(dest);
        redrawn(ctx);
    }

    fn uiContext(ctx: *anyopaque) ?*ui.Context {
        const b: *Browser = @ptrCast(@alignCast(ctx));
        return b.context;
    }

    fn viewport(ctx: *anyopaque) [2]f32 {
        const b: *Browser = @ptrCast(@alignCast(ctx));
        return b.page_size;
    }

    /// `history.pushState` or a fragment: the tab's entry is the new address.
    fn urlChanged(ctx: *anyopaque, page: *Page, pushed: bool) void {
        const b: *Browser = @ptrCast(@alignCast(ctx));
        const t = b.tabOf(page) orelse return;
        if (pushed) t.pushed(page, page.url()) else t.settled(page.url());
        redrawn(ctx);
    }

    /// `history.go` past what the document itself pushed: the tab's own.
    fn historyAsked(ctx: *anyopaque, page: *Page, by: i32) void {
        const b: *Browser = @ptrCast(@alignCast(ctx));
        const t = b.tabOf(page) orelse return;
        var left = by;
        while (left < 0) : (left += 1) t.back();
        while (left > 0) : (left -= 1) t.forward();
        redrawn(ctx);
    }

    fn pageLoaded(ctx: *anyopaque, page: *Page) void {
        const b: *Browser = @ptrCast(@alignCast(ctx));
        const t = b.tabOf(page) orelse return;
        t.settled(page.url());
        b.remember(page.url(), page.title());
        redrawn(ctx);
    }

    fn remember(b: *Browser, url: []const u8, title: []const u8) void {
        if (url.len == 0 or std.mem.startsWith(u8, url, "about:") or std.mem.startsWith(u8, url, "data:")) return;
        const u = b.gpa.dupe(u8, url) catch return;
        const t = b.gpa.dupe(u8, title) catch {
            b.gpa.free(u);
            return;
        };
        b.visited.append(b.gpa, .{ .url = u, .title = t }) catch {
            b.gpa.free(u);
            b.gpa.free(t);
        };
    }

    fn tabOf(b: *Browser, page: *Page) ?*Tab {
        for (b.tabs.items) |t| if (t.page == page) return t;
        if (b.split) |t| if (t.page == page) return t;
        return null;
    }

    fn live(b: *Browser) ?*Tab {
        return if (b.current < b.tabs.items.len) b.tabs.items[b.current] else null;
    }

    pub fn newTab(b: *Browser, url: ?[]const u8) !void {
        const t = try Tab.create(b.gpa, b.host());
        errdefer t.destroy();
        try b.tabs.append(b.gpa, t);
        b.current = b.tabs.items.len - 1;
        if (url) |u| t.go(u) else b.box.reset("");
    }

    pub fn closeCurrentTab(b: *Browser) void {
        b.closeTab(b.current);
    }

    fn closeTab(b: *Browser, i: usize) void {
        const t = b.tabs.items[i];
        if (!t.isEmpty()) {
            if (b.gpa.dupe(u8, t.url())) |s| b.closed.append(b.gpa, s) catch b.gpa.free(s) else |_| {}
        }
        _ = b.tabs.orderedRemove(i);
        t.destroy();
        if (b.tabs.items.len == 0) {
            b.newTab(null) catch {};
            return;
        }
        if (b.current >= b.tabs.items.len or b.current > i) b.current -|= 1;
    }

    fn openAddress(b: *Browser) void {
        const t = b.live() orelse return;
        b.address_open = true;
        b.box.reset(t.url());
    }

    fn toggleSplit(b: *Browser) void {
        if (b.split) |other| {
            b.split = null;
            b.tabs.append(b.gpa, other) catch other.destroy();
            return;
        }
        // The last tab beside this one, or a new one.
        if (b.tabs.items.len > 1) {
            const i: usize = if (b.current == 0) 1 else b.current - 1;
            b.split = b.tabs.orderedRemove(i);
            if (i < b.current) b.current -= 1;
            return;
        }
        b.split = Tab.create(b.gpa, b.host()) catch null;
    }

    /// ⌘ keys: the browser's before the page's.
    fn shortcuts(b: *Browser, c: *ui.Context) void {
        const t = b.live();
        if (c.shortcut(.{ .key = 't', .cmd = true })) b.newTab(null) catch {};
        if (c.shortcut(.{ .key = 'w', .cmd = true })) b.closeTab(b.current);
        if (c.shortcut(.{ .key = 'l', .cmd = true })) b.openAddress();
        if (c.shortcut(.{ .key = 'k', .cmd = true })) b.finder.open();
        if (c.shortcut(.{ .key = 's', .cmd = true })) b.tabs_hidden = !b.tabs_hidden;
        if (c.shortcut(.{ .key = 'd', .cmd = true })) b.toggleSplit();
        if (c.shortcut(.{ .key = 'd', .cmd = true, .shift = true })) if (t) |x| b.newTab(x.url()) catch {};
        if (c.shortcut(.{ .key = 't', .cmd = true, .shift = true })) if (b.closed.pop()) |s| {
            defer b.gpa.free(s);
            b.newTab(s) catch {};
        };
        if (c.shortcut(.{ .key = '[', .cmd = true })) if (t) |x| x.back();
        if (c.shortcut(.{ .key = ']', .cmd = true })) if (t) |x| x.forward();
        if (c.shortcut(.{ .key = 'r', .cmd = true })) if (t) |x| x.reload();
        if (c.shortcut(.{ .key = 'f', .cmd = true })) {
            b.find_open = true;
            b.find_wants_focus = true;
        }
        if (c.shortcut(.{ .key = 'g', .cmd = true })) if (t) |x| if (x.page) |p| p.findStep(1);
        if (c.shortcut(.{ .key = 'g', .cmd = true, .shift = true })) if (t) |x| if (x.page) |p| p.findStep(-1);
        if (c.shortcut(.{ .key = '\t', .ctrl = true })) b.current = (b.current + 1) % @max(b.tabs.items.len, 1);
        if (c.shortcut(.{ .key = '\t', .ctrl = true, .shift = true })) b.current = (b.current + b.tabs.items.len - 1) % @max(b.tabs.items.len, 1);
        for (0..9) |i| if (c.shortcut(.{ .key = '1' + @as(u21, @intCast(i)), .cmd = true })) {
            if (i < b.tabs.items.len) b.current = i;
        };
        if (c.shortcut(.{ .key = ui.Shortcut.escape })) {
            if (b.finder.showing) b.finder.showing = false else if (b.address_open) b.address_open = false else if (b.find_open) {
                b.find_open = false;
                if (t) |x| if (x.page) |p| p.findStop();
            } else if (t) |x| if (x.page) |p| p.stop();
        }
    }

    pub fn view(b: *Browser, c: *ui.Context) void {
        const p = theme.of(c);
        b.dirty = false;
        b.context = c;
        b.freeRetired();
        b.shortcuts(c);
        b.keepTitle();
        _ = c.open(.{ .width = .fill, .height = .fill, .background = p.ground }, "browser");
        defer c.end();
        var top: f32 = m.bare;
        if (b.tabs_hidden) {
            c.title_bar_height = m.bare;
            _ = c.open(.{ .width = .fill, .height = .{ .px = m.bare }, .window_drag = true }, "bare");
            c.end();
        } else {
            top = m.strip;
            b.act(strip.view(c, b.tabs.items, b.current));
        }
        const h = @max(0, c.size.h - top);
        const w = c.size.w;
        if (b.split) |other| {
            const half = @floor(w / 2);
            if (b.live()) |t| b.pageIn(c, t, 0, top, half - 0.5, h, false);
            b.pageIn(c, other, half + 0.5, top, w - half - 0.5, h, true);
            _ = c.leaf(.{ .absolute = true, .fixed = true, .offset = .{ .x = half - 0.5, .y = top }, .width = .{ .px = 1 }, .height = .{ .px = h }, .background = p.hairline }, .none, "divider");
        } else if (b.live()) |t| b.pageIn(c, t, 0, top, w, h, false);
        if (b.find_open) b.findBar(c, top);
        if (b.finder.showing) b.switcherView(c, top, h);
        if (b.address_open) if (b.live()) |t| {
            var buf: [max_offers]omnibox.Offer = undefined;
            const r = b.box.view(c, 0, top, w, h, true, b.currentOffers(c, &buf), b.engine);
            b.fieldResult(c, t, r);
        };
    }

    /// A tab's page in a rectangle, or the field alone on an empty tab.
    fn pageIn(b: *Browser, c: *ui.Context, t: *Tab, x: f32, y: f32, w: f32, h: f32, side: bool) void {
        b.page_size = .{ w, h };
        if (t.page) |page| {
            page.view(c, .{ .x = x, .y = y, .w = w, .h = h });
            return;
        }
        if (b.address_open and !side) return;
        var buf: [max_offers]omnibox.Offer = undefined;
        const r = b.box.view(c, x, y, w, h, false, b.currentOffers(c, &buf), b.engine);
        b.fieldResult(c, t, r);
    }

    fn fieldResult(b: *Browser, c: *ui.Context, t: *Tab, r: omnibox.Omnibox.Result) void {
        switch (r) {
            .none, .typed => {},
            .dismiss => b.address_open = false,
            .go => |typed| {
                const url = search.destination(b.gpa, typed, b.engine, b.search_base) catch return orelse {
                    b.box.refuse(c.time);
                    return;
                };
                b.goTo(c, t, url);
            },
            .search => |query| {
                const url = search.resultsUrl(b.gpa, b.engine, query, b.search_base) catch return;
                b.goTo(c, t, url);
            },
            .engine => |e| {
                b.engine = e;
                if (b.keep_engine) search.save(e);
                b.box.wants_focus = true;
                c.changed = true;
            },
        }
    }

    /// Takes `url`, which it frees.
    fn goTo(b: *Browser, c: *ui.Context, t: *Tab, url: []u8) void {
        defer b.gpa.free(url);
        b.address_open = false;
        t.go(url);
        c.changed = true;
    }

    /// Places it knows first, then what the engine suggests for the same text.
    pub fn currentOffers(b: *Browser, c: *ui.Context, buf: *[max_offers]omnibox.Offer) []omnibox.Offer {
        const typed = b.box.field.text();
        const s = b.suggest orelse return omnibox.offersFor(typed, b.visited.items, buf);
        s.watch(c, typed, b.engine);
        if (typed.len == 0) return buf[0..0];
        var n = omnibox.offersFor(typed, b.visited.items, buf[0..if (s.rows.len > 0) @as(usize, 3) else buf.len]).len;
        const shown = std.mem.trim(u8, typed, " \t\r\n");
        for (s.rows) |row| {
            if (n == buf.len) break;
            if (std.ascii.eqlIgnoreCase(row, shown)) continue;
            buf[n] = .{ .url = row, .title = "", .search = true };
            n += 1;
        }
        return buf[0..n];
    }

    fn act(b: *Browser, a: strip.Action) void {
        const t = b.live();
        switch (a) {
            .none => {},
            .select => |i| b.current = i,
            .close => |i| b.closeTab(i),
            .new_tab => b.newTab(null) catch {},
            .back => if (t) |x| x.back(),
            .forward => if (t) |x| x.forward(),
            .reload => if (t) |x| {
                if (x.loading()) x.page.?.stop() else x.reload();
            },
            .address => b.openAddress(),
        }
    }

    fn switcherView(b: *Browser, c: *ui.Context, top: f32, h: f32) void {
        const titles = c.alloc().alloc(switcher.Row, b.tabs.items.len) catch return;
        for (b.tabs.items, titles) |t, *row| row.* = .{ .title = t.title(), .url = t.url() };
        if (b.finder.view(c, 0, top, c.size.w, h, titles)) |i| {
            b.current = i;
            c.changed = true;
        }
    }

    fn findBar(b: *Browser, c: *ui.Context, top: f32) void {
        const p = theme.of(c);
        const t = b.live() orelse return;
        const page = t.page orelse return;
        _ = c.open(.{
            .absolute = true,
            .fixed = true,
            .offset = .{ .x = c.size.w - 340, .y = top + 10 },
            .width = .{ .px = 320 },
            .direction = .row,
            .gap = 8,
            .padding = .xy(14, 8),
            .radius = 12,
            .align_items = .center,
            .background = p.ground,
            .border = p.hairline,
            .shadow = .{ .color = .{ .a = 0.08 }, .blur = 18, .y = 6 },
            .layer = 1,
        }, "find");
        defer c.end();
        if (b.find_wants_focus) {
            c.focus = c.peekId("find-field");
            b.find_wants_focus = false;
        }
        ui.key(c, "find-field");
        const r = ui.textField(c, &b.find_field, .{ .placeholder = "Find on page", .width = .fill, .size = 13, .bare = true, .select_all_on_focus = true, .color = p.ink, .placeholder_color = p.muted });
        if (r.changed) page.findText(b.find_field.text());
        if (r.submitted) page.findStep(1);
        ui.textf(c, .{ .size = 12, .color = p.muted }, "{d}", .{page.findCount()});
    }

    /// The window's title follows the live page.
    fn keepTitle(b: *Browser) void {
        const t = b.live() orelse return;
        const w = b.window orelse return;
        const s = t.title();
        const h = std.hash.Wyhash.hash(0, s);
        if (h == b.title_set) return;
        b.title_set = h;
        w.setTitle(s);
    }
};

/// What windows draw.
pub fn viewOf(b: *Browser, c: *ui.Context) void {
    b.view(c);
}

test {
    _ = strip;
    _ = omnibox;
    _ = address;
    _ = switcher;
    _ = box;
}
