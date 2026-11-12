//! One loaded document: fetching it and what it asks for, its style, layout and
//! display list, and its script world. A page outlives `destroy` for as long
//! as a request or a frame still holds it (`dead`); it frees itself then.
const std = @import("std");
const nanoui = @import("nanoui");
const dom = @import("dom.zig");
const html = @import("html/html.zig");
const css = @import("css/css.zig");
const box = @import("layout/box.zig");
const display = @import("paint/display.zig");
const gradient = @import("paint/gradient.zig");
const svg_markup = @import("paint/svg_markup.zig");
const loader = @import("loader.zig");
const web = @import("web/web.zig");
const view_mod = @import("page_view.zig");
const find_mod = @import("find.zig");
const frames_mod = @import("frames.zig");
const http = nanoui.http;
const Allocator = std.mem.Allocator;

/// Which Chrome the user agent says. Kept near the current stable: sites treat an
/// old one as out of date, and anything they don't recognize gets their plainest page.
pub const chrome_major = "158";
/// Chrome's own string, as Chromium's other browsers send it, with no name of ours.
pub const user_agent = "Mozilla/5.0 (" ++ platform_ua ++ ") AppleWebKit/537.36 (KHTML, like Gecko) Chrome/" ++ chrome_major ++ ".0.0.0 Safari/537.36";
const platform_ua = switch (@import("builtin").os.tag) {
    .macos => "Macintosh; Intel Mac OS X 10_15_7",
    .windows => "Windows NT 10.0; Win64; x64",
    .ios => "iPhone; CPU iPhone OS 18_0 like Mac OS X",
    else => "X11; Linux x86_64",
};

pub const Page = struct {
    gpa: Allocator,
    host: Host,
    /// The document and everything made for it die with this.
    doc_arena: std.heap.ArenaAllocator,
    doc: *dom.Document,
    engine: css.Engine,
    final_url: []u8 = &.{},
    state: State = .fetching,
    dead: bool = false,
    /// Requests under way, and frames being drawn: what `dead` waits for.
    pending: u32 = 0,
    busy: u32 = 0,

    /// Style sheets in document order, and what fetches them (`loader.zig`).
    sheets: loader.Sheets = .{},
    pictures: loader.Pictures = .{},
    /// What inline `<svg>`s were last drawn from.
    svgs: svg_markup.Cache = .{},
    /// What each `<canvas>` with a context shows.
    canvases: @import("paint/canvas_source.zig").Table = .{},
    webgl: @import("gl/context.zig").List = .{},
    gpu: @import("gpu/context.zig").Context = .{},
    /// The screen and window `srcset` and `media` were last answered for.
    pick_signature: u64 = 0,
    icon: ?[]const u8 = null,
    icon_key: []const u8 = "",
    icon_asked: bool = false,
    title_text: []const u8 = "",
    title_stale: bool = true,

    layout_arena: std.heap.ArenaAllocator,
    prev_layout_arena: std.heap.ArenaAllocator,
    /// The display list's own: a style change that moves nothing makes it again
    /// alone, each frame of an animation say.
    list_arena: std.heap.ArenaAllocator,
    list_dirty: bool = false,
    /// What the last new size cost to lay out and when that finished, in seconds.
    resize_cost: f64 = 0,
    resized_at: f64 = 0,
    /// The list is behind on something out of sight (`page_motion`).
    list_stale: bool = false,
    /// All that's animating is out of sight.
    motion_unseen: bool = false,
    /// How many times the display list has been built.
    lists: u32 = 0,
    /// Scrolling on its way (`page_glide`).
    glide: ?@import("page_glide.zig").Glide = null,
    /// How many times the page has been laid out.
    layouts: u32 = 0,
    list: ?display.List = null,
    tree: ?box.Tree = null,
    viewport_w: f32 = 0,
    viewport_h: f32 = 0,
    dark: bool = false,
    /// Scroll offsets by element, the page's under the document's node.
    scrolls: std.AutoHashMapUnmanaged(*dom.Node, [2]f32) = .empty,
    restore_scroll: f32 = 0,
    /// Text widths already measured, by text and font.
    widths: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    /// Fonts' line metrics, by font.
    font_metrics: std.AutoHashMapUnmanaged(u64, box.Metrics) = .empty,
    /// Its `@font-face` rules and what came of them (`webfonts.zig`).
    faces: @import("webfonts.zig").Faces = .{},
    gradients: gradient.Cache,
    /// Controls' editors (`paint/controls.zig`), freed with the page.
    editors: std.ArrayList(*nanoui.ui.TextBuffer) = .empty,
    /// The field that last had the keyboard, to tell when it loses it.
    field_focus: ?*dom.Node = null,
    /// A press gave this field the document's focus: the keys go with it, even if the
    /// style that brought (`:focus-within`) gave it another id than the one pressed.
    field_pressed: ?*dom.Node = null,
    /// The `<select>` whose list is open.
    open_select: ?*dom.Node = null,
    last_press: ?*dom.Node = null,
    find: find_mod.Find = .{},
    /// What the pointer was last over, to tell scripts it moved.
    pointer: [2]f32 = .{ -1, -1 },
    /// Until when what's under a still pointer doesn't count as hovered: it scrolled.
    hover_held_until: f64 = 0,
    /// Where the page's rectangle last was in the window: scripts' coordinates start here.
    origin: [2]f32 = .{ 0, 0 },

    /// Scripts: null until the document has any (or none ever).
    js: ?*web.World = null,
    /// `sandbox` without `allow-scripts`.
    no_scripts: bool = false,

    /// Its `<iframe>`s, and when it is in one, that one.
    frames: frames_mod.Frames = .{},
    frame: ?*frames_mod.Frame = null,
    /// The worker this page is the scripts of: it has no window and draws nothing.
    worker: ?*@import("web/api_worker.zig").Worker = null,
    /// The workers its scripts started.
    workers: std.ArrayList(*@import("web/api_worker.zig").Worker) = .empty,
    /// The number other pages' scripts know it by; 0 until one asks.
    id: u32 = 0,
    /// A wheel over this frame was taken by what's outside it.
    wheel_taken: bool = false,

    pub const State = enum { fetching, parsed, done, failed };

    /// What a page asks of the window it is in.
    pub const Host = struct {
        ctx: *anyopaque,
        navigate: *const fn (ctx: *anyopaque, page: *Page, to: Navigation) void,
        /// Something changed outside a frame: draw one.
        redraw: *const fn (ctx: *anyopaque) void,
        /// It settled on a URL and a title.
        loaded: *const fn (ctx: *anyopaque, page: *Page) void,
        /// The window's context for measuring text outside a frame; null until
        /// a frame has drawn.
        uiContext: *const fn (ctx: *anyopaque) ?*nanoui.ui.Context,
        /// The size a page has in the window, for one not drawn yet.
        viewport: *const fn (ctx: *anyopaque) [2]f32,
        /// The page moved to another address by itself (`history`, a fragment).
        urlChanged: *const fn (ctx: *anyopaque, page: *Page, pushed: bool) void,
        /// `history.go` past the entries the document itself pushed.
        history: *const fn (ctx: *anyopaque, page: *Page, by: i32) void,
        /// Holds a dying page to the next frame: this frame's strings may be its.
        retire: *const fn (ctx: *anyopaque, page: *Page) void,
    };

    pub const Navigation = struct {
        url: []const u8,
        new_tab: bool = false,
        post: bool = false,
        body: []const u8 = "",
    };

    pub const Load = struct {
        method: []const u8 = "GET",
        body: []const u8 = "",
    };

    pub fn create(gpa: Allocator, host: Host) !*Page {
        const p = try gpa.create(Page);
        errdefer gpa.destroy(p);
        p.* = .{
            .gpa = gpa,
            .host = host,
            .doc_arena = .init(gpa),
            .doc = undefined,
            .engine = undefined,
            .layout_arena = .init(gpa),
            .prev_layout_arena = .init(gpa),
            .list_arena = .init(gpa),
            .gradients = .{ .gpa = gpa },
        };
        errdefer p.doc_arena.deinit();
        p.doc = try dom.Document.create(p.doc_arena.allocator());
        p.engine = css.Engine.init(gpa, p.doc);
        @import("webfonts.zig").begin(p);
        return p;
    }

    /// Lets the page go; it is freed when the last thing holding it is done.
    pub fn destroy(p: *Page) void {
        web.forgetPage(p);
        p.dead = true;
        p.busy += 1;
        frames_mod.destroyAll(p);
        @import("web/api_worker.zig").destroyAll(p);
        p.host.retire(p.host.ctx, p);
    }

    /// Called as requests and frames finish.
    pub fn maybeFree(p: *Page) void {
        if (!p.dead or p.pending > 0 or p.busy > 0) return;
        const gpa = p.gpa;
        if (p.js) |w| w.destroy();
        p.engine.deinit();
        p.layout_arena.deinit();
        p.prev_layout_arena.deinit();
        p.list_arena.deinit();
        p.scrolls.deinit(gpa);
        p.widths.deinit(gpa);
        p.font_metrics.deinit(gpa);
        p.faces.deinit(gpa);
        p.gradients.deinit();
        for (p.editors.items) |e| gpa.destroy(e);
        p.editors.deinit(gpa);
        p.find.query.deinit(gpa);
        p.sheets.deinit(gpa);
        p.pictures.deinit(gpa);
        p.svgs.deinit(gpa);
        p.webgl.deinit(gpa);
        p.gpu.deinit();
        p.canvases.deinit(gpa);
        gpa.free(p.final_url);
        p.doc_arena.deinit();
        gpa.destroy(p);
    }

    pub fn arena(p: *Page) Allocator {
        return p.doc_arena.allocator();
    }

    pub fn url(p: *const Page) []const u8 {
        return p.final_url;
    }

    pub fn isLoading(p: *const Page) bool {
        const scripts_own: u32 = if (p.js) |w| w.net_pending else 0;
        return p.state == .fetching or p.pending > scripts_own;
    }

    pub fn title(p: *Page) []const u8 {
        if (p.title_stale) {
            p.title_stale = false;
            const raw = p.doc.title(p.arena()) catch "";
            p.title_text = collapse(p.arena(), raw) catch "";
        }
        return p.title_text;
    }

    pub fn favicon(p: *const Page) ?[]const u8 {
        return p.icon;
    }

    pub fn faviconKey(p: *const Page) []const u8 {
        return p.icon_key;
    }

    pub fn scrollY(p: *const Page) f32 {
        const s = p.scrolls.get(p.doc.node) orelse return 0;
        return s[1];
    }

    pub fn view(p: *Page, c: *nanoui.ui.Context, rect: box.Rect) void {
        view_mod.view(p, c, rect);
    }

    pub fn findText(p: *Page, query: []const u8) void {
        find_mod.set(p, query);
    }

    pub fn findStep(p: *Page, by: i32) void {
        find_mod.step(p, by);
    }

    pub fn findStop(p: *Page) void {
        find_mod.stop(p);
    }

    pub fn findCount(p: *const Page) usize {
        return p.find.count;
    }

    pub fn stop(p: *Page) void {
        p.pictures.cancelQueued();
        if (p.js) |w| w.stop();
    }

    pub fn redraw(p: *Page) void {
        if (!p.dead) p.host.redraw(p.host.ctx);
    }

    /// The page is at `to` now, without loading anything.
    pub fn setUrl(p: *Page, to: []const u8, pushed: bool) void {
        const copy = p.gpa.dupe(u8, to) catch return;
        p.gpa.free(p.final_url);
        p.final_url = copy;
        p.doc.url = copy;
        if (!p.dead) p.host.urlChanged(p.host.ctx, p, pushed);
    }

    /// The tab went back or forward within what this document pushed.
    pub fn stepHistory(p: *Page, by: i32) void {
        web.historyStep(p, by);
    }

    pub fn navigate(p: *Page, to: Navigation) void {
        // A page from the web doesn't open files.
        if (std.ascii.startsWithIgnoreCase(to.url, "file:") and !std.ascii.startsWithIgnoreCase(p.final_url, "file:")) return;
        if (!p.dead) p.host.navigate(p.host.ctx, p, to);
    }

    /// Starts fetching `dest`.
    pub fn load(p: *Page, dest: []const u8, req: Load) void {
        p.final_url = p.gpa.dupe(u8, dest) catch &.{};
        p.doc.url = p.final_url;
        if (std.mem.startsWith(u8, dest, "about:")) {
            p.state = .done;
            html.parseDocument(p.doc, "") catch {};
            web.parsed(p);
            return;
        }
        if (std.mem.startsWith(u8, dest, "file://")) {
            loader.readFile(p, dest);
            return;
        }
        loader.fetchDocument(p, dest, req);
    }

    /// The document's bytes came: parse them, then ask for what they name.
    pub fn documentArrived(p: *Page, status: u16, body: []const u8, final: []const u8, content_type: []const u8, err: []const u8) void {
        // Its scripts might navigate away: the page outlasts this call.
        p.busy += 1;
        defer {
            p.busy -= 1;
            p.maybeFree();
        }
        if (final.len > 0 and !std.mem.eql(u8, final, p.final_url)) {
            const hash = if (std.mem.indexOfScalar(u8, final, '#') == null)
                if (std.mem.indexOfScalar(u8, p.final_url, '#')) |i| p.final_url[i..] else ""
            else
                "";
            const copy = if (hash.len > 0)
                std.fmt.allocPrint(p.gpa, "{s}{s}", .{ final, hash }) catch p.final_url
            else
                p.gpa.dupe(u8, final) catch p.final_url;
            if (copy.ptr != p.final_url.ptr) {
                p.gpa.free(p.final_url);
                p.final_url = copy;
                p.doc.url = copy;
            }
        }
        p.state = .parsed;
        if (status == 0) {
            p.state = .failed;
            const shown = std.fmt.allocPrint(p.arena(), error_page, .{ escaped(p.arena(), p.final_url), escaped(p.arena(), err) }) catch "";
            html.parseDocument(p.doc, shown) catch {};
        } else {
            const source = documentSource(p, body, content_type) catch "";
            // Without scripts, `<noscript>` is markup to show.
            html.parseDocumentWith(p.doc, source, .{ .scripting = !p.no_scripts }) catch {};
        }
        p.title_stale = true;
        web.parsed(p);
        loader.scan(p);
        web.begin(p);
        if (p.dead) return;
        p.finishLoadCheck();
        if (p.dead) return;
        if (p.state != .done) p.host.loaded(p.host.ctx, p);
        p.redraw();
    }

    /// Everything it asked for has come.
    pub fn finishLoadCheck(p: *Page) void {
        web.loadCheck(p);
        if (p.dead) return;
        const scripts_own: u32 = if (p.js) |w| w.net_pending else 0;
        if (p.state == .parsed and p.pending <= scripts_own) {
            p.state = .done;
            p.host.loaded(p.host.ctx, p);
        }
    }
};

/// What a response's bytes are as HTML: pictures and plain text get a page.
fn documentSource(p: *Page, body: []const u8, content_type: []const u8) ![]const u8 {
    const a = p.arena();
    if (std.ascii.startsWithIgnoreCase(content_type, "image/")) {
        return std.fmt.allocPrint(a, "<!doctype html><title>{s}</title><body style=\"margin:0;display:flex;align-items:center;justify-content:center;min-height:100vh\"><img src=\"{s}\" style=\"max-width:100%;max-height:100vh\">", .{ escaped(a, p.final_url), escaped(a, p.final_url) });
    }
    if (std.ascii.startsWithIgnoreCase(content_type, "text/plain") or std.ascii.startsWithIgnoreCase(content_type, "application/json")) {
        const text = try html.toUtf8(a, body, content_type);
        return std.fmt.allocPrint(a, "<!doctype html><body><pre style=\"white-space:pre-wrap;margin:12px\">{s}</pre>", .{escaped(a, text)});
    }
    return html.toUtf8(a, body, content_type);
}

fn escaped(a: Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| switch (ch) {
        '&' => out.appendSlice(a, "&amp;") catch return "",
        '<' => out.appendSlice(a, "&lt;") catch return "",
        '>' => out.appendSlice(a, "&gt;") catch return "",
        '"' => out.appendSlice(a, "&quot;") catch return "",
        else => out.append(a, ch) catch return "",
    };
    return out.items;
}

/// Runs of whitespace as one space, none at the ends.
fn collapse(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n\x0c");
    while (it.next()) |w| {
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, w);
    }
    return out.items;
}

const error_page =
    \\<!doctype html><meta charset=utf-8><title>Can't open this page</title>
    \\<style>body{{font:15px/1.5 system-ui;color:#171717;margin:0;display:flex;align-items:center;justify-content:center;min-height:100vh}}
    \\main{{max-width:520px;padding:24px}}h1{{font-size:20px;font-weight:600;margin:0 0 8px}}p{{color:#8c8c8c;margin:0;overflow-wrap:anywhere}}
    \\@media (prefers-color-scheme:dark){{body{{color:#ededed;background:#1c1c1c}}p{{color:#949494}}}}</style>
    \\<main><h1>Can't open this page</h1><p>{s}</p><p>{s}</p></main>
;

test "titles collapse, and escapes" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("A bird", try collapse(a.allocator(), "  A \n  bird\t"));
    try std.testing.expectEqualStrings("&lt;a&amp;&quot;&gt;", escaped(a.allocator(), "<a&\">"));
}

comptime {
    _ = view_mod;
    _ = frames_mod;
}
