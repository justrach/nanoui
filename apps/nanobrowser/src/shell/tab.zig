//! One tab: where it has been, and the page it shows now. Each navigation
//! makes a new `Page`; going back loads again, at the scroll it left.
const std = @import("std");
const nanoui = @import("nanoui");
const Page = @import("../page.zig").Page;
const address = @import("address.zig");

/// `doc`: the page this entry is a state of, when scripts pushed it
/// (`history.pushState`, a fragment): going there needs no load.
pub const Entry = struct { url: []u8, scroll: f32 = 0, doc: ?*Page = null };

pub const Tab = struct {
    gpa: std.mem.Allocator,
    host: Page.Host,
    page: ?*Page = null,
    history: std.ArrayList(Entry) = .empty,
    /// Which entry shows.
    at: usize = 0,
    /// What a tab shows while it is empty.
    title_buf: [128]u8 = undefined,

    pub fn create(gpa: std.mem.Allocator, host: Page.Host) !*Tab {
        const t = try gpa.create(Tab);
        t.* = .{ .gpa = gpa, .host = host };
        return t;
    }

    pub fn destroy(t: *Tab) void {
        if (t.page) |p| p.destroy();
        for (t.history.items) |e| t.gpa.free(e.url);
        t.history.deinit(t.gpa);
        t.gpa.destroy(t);
    }

    pub fn isEmpty(t: *const Tab) bool {
        return t.history.items.len == 0;
    }

    pub fn url(t: *const Tab) []const u8 {
        if (t.page) |p| return p.url();
        return if (t.history.items.len > 0) t.history.items[t.at].url else "";
    }

    pub fn title(t: *Tab) []const u8 {
        if (t.page) |p| {
            const s = p.title();
            if (s.len > 0) return s;
        }
        if (t.isEmpty()) return "New Tab";
        return address.hostOf(t.url());
    }

    pub fn loading(t: *const Tab) bool {
        return if (t.page) |p| p.isLoading() else false;
    }

    /// Goes to `dest`, leaving what was ahead of here behind.
    pub fn go(t: *Tab, dest: []const u8) void {
        t.keepScroll();
        const copy = t.gpa.dupe(u8, dest) catch return;
        for (t.history.items[@min(t.at + 1, t.history.items.len)..]) |e| t.gpa.free(e.url);
        t.history.items.len = @min(t.at + 1, t.history.items.len);
        t.history.append(t.gpa, .{ .url = copy }) catch {
            t.gpa.free(copy);
            return;
        };
        t.at = t.history.items.len - 1;
        t.show(.{});
    }

    /// Goes to `dest` with a form's body.
    pub fn post(t: *Tab, dest: []const u8, body: []const u8) void {
        t.keepScroll();
        const copy = t.gpa.dupe(u8, dest) catch return;
        for (t.history.items[@min(t.at + 1, t.history.items.len)..]) |e| t.gpa.free(e.url);
        t.history.items.len = @min(t.at + 1, t.history.items.len);
        t.history.append(t.gpa, .{ .url = copy }) catch {
            t.gpa.free(copy);
            return;
        };
        t.at = t.history.items.len - 1;
        t.show(.{ .method = "POST", .body = body });
    }

    pub fn canGoBack(t: *const Tab) bool {
        return t.at > 0;
    }

    pub fn canGoForward(t: *const Tab) bool {
        return t.at + 1 < t.history.items.len;
    }

    pub fn back(t: *Tab) void {
        if (!t.canGoBack()) return;
        t.keepScroll();
        t.at -= 1;
        if (t.sameDocument()) return t.page.?.stepHistory(-1);
        t.show(.{});
    }

    pub fn forward(t: *Tab) void {
        if (!t.canGoForward()) return;
        t.keepScroll();
        t.at += 1;
        if (t.sameDocument()) return t.page.?.stepHistory(1);
        t.show(.{});
    }

    fn sameDocument(t: *const Tab) bool {
        const d = t.history.items[t.at].doc orelse return false;
        return t.page == d;
    }

    /// The page's scripts pushed a state: a new entry, ahead of here given up.
    pub fn pushed(t: *Tab, page: *Page, to: []const u8) void {
        if (t.history.items.len == 0) return;
        const copy = t.gpa.dupe(u8, to) catch return;
        for (t.history.items[t.at + 1..]) |e| t.gpa.free(e.url);
        t.history.items.len = t.at + 1;
        t.history.items[t.at].doc = page;
        t.history.append(t.gpa, .{ .url = copy, .doc = page }) catch {
            t.gpa.free(copy);
            return;
        };
        t.at = t.history.items.len - 1;
    }

    pub fn reload(t: *Tab) void {
        if (t.isEmpty()) return;
        t.keepScroll();
        t.show(.{});
    }

    /// The page's redirects settled on another URL: this entry is that one.
    pub fn settled(t: *Tab, final: []const u8) void {
        if (t.history.items.len == 0) return;
        const copy = t.gpa.dupe(u8, final) catch return;
        const e = &t.history.items[t.at];
        t.gpa.free(e.url);
        e.url = copy;
    }

    fn keepScroll(t: *Tab) void {
        if (t.page) |p| if (t.history.items.len > 0) {
            t.history.items[t.at].scroll = p.scrollY();
        };
    }

    fn show(t: *Tab, req: Page.Load) void {
        if (t.page) |p| p.destroy();
        t.page = null;
        const e = t.history.items[t.at];
        const p = Page.create(t.gpa, t.host) catch return;
        t.page = p;
        p.restore_scroll = e.scroll;
        p.load(e.url, req);
    }
};
