//! Which file a picture shows: `<picture>`'s `<source>`s by `media` and `type`,
//! `srcset`'s candidates by density (`x`, or `w` against `sizes`), as Blink
//! chooses them, then `src`; and the `data-src` of lazy loaders, when nothing
//! else is there to show.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const dom = @import("../dom.zig");
const media = @import("../css/media.zig");
const Allocator = std.mem.Allocator;

pub const Choice = struct {
    url: []const u8,
    /// File pixels to the CSS pixel: its natural size is its pixels over this.
    density: f32 = 1,
};

pub const Env = struct {
    /// Pixels a point on this screen.
    scale: f32,
    viewport: media.Viewport,
};

/// Whether a window or screen could change what this `<img>` shows.
pub fn mayChange(n: *const dom.Node) bool {
    if (n.hasAttr("srcset")) return true;
    const p = n.parent orelse return false;
    return p.isTag("picture");
}

/// What `img` shows here; null if it names nothing.
pub fn choose(img: *const dom.Node, env: Env, a: Allocator) ?Choice {
    if (img.parent) |p| if (p.isTag("picture")) {
        var at = p.first_child;
        while (at) |s| : (at = s.next) {
            if (s == img) break;
            if (!s.isTag("source")) continue;
            if (fromSource(s, env, a)) |c| return c;
        }
    };
    if (img.attr("srcset") orelse img.attr("data-srcset")) |set| {
        if (best(set, img.attr("sizes"), img.attr("src"), env, a)) |c| return c;
    }
    if (img.attr("src")) |s| if (s.len > 0) return .{ .url = s };
    for ([_][]const u8{ "data-src", "data-lazy-src", "data-original" }) |name| {
        if (img.attr(name)) |s| if (s.len > 0) return .{ .url = s };
    }
    return null;
}

fn fromSource(s: *const dom.Node, env: Env, a: Allocator) ?Choice {
    const set = s.attr("srcset") orelse return null;
    if (s.attr("media")) |m| {
        const list = media.parseText(a, m) catch return null;
        if (!list.matches(env.viewport)) return null;
    }
    if (s.attr("type")) |t| if (!ui.imageTypeDecodes(t)) return null;
    return best(set, s.attr("sizes"), null, env, a);
}

const Candidate = struct { url: []const u8, density: f32 };

/// The candidate for this screen. A plain `src` stands for 1x if no other does.
fn best(set: []const u8, sizes: ?[]const u8, src: ?[]const u8, env: Env, a: Allocator) ?Choice {
    var list: std.ArrayList(Candidate) = .empty;
    const size = sourceSize(sizes, env, a);
    parseSet(set, size, a, &list) catch return null;
    if (src) |s| if (s.len > 0) {
        var has_one = false;
        for (list.items) |c| if (c.density == 1) {
            has_one = true;
        };
        if (!has_one) list.append(a, .{ .url = s, .density = 1 }) catch {};
    };
    if (list.items.len == 0) return null;
    std.mem.sort(Candidate, list.items, {}, struct {
        fn lt(_: void, x: Candidate, y: Candidate) bool {
            return x.density < y.density;
        }
    }.lt);
    const c = select(list.items, env.scale);
    return .{ .url = c.url, .density = c.density };
}

/// Blink's rule, sorted by density: a candidate is taken once the next is more
/// than the geometric mean's worth too large, or (on a low density screen) once
/// it covers the screen. So a slightly short candidate can beat a much larger one.
fn select(sorted: []const Candidate, scale: f32) Candidate {
    for (sorted, 0..) |c, i| {
        if (i + 1 >= sorted.len) return c;
        const next = sorted[i + 1].density;
        if (next < 0) return c;
        const mean = @sqrt(c.density * next);
        if ((scale <= 1 and scale <= c.density) or (scale > 1 and mean >= scale)) return c;
    }
    return sorted[sorted.len - 1];
}

/// The spec's split: a URL runs to whitespace, so commas may be inside it; a
/// trailing comma ends a candidate; descriptors run to a comma out of parens.
fn parseSet(set: []const u8, size: f32, a: Allocator, out: *std.ArrayList(Candidate)) !void {
    var i: usize = 0;
    while (i < set.len) {
        while (i < set.len and (std.ascii.isWhitespace(set[i]) or set[i] == ',')) i += 1;
        if (i >= set.len) return;
        const start = i;
        while (i < set.len and !std.ascii.isWhitespace(set[i])) i += 1;
        var url = set[start..i];
        var density: f32 = 1;
        if (url[url.len - 1] == ',') {
            url = std.mem.trimEnd(u8, url, ",");
        } else {
            const d_start = i;
            var depth: u32 = 0;
            while (i < set.len and !(set[i] == ',' and depth == 0)) : (i += 1) {
                if (set[i] == '(') depth += 1;
                if (set[i] == ')' and depth > 0) depth -= 1;
            }
            if (!descriptor(set[d_start..i], size, &density)) continue;
            if (i < set.len) i += 1;
        }
        if (url.len == 0) continue;
        try out.append(a, .{ .url = url, .density = density });
    }
}

/// False for a candidate the spec throws away.
fn descriptor(text: []const u8, size: f32, density: *f32) bool {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n\x0c");
    while (it.next()) |w| {
        const unit = w[w.len - 1];
        const n = std.fmt.parseFloat(f32, w[0 .. w.len - 1]) catch return false;
        if (!(n > 0)) return false;
        switch (unit) {
            'x' => density.* = n,
            'w' => density.* = n / @max(size, 1),
            'h' => {},
            else => return false,
        }
    }
    return true;
}

/// `sizes`: the first entry whose media condition holds; 100vw without one.
fn sourceSize(sizes: ?[]const u8, env: Env, a: Allocator) f32 {
    const vw = env.viewport.width;
    const text = sizes orelse return vw;
    var i: usize = 0;
    var depth: u32 = 0;
    var start: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or (text[i] == ',' and depth == 0)) {
            if (entry(text[start..i], env, a)) |px| return px;
            start = i + 1;
        } else if (text[i] == '(') {
            depth += 1;
        } else if (text[i] == ')' and depth > 0) {
            depth -= 1;
        }
    }
    return vw;
}

fn entry(raw: []const u8, env: Env, a: Allocator) ?f32 {
    const t = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (t.len == 0) return null;
    // The length is the entry's end: one word, or one function call.
    var at = t.len;
    if (t[t.len - 1] == ')') {
        var depth: u32 = 0;
        while (at > 0) {
            at -= 1;
            if (t[at] == ')') depth += 1;
            if (t[at] == '(') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        while (at > 0 and std.ascii.isAlphabetic(t[at - 1])) at -= 1;
    } else {
        while (at > 0 and !std.ascii.isWhitespace(t[at - 1])) at -= 1;
    }
    const cond = std.mem.trim(u8, t[0..at], " \t\r\n\x0c");
    if (cond.len > 0) {
        const list = media.parseText(a, cond) catch return null;
        if (!list.matches(env.viewport)) return null;
    }
    const length = t[at..];
    // `sizes=auto`: as much as there is, nearer to being right than nothing.
    if (std.ascii.eqlIgnoreCase(length, "auto")) return env.viewport.width;
    var ev: Eval = .{ .s = length, .env = env };
    const v = ev.sum() orelse return null;
    return if (v >= 0) v else null;
}

/// Lengths and `calc()` over them: `100vw`, `calc(50vw - 2rem)`, `min(...)`.
const Eval = struct {
    s: []const u8,
    i: usize = 0,
    env: Env,

    fn ws(e: *Eval) void {
        while (e.i < e.s.len and std.ascii.isWhitespace(e.s[e.i])) e.i += 1;
    }

    fn sum(e: *Eval) ?f32 {
        var v = e.product() orelse return null;
        while (true) {
            e.ws();
            if (e.i >= e.s.len) return v;
            const c = e.s[e.i];
            if (c != '+' and c != '-') return v;
            e.i += 1;
            const r = e.product() orelse return null;
            v = if (c == '+') v + r else v - r;
        }
    }

    fn product(e: *Eval) ?f32 {
        var v = e.value() orelse return null;
        while (true) {
            e.ws();
            if (e.i >= e.s.len) return v;
            const c = e.s[e.i];
            if (c != '*' and c != '/') return v;
            e.i += 1;
            const r = e.value() orelse return null;
            v = if (c == '*') v * r else if (r != 0) v / r else return null;
        }
    }

    fn value(e: *Eval) ?f32 {
        e.ws();
        if (e.i >= e.s.len) return null;
        if (std.ascii.isAlphabetic(e.s[e.i])) return e.function();
        if (e.s[e.i] == '(') {
            e.i += 1;
            const v = e.sum();
            e.ws();
            if (e.i < e.s.len and e.s[e.i] == ')') e.i += 1;
            return v;
        }
        const start = e.i;
        if (e.s[e.i] == '-' or e.s[e.i] == '+') e.i += 1;
        while (e.i < e.s.len and (std.ascii.isDigit(e.s[e.i]) or e.s[e.i] == '.')) e.i += 1;
        const n = std.fmt.parseFloat(f32, e.s[start..e.i]) catch return null;
        const u_start = e.i;
        while (e.i < e.s.len and (std.ascii.isAlphabetic(e.s[e.i]) or e.s[e.i] == '%')) e.i += 1;
        return e.unit(n, e.s[u_start..e.i]);
    }

    fn function(e: *Eval) ?f32 {
        const start = e.i;
        while (e.i < e.s.len and std.ascii.isAlphabetic(e.s[e.i])) e.i += 1;
        const name = e.s[start..e.i];
        if (e.i >= e.s.len or e.s[e.i] != '(') return null;
        e.i += 1;
        const eq = std.ascii.eqlIgnoreCase;
        var v = e.sum() orelse return null;
        while (true) {
            e.ws();
            if (e.i >= e.s.len) return null;
            if (e.s[e.i] == ')') {
                e.i += 1;
                return v;
            }
            if (e.s[e.i] != ',') return null;
            e.i += 1;
            const r = e.sum() orelse return null;
            if (eq(name, "min")) v = @min(v, r) else if (eq(name, "max")) v = @max(v, r) else return null;
        }
    }

    fn unit(e: *const Eval, n: f32, u: []const u8) ?f32 {
        const eq = std.ascii.eqlIgnoreCase;
        const w = e.env.viewport.width;
        const h = e.env.viewport.height;
        if (u.len == 0 or eq(u, "px")) return n;
        if (eq(u, "vw") or eq(u, "dvw") or eq(u, "svw") or eq(u, "lvw")) return n * w / 100;
        if (eq(u, "vh") or eq(u, "dvh") or eq(u, "svh") or eq(u, "lvh")) return n * h / 100;
        if (eq(u, "vmin")) return n * @min(w, h) / 100;
        if (eq(u, "vmax")) return n * @max(w, h) / 100;
        if (eq(u, "em") or eq(u, "rem")) return n * 16;
        if (eq(u, "pt")) return n * 4 / 3;
        return null;
    }
};

const testing = std.testing;

fn pick(set: []const u8, sizes: ?[]const u8, scale: f32, vw: f32) !Choice {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const c = best(set, sizes, null, .{ .scale = scale, .viewport = .{ .width = vw, .height = 800 } }, arena.allocator()) orelse return error.TestFailed;
    arena.deinit();
    return c;
}

test "x descriptors go by the screen" {
    try testing.expectEqualStrings("b.png", (try pick("a.png 1x, b.png 2x, c.png 3x", null, 2, 1000)).url);
    try testing.expectEqualStrings("a.png", (try pick("a.png 1x, b.png 2x", null, 1, 1000)).url);
    try testing.expectEqual(@as(f32, 2), (try pick("b.png 2x", null, 1, 1000)).density);
    // Between two, the nearer by the geometric mean.
    try testing.expectEqualStrings("b.png", (try pick("a.png 1x, b.png 2x, c.png 3x", null, 2.4, 1000)).url);
}

test "w descriptors go by sizes and the screen" {
    const set = "s.png 320w, m.png 640w, l.png 1280w, x.png 2560w";
    // 100vw of 1280 on a 2x screen wants 2560 pixels.
    const wide = try pick(set, null, 2, 1280);
    try testing.expectEqualStrings("x.png", wide.url);
    try testing.expectEqual(@as(f32, 2), wide.density);
    // 320 CSS pixels on 2x wants 640.
    try testing.expectEqualStrings("m.png", (try pick(set, "(max-width: 600px) 100vw, 320px", 2, 1280)).url);
    // The first size whose condition holds.
    try testing.expectEqualStrings("m.png", (try pick(set, "(max-width: 600px) 100vw, 320px", 2, 320)).url);
    try testing.expectEqualStrings("l.png", (try pick(set, "(min-width: 600px) calc(50vw - 0px), 100vw", 2, 1280)).url);
    try testing.expectEqualStrings("s.png", (try pick(set, "min(320px, 90vw)", 1, 1280)).url);
}

test "commas in an address, a stray comma, and candidates to throw away" {
    const c = try pick("https://x.test/w_100,h_100/a.png 1x, b.png 2x", null, 1, 800);
    try testing.expectEqualStrings("https://x.test/w_100,h_100/a.png", c.url);
    try testing.expectEqualStrings("b.png", (try pick("a.png 0x, b.png, ,", null, 1, 800)).url);
    try testing.expectEqualStrings("data:image/png;base64,AA==", (try pick("data:image/png;base64,AA== 1x", null, 1, 800)).url);
}
