//! A page's `<iframe>`s: each holds a nested `Page` with its own document, layout
//! and script world. A page full of ad frames stays cheap: a cross-origin frame
//! is only fetched near the viewport, a few at a time, and only so many stay alive.
const std = @import("std");
const nanoui = @import("nanoui");
const dom = @import("dom.zig");
const box = @import("layout/box.zig");
const layout = @import("layout/layout.zig");
const page_mod = @import("page.zig");
const Page = page_mod.Page;
const Allocator = std.mem.Allocator;

/// Frames nested deeper than this hold nothing.
pub const max_depth = 6;
/// Frames fetching at once, and alive at once, under one tab.
const max_loading = 4;
const max_live = 24;
/// Frames without a box of any size that a cross-origin page may keep alive.
const max_hidden = 8;
/// How far beyond the viewport a frame starts to load, in viewports.
const near = 1.0;

/// What `sandbox` lets a frame do.
pub const Sandbox = struct {
    on: bool = false,
    scripts: bool = true,
    same_origin: bool = true,
    forms: bool = true,
    popups: bool = true,
    top_navigation: bool = true,
};

pub const Frame = struct {
    owner: *Page,
    node: *dom.Node,
    page: ?*Page = null,
    /// What it was last told to show: its `src` or `srcdoc` as written.
    wanted: []const u8 = "",
    srcdoc: bool = false,
    /// Where it is in the window this frame; what the child's scripts measure against.
    rect: box.Rect = .{},
    /// `load` has fired for the page it holds.
    load_told: bool = false,
    loading: bool = false,
    /// A hop in `<a target>` or `location` asked for this instead of `wanted`.
    navigated: bool = false,
    /// The number scripts know this frame's window by, once they have one (`api_frames.zig`).
    window_id: u32 = 0,
    sandbox: Sandbox = .{},
};

pub const Frames = struct {
    list: std.ArrayList(*Frame) = .empty,
    /// The child page under the pointer or holding the keyboard.
    focused: ?*Page = null,
};

/// The page at the top of `p`'s tree: the tab's.
pub fn topOf(p: *Page) *Page {
    var at = p;
    while (at.frame) |f| at = f.owner;
    return at;
}

/// Every frame under `p`, itself excluded, counted by what's asked of them.
fn tally(p: *const Page, live: *u32, loading: *u32) void {
    for (p.frames.list.items) |f| {
        if (f.page) |c| {
            live.* += 1;
            if (f.loading) loading.* += 1;
            tally(c, live, loading);
        }
    }
}

pub fn frameOf(p: *const Page, n: *const dom.Node) ?*Frame {
    for (p.frames.list.items) |f| if (f.node == n) return f;
    return null;
}

fn parseSandbox(n: *const dom.Node) Sandbox {
    const v = n.attr("sandbox") orelse return .{};
    var out: Sandbox = .{ .on = true, .scripts = false, .same_origin = false, .forms = false, .popups = false, .top_navigation = false };
    var it = std.mem.tokenizeAny(u8, v, " \t\r\n\x0c");
    while (it.next()) |w| {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(w, "allow-scripts")) out.scripts = true;
        if (eq(w, "allow-same-origin")) out.same_origin = true;
        if (eq(w, "allow-forms")) out.forms = true;
        if (eq(w, "allow-popups")) out.popups = true;
        if (eq(w, "allow-top-navigation")) out.top_navigation = true;
    }
    return out;
}

/// The child's host: what it asks of the window goes through its owner.
fn hostOf(f: *Frame) Page.Host {
    return .{ .ctx = f, .navigate = childNavigate, .redraw = childRedraw, .loaded = childLoaded, .uiContext = childUi, .viewport = childViewport, .urlChanged = childUrl, .history = childHistory, .retire = childRetire };
}

fn frameFrom(ctx: *anyopaque) *Frame {
    return @ptrCast(@alignCast(ctx));
}

fn childNavigate(ctx: *anyopaque, page: *Page, to: Page.Navigation) void {
    const f = frameFrom(ctx);
    if (to.new_tab) {
        if (f.sandbox.popups) f.owner.host.navigate(f.owner.host.ctx, f.owner, to);
        return;
    }
    _ = page;
    navigateTo(f, to.url, if (to.post) .{ .method = "POST", .body = to.body } else .{});
}

fn childRedraw(ctx: *anyopaque) void {
    frameFrom(ctx).owner.redraw();
}

/// The child reached a resting point: its element hears `load`, and the next frame
/// in the queue gets a turn.
fn childLoaded(ctx: *anyopaque, page: *Page) void {
    const f = frameFrom(ctx);
    if (page.state != .done and page.state != .failed) return;
    f.loading = false;
    if (!f.load_told) {
        f.load_told = true;
        @import("web/web.zig").imageDone(f.owner, f.node, true);
    }
    f.owner.redraw();
}

fn childUi(ctx: *anyopaque) ?*nanoui.ui.Context {
    const o = frameFrom(ctx).owner;
    return o.host.uiContext(o.host.ctx);
}

fn childViewport(ctx: *anyopaque) [2]f32 {
    const f = frameFrom(ctx);
    if (f.rect.w > 0 or f.rect.h > 0) return .{ f.rect.w, f.rect.h };
    // Measured from its box, for a frame not drawn yet.
    if (layout.boxOfNode(f.node)) |b| {
        const r = b.contentRect();
        return .{ r.w, r.h };
    }
    return .{ 0, 0 };
}

fn childUrl(_: *anyopaque, _: *Page, _: bool) void {}

fn childHistory(_: *anyopaque, _: *Page, _: i32) void {}

fn childRetire(ctx: *anyopaque, page: *Page) void {
    const o = frameFrom(ctx).owner;
    o.host.retire(o.host.ctx, page);
}

/// What the iframe's attributes ask it to show.
fn wantedOf(n: *const dom.Node) struct { text: []const u8, srcdoc: bool } {
    if (n.attr("srcdoc")) |s| return .{ .text = s, .srcdoc = true };
    return .{ .text = n.attr("src") orelse "", .srcdoc = false };
}

fn detach(f: *Frame) void {
    if (f.page) |c| {
        f.page = null;
        const o = f.owner;
        if (o.frames.focused == c) o.frames.focused = null;
        c.destroy();
    }
    f.loading = false;
}

/// Takes the frame's page down and forgets it.
fn drop(p: *Page, f: *Frame) void {
    detach(f);
    @import("web/api_frames.zig").forgetFrame(f);
    for (p.frames.list.items, 0..) |x, i| if (x == f) {
        _ = p.frames.list.orderedRemove(i);
        break;
    };
    p.gpa.destroy(f);
}

/// A dying page's frames go first, while it can still pass their retirement on.
pub fn destroyAll(p: *Page) void {
    while (p.frames.list.items.len > 0) drop(p, p.frames.list.items[p.frames.list.items.len - 1]);
    p.frames.list.deinit(p.gpa);
    p.frames.list = .empty;
}

fn connected(n: *const dom.Node) bool {
    var at: ?*const dom.Node = n;
    while (at) |x| : (at = x.parent) if (x.kind == .document) return true;
    return false;
}

/// An iframe seen in the document: it gets a frame, and what it now asks for.
pub fn note(p: *Page, n: *dom.Node) void {
    const w = wantedOf(n);
    if (frameOf(p, n)) |f| {
        if (!std.mem.eql(u8, f.wanted, w.text) or f.srcdoc != w.srcdoc) {
            f.wanted = p.arena().dupe(u8, w.text) catch return;
            f.srcdoc = w.srcdoc;
            f.navigated = false;
            f.sandbox = parseSandbox(n);
            detach(f);
            f.load_told = false;
        }
        return;
    }
    const f = p.gpa.create(Frame) catch return;
    f.* = .{ .owner = p, .node = n, .wanted = p.arena().dupe(u8, w.text) catch "", .srcdoc = w.srcdoc, .sandbox = parseSandbox(n) };
    p.frames.list.append(p.gpa, f) catch {
        p.gpa.destroy(f);
        return;
    };
    // Nothing to fetch: scripts expect it there at once.
    if (isBlank(f)) start(f);
}

fn isBlank(f: *const Frame) bool {
    if (f.srcdoc) return false;
    return f.wanted.len == 0 or std.mem.eql(u8, f.wanted, "about:blank");
}

/// Frames whose iframe has left the document go. True if any did.
pub fn sweep(p: *Page) void {
    var i = p.frames.list.items.len;
    while (i > 0) {
        i -= 1;
        const f = p.frames.list.items[i];
        if (!connected(f.node)) drop(p, f);
    }
}

/// A page's origin, `null` when it has none to share. A frame with no address of its
/// own has its owner's; a sandboxed one has none.
pub fn originOf(a: Allocator, p: *const Page) []const u8 {
    _ = a;
    const home = originHome(p);
    if (home.frame) |f| if (f.sandbox.on and !f.sandbox.same_origin) return "null";
    return urlOrigin(home.final_url);
}

/// The scheme, host and port of an address; `null` for those that have none.
pub fn urlOrigin(u: []const u8) []const u8 {
    if (std.ascii.startsWithIgnoreCase(u, "data:") or std.ascii.startsWithIgnoreCase(u, "about:") or std.ascii.startsWithIgnoreCase(u, "blob:")) return "null";
    const scheme_end = std.mem.indexOf(u8, u, "://") orelse return "null";
    const from = scheme_end + 3;
    const rest = u[from..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const whole = u[0 .. from + end];
    // A scheme's own port isn't part of its origin: reCAPTCHA says `https://x:443`.
    const https = std.ascii.startsWithIgnoreCase(u, "https://");
    const http = std.ascii.startsWithIgnoreCase(u, "http://");
    if (https and std.mem.endsWith(u8, whole, ":443")) return whole[0 .. whole.len - 4];
    if (http and std.mem.endsWith(u8, whole, ":80")) return whole[0 .. whole.len - 3];
    return whole;
}

/// The page whose origin a page has: its own, or for one with no address the page
/// that made it.
fn originHome(p: *const Page) *const Page {
    var at = p;
    while (at.frame) |f| {
        if (f.sandbox.on and !f.sandbox.same_origin) return at;
        if (!std.mem.startsWith(u8, at.final_url, "about:")) return at;
        at = f.owner;
    }
    return at;
}

pub fn sameOrigin(a: *const Page, b: *const Page) bool {
    const x = originHome(a);
    const y = originHome(b);
    if (x == y) return true;
    if (x.frame) |f| if (f.sandbox.on and !f.sandbox.same_origin) return false;
    if (y.frame) |f| if (f.sandbox.on and !f.sandbox.same_origin) return false;
    const ox = urlOrigin(x.final_url);
    const oy = urlOrigin(y.final_url);
    if (std.mem.eql(u8, ox, "null") or std.mem.eql(u8, oy, "null")) return false;
    return std.mem.eql(u8, ox, oy);
}

/// Whether an address is that of one of the frames holding it, or the owner:
/// a page framing itself would never end.
fn recursive(f: *const Frame, url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "about:")) return false;
    var at: ?*const Page = f.owner;
    while (at) |p| : (at = if (p.frame) |x| x.owner else null) {
        if (std.mem.eql(u8, p.final_url, url)) return true;
    }
    return false;
}

fn depthOf(p: *const Page) u32 {
    var n: u32 = 0;
    var at = p;
    while (at.frame) |f| : (at = f.owner) n += 1;
    return n;
}

/// Gives the frame a page and starts it on what it wants.
pub fn start(f: *Frame) void {
    if (f.page != null) return;
    const o = f.owner;
    if (o.dead or depthOf(o) + 1 >= max_depth) return;
    if (f.srcdoc) {
        return begin(f, "about:srcdoc", .{}, f.wanted);
    }
    const ref = if (f.wanted.len > 0) f.wanted else "about:blank";
    const url = @import("loader.zig").linkFrom(o, ref) orelse ref;
    if (recursive(f, url)) return;
    begin(f, url, .{}, null);
}

/// Frames that want to start and may: near the viewport, as the pool allows.
pub fn schedule(p: *Page) void {
    if (p.frames.list.items.len == 0) return;
    var live: u32 = 0;
    var loading: u32 = 0;
    tally(topOf(p), &live, &loading);
    var hidden: u32 = 0;
    for (p.frames.list.items) |f| {
        if (f.page == null) continue;
        const r = layout.rectOf(f.node);
        if (r == null or r.?.w <= 1 or r.?.h <= 1) hidden += 1;
    }
    const sy = p.scrollY();
    for (p.frames.list.items) |f| {
        if (f.page != null) continue;
        if (live >= max_live or loading >= max_loading) return;
        if (!wantedNow(p, f, sy, &hidden)) continue;
        start(f);
        if (f.page != null) {
            live += 1;
            if (f.loading) loading += 1;
        }
    }
}

/// Whether a frame not yet started should be. Its own origin's frames are part of its
/// page and go whatever their place; others wait for the viewport, and those with
/// no box are mostly trackers, of which a page gets a few.
fn wantedNow(p: *const Page, f: *const Frame, sy: f32, hidden: *u32) bool {
    if (!f.srcdoc and f.wanted.len > 0) {
        const lazy = if (f.node.attr("loading")) |v| std.ascii.eqlIgnoreCase(v, "lazy") else false;
        const url = @import("loader.zig").linkFrom(@constCast(p), f.wanted) orelse f.wanted;
        const mine = urlOrigin(p.final_url);
        const own = !std.mem.eql(u8, mine, "null") and std.mem.eql(u8, urlOrigin(url), mine);
        const r = layout.rectOf(f.node);
        if (r == null or r.?.w <= 1 or r.?.h <= 1) {
            if (own and !lazy) return true;
            if (hidden.* >= max_hidden) return false;
            hidden.* += 1;
            return true;
        }
        if (own and !lazy) return true;
        const reach = p.viewport_h * near;
        return r.?.y + r.?.h >= sy - reach and r.?.y <= sy + p.viewport_h + reach;
    }
    return true;
}

fn begin(f: *Frame, url: []const u8, req: Page.Load, srcdoc: ?[]const u8) void {
    const o = f.owner;
    const child = Page.create(o.gpa, hostOf(f)) catch return;
    child.frame = f;
    child.dark = o.dark;
    child.engine.scripting = f.sandbox.scripts;
    child.no_scripts = !f.sandbox.scripts;
    f.page = child;
    f.loading = true;
    f.load_told = false;
    if (srcdoc) |text| {
        child.final_url = o.gpa.dupe(u8, url) catch &.{};
        child.doc.url = child.final_url;
        child.documentArrived(200, text, url, "text/html", "");
    } else child.load(url, req);
    if (f.page == child and (child.state == .done or child.state == .failed)) childLoaded(f, child);
}

/// The frame goes to another address: its old page leaves.
pub fn navigateTo(f: *Frame, url: []const u8, req: Page.Load) void {
    const copy = f.owner.gpa.dupe(u8, url) catch return;
    defer f.owner.gpa.free(copy);
    detach(f);
    if (recursive(f, copy)) return;
    f.navigated = true;
    begin(f, copy, req, null);
    f.owner.redraw();
}

/// A named frame under `p`, for `<a target>`.
pub fn named(p: *Page, name: []const u8) ?*Frame {
    for (p.frames.list.items) |f| {
        if (f.node.attr("name")) |v| if (std.mem.eql(u8, v, name)) return f;
        if (f.page) |c| if (named(c, name)) |x| return x;
    }
    return null;
}

/// The frames in view, with where they are in the window: what a frame draws.
pub fn childPage(p: *const Page, n: *const dom.Node) ?*Page {
    const f = frameOf(p, n) orelse return null;
    return f.page;
}

/// Sets the focus chain to `p`, for the keyboard.
pub fn focusChain(p: *Page) void {
    var at = p;
    at.frames.focused = null;
    while (at.frame) |f| {
        f.owner.frames.focused = at;
        at = f.owner;
    }
}

/// The page the keyboard goes to.
pub fn keyboardPage(top: *Page) *Page {
    var at = top;
    while (at.frames.focused) |c| at = c;
    return at;
}

test "an address's origin" {
    try std.testing.expectEqualStrings("https://a.test:8080", urlOrigin("https://a.test:8080/x?y#z"));
    try std.testing.expectEqualStrings("https://a.test", urlOrigin("https://a.test"));
    try std.testing.expectEqualStrings("https://a.test", urlOrigin("https://a.test:443/x"));
    try std.testing.expectEqualStrings("http://a.test", urlOrigin("http://a.test:80"));
    try std.testing.expectEqualStrings("https://a.test:80", urlOrigin("https://a.test:80"));
    try std.testing.expectEqualStrings("http://a.test:443", urlOrigin("http://a.test:443"));
    try std.testing.expectEqualStrings("null", urlOrigin("data:text/html,hi"));
    try std.testing.expectEqualStrings("null", urlOrigin("about:blank"));
}
