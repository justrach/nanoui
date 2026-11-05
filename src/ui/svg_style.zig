//! What an SVG element draws with: presentation attributes, `style="…"` and
//! a document's own sheet read into a `Style`, which children inherit.
//! Colors are in `svg_colors.zig`.
const std = @import("std");
const geom = @import("svg_geom.zig");
const raster = @import("svg_raster.zig");
const colors = @import("svg_colors.zig");
const Tag = @import("svg_tags.zig").Tag;
const Transform = geom.Transform;

pub const max_dashes = 16;

/// What a paint falls to when its `url(#…)` names nothing it can use.
pub const Fallback = union(enum) { none, current, color: [4]f32 };

pub const Paint = union(enum) {
    none,
    current,
    color: [4]f32,
    url: struct { id: []const u8, fallback: Fallback = .none },
};

pub const Style = struct {
    // Inherited.
    fill: Paint = .{ .color = .{ 0, 0, 0, 1 } },
    stroke: Paint = .none,
    stroke_width: f32 = 1,
    cap: raster.Cap = .butt,
    join: raster.Join = .miter,
    miter_limit: f32 = 4,
    rule: raster.Rule = .nonzero,
    clip_rule: raster.Rule = .nonzero,
    fill_opacity: f32 = 1,
    stroke_opacity: f32 = 1,
    dash: [max_dashes]f32 = undefined,
    dash_n: u8 = 0,
    dash_offset: f32 = 0,
    /// `currentColor`.
    color: [4]f32 = .{ 0, 0, 0, 1 },
    visible: bool = true,
    stroke_first: bool = false,
    non_scaling_stroke: bool = false,
    /// User space to pixels.
    t: Transform = .{},
    /// What percentages are of, in user units.
    vp: [2]f32 = .{ 0, 0 },
    /// A nested viewport's clip in pixels, while it is axis-aligned.
    clip_rect: ?[4]f32 = null,
    // The element's own.
    opacity: f32 = 1,
    clip: ?[]const u8 = null,
    mask: ?[]const u8 = null,
    hidden: bool = false,

    /// What `child` starts from.
    pub fn inherit(p: *const Style) Style {
        var s = p.*;
        s.opacity = 1;
        s.clip = null;
        s.mask = null;
        s.hidden = false;
        return s;
    }

    pub fn wantsLayer(s: *const Style) bool {
        return s.opacity < 0.999 or s.clip != null or s.mask != null;
    }
};

/// A document's `<style>`: enough for what drawing programs write
/// (`.cls-1{fill:#fff}`, lists, compounds); of a longer selector, its last
/// compound decides.
pub const Sheet = struct {
    rules: std.ArrayList(Rule) = .empty,

    const Rule = struct { selectors: []const u8, decls: []const u8 };

    pub fn deinit(s: *Sheet, gpa: std.mem.Allocator) void {
        s.rules.deinit(gpa);
    }

    pub fn parse(s: *Sheet, gpa: std.mem.Allocator, text_in: []const u8) !void {
        var text = text_in;
        while (std.mem.indexOf(u8, text, "/*")) |at| {
            // A comment ends what's read of this piece: rare, and harmless to
            // read around.
            const end = std.mem.indexOfPos(u8, text, at, "*/") orelse return;
            try s.parseSome(gpa, text[0..at]);
            text = text[end + 2 ..];
        }
        try s.parseSome(gpa, text);
    }

    fn parseSome(s: *Sheet, gpa: std.mem.Allocator, text: []const u8) !void {
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, i, '{')) |open| {
            const close = std.mem.indexOfScalarPos(u8, text, open, '}') orelse return;
            const sel = std.mem.trim(u8, text[i..open], " \t\r\n");
            i = close + 1;
            if (sel.len == 0) continue;
            if (sel[0] == '@') {
                // An at-rule's block holds rules of its own: passed over.
                if (std.mem.indexOfScalarPos(u8, text, open + 1, '{')) |inner| if (inner < close) {
                    var depth: usize = 2;
                    var j = inner + 1;
                    while (j < text.len and depth > 0) : (j += 1) {
                        if (text[j] == '{') depth += 1;
                        if (text[j] == '}') depth -= 1;
                    }
                    i = j;
                };
                continue;
            }
            try s.rules.append(gpa, .{ .selectors = sel, .decls = text[open + 1 .. close] });
        }
    }

    pub fn selects(selectors: []const u8, tag: Tag) bool {
        var list = std.mem.splitScalar(u8, selectors, ',');
        while (list.next()) |one| {
            const t = std.mem.trim(u8, one, " \t\r\n");
            const start = if (std.mem.lastIndexOfAny(u8, t, " >+~\t\r\n")) |x| x + 1 else 0;
            if (compoundMatches(t[start..], tag)) return true;
        }
        return false;
    }

    fn compoundMatches(c: []const u8, tag: Tag) bool {
        if (c.len == 0) return false;
        var i: usize = 0;
        while (i < c.len) {
            const kind = c[i];
            const part_start = if (kind == '.' or kind == '#') i + 1 else i;
            var j = part_start;
            while (j < c.len and c[j] != '.' and c[j] != '#' and c[j] != '[' and c[j] != ':') j += 1;
            const word = c[part_start..j];
            switch (kind) {
                '.' => if (!hasClass(tag, word)) return false,
                '#' => if (!std.mem.eql(u8, tag.attr("id") orelse "", word)) return false,
                '[', ':' => return false,
                '*' => {},
                else => if (!std.ascii.eqlIgnoreCase(word, tag.name)) return false,
            }
            i = j;
            if (i == part_start and word.len == 0 and kind != '.' and kind != '#') return false;
        }
        return true;
    }

    fn hasClass(tag: Tag, word: []const u8) bool {
        var it = std.mem.tokenizeAny(u8, tag.attr("class") orelse return false, " \t\r\n");
        while (it.next()) |w| if (std.mem.eql(u8, w, word)) return true;
        return false;
    }
};

/// The element's attributes, then its sheet's rules, then its `style`.
pub fn apply(st: *Style, tag: Tag, sheet: ?*const Sheet) void {
    var it = tag.attrs();
    while (it.next()) |a| property(st, a.name, a.value);
    if (sheet) |sh| for (sh.rules.items) |r| if (Sheet.selects(r.selectors, tag)) declarations(st, r.decls);
    if (tag.attr("style")) |css| declarations(st, css);
}

pub fn declarations(st: *Style, css: []const u8) void {
    var decls = std.mem.splitScalar(u8, css, ';');
    while (decls.next()) |d| {
        const colon = std.mem.indexOfScalar(u8, d, ':') orelse continue;
        var v = std.mem.trim(u8, d[colon + 1 ..], " \t\r\n");
        if (std.mem.indexOfScalar(u8, v, '!')) |bang| v = std.mem.trimEnd(u8, v[0..bang], " \t\r\n");
        property(st, std.mem.trim(u8, d[0..colon], " \t\r\n"), v);
    }
}

fn property(st: *Style, name: []const u8, v: []const u8) void {
    const eq = std.mem.eql;
    if (eq(u8, name, "fill")) {
        if (parsePaint(v)) |p| st.fill = p;
    } else if (eq(u8, name, "stroke")) {
        if (parsePaint(v)) |p| st.stroke = p;
    } else if (eq(u8, name, "color")) {
        if (colors.parse(v)) |c| st.color = c;
    } else if (eq(u8, name, "stroke-width")) {
        if (length(v, st.vp[0])) |x| st.stroke_width = x;
    } else if (eq(u8, name, "stroke-linecap")) {
        st.cap = std.meta.stringToEnum(raster.Cap, v) orelse st.cap;
    } else if (eq(u8, name, "stroke-linejoin")) {
        st.join = if (eq(u8, v, "miter-clip") or eq(u8, v, "arcs")) .miter else std.meta.stringToEnum(raster.Join, v) orelse st.join;
    } else if (eq(u8, name, "stroke-miterlimit")) {
        if (length(v, 0)) |x| st.miter_limit = @max(1, x);
    } else if (eq(u8, name, "stroke-dasharray")) {
        dashes(st, v);
    } else if (eq(u8, name, "stroke-dashoffset")) {
        if (length(v, st.vp[0])) |x| st.dash_offset = x;
    } else if (eq(u8, name, "fill-rule")) {
        st.rule = std.meta.stringToEnum(raster.Rule, v) orelse st.rule;
    } else if (eq(u8, name, "clip-rule")) {
        st.clip_rule = std.meta.stringToEnum(raster.Rule, v) orelse st.clip_rule;
    } else if (eq(u8, name, "opacity")) {
        if (unit(v)) |x| st.opacity = x;
    } else if (eq(u8, name, "fill-opacity")) {
        if (unit(v)) |x| st.fill_opacity = x;
    } else if (eq(u8, name, "stroke-opacity")) {
        if (unit(v)) |x| st.stroke_opacity = x;
    } else if (eq(u8, name, "transform")) {
        st.t = transform(v).then(st.t);
    } else if (eq(u8, name, "display")) {
        st.hidden = eq(u8, v, "none");
    } else if (eq(u8, name, "visibility")) {
        st.visible = !(eq(u8, v, "hidden") or eq(u8, v, "collapse"));
    } else if (eq(u8, name, "clip-path")) {
        st.clip = urlId(v);
    } else if (eq(u8, name, "mask")) {
        st.mask = urlId(v);
    } else if (eq(u8, name, "paint-order")) {
        st.stroke_first = std.mem.startsWith(u8, std.mem.trim(u8, v, " "), "stroke");
    } else if (eq(u8, name, "vector-effect")) {
        st.non_scaling_stroke = eq(u8, v, "non-scaling-stroke");
    }
}

fn dashes(st: *Style, v: []const u8) void {
    st.dash_n = 0;
    if (std.mem.eql(u8, v, "none")) return;
    var it = std.mem.tokenizeAny(u8, v, " ,\t\r\n");
    while (it.next()) |w| {
        if (st.dash_n == max_dashes) break;
        const x = length(w, st.vp[0]) orelse {
            st.dash_n = 0;
            return;
        };
        if (x < 0) {
            st.dash_n = 0;
            return;
        }
        st.dash[st.dash_n] = x;
        st.dash_n += 1;
    }
}

fn unit(v: []const u8) ?f32 {
    const t = std.mem.trim(u8, v, " \t\r\n");
    if (std.mem.endsWith(u8, t, "%")) {
        const n = std.fmt.parseFloat(f32, t[0 .. t.len - 1]) catch return null;
        return std.math.clamp(n / 100, 0, 1);
    }
    const n = std.fmt.parseFloat(f32, t) catch return null;
    return std.math.clamp(n, 0, 1);
}

/// A length in user units: `%` of `ref`, `em` of the usual 16.
pub fn length(s: []const u8, ref: f32) ?f32 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return null;
    var end: usize = 0;
    if (t[0] == '-' or t[0] == '+') end = 1;
    var digits = false;
    while (end < t.len and (std.ascii.isDigit(t[end]) or t[end] == '.')) : (end += 1) {
        if (t[end] != '.') digits = true;
    }
    if (!digits) return null;
    if (end < t.len and (t[end] == 'e' or t[end] == 'E') and end + 1 < t.len and (std.ascii.isDigit(t[end + 1]) or t[end + 1] == '-' or t[end + 1] == '+')) {
        end += 2;
        while (end < t.len and std.ascii.isDigit(t[end])) end += 1;
    }
    const n = std.fmt.parseFloat(f32, t[0..end]) catch return null;
    const u = t[end..];
    const eq = std.ascii.eqlIgnoreCase;
    if (u.len == 0 or eq(u, "px")) return n;
    if (eq(u, "%")) return n * ref / 100;
    if (eq(u, "em") or eq(u, "rem")) return n * 16;
    if (eq(u, "ex")) return n * 8;
    if (eq(u, "pt")) return n * 4.0 / 3.0;
    if (eq(u, "pc")) return n * 16;
    if (eq(u, "in")) return n * 96;
    if (eq(u, "cm")) return n * 96 / 2.54;
    if (eq(u, "mm")) return n * 96 / 25.4;
    return n;
}

/// The number at the start of `s[i..]`, its unit skipped; a function's
/// arguments are read with it, in attributes (`rotate(45)`) and CSS alike
/// (`rotate(45deg)`, `translate(1px, 2px)`).
fn arg(s: []const u8, i: *usize) ?f32 {
    while (i.* < s.len and (std.ascii.isWhitespace(s[i.*]) or s[i.*] == ',')) i.* += 1;
    const start = i.*;
    var j = start;
    if (j < s.len and (s[j] == '-' or s[j] == '+')) j += 1;
    while (j < s.len and (std.ascii.isDigit(s[j]) or s[j] == '.')) j += 1;
    if (j < s.len and (s[j] == 'e' or s[j] == 'E') and j + 1 < s.len and (std.ascii.isDigit(s[j + 1]) or s[j + 1] == '-')) {
        j += 2;
        while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
    }
    if (j == start) return null;
    const n = std.fmt.parseFloat(f32, s[start..j]) catch return null;
    while (j < s.len and (std.ascii.isAlphabetic(s[j]) or s[j] == '%')) j += 1;
    i.* = j;
    return n;
}

/// `translate`, `scale`, `rotate`, `skewX`, `skewY` and `matrix`, in order,
/// with CSS's axis forms too.
pub fn transform(s: []const u8) Transform {
    var t: Transform = .{};
    var rest = s;
    while (std.mem.indexOfScalar(u8, rest, '(')) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open, ')') orelse break;
        const name = std.mem.trim(u8, rest[0..open], " \t\r\n,");
        const body = rest[open + 1 .. close];
        var i: usize = 0;
        var a: [6]f32 = undefined;
        var n: usize = 0;
        while (n < 6) : (n += 1) a[n] = arg(body, &i) orelse break;
        const eq = std.mem.eql;
        const m: Transform = if (eq(u8, name, "translate") and n >= 1)
            .translate(a[0], if (n > 1) a[1] else 0)
        else if (eq(u8, name, "translateX") and n >= 1)
            .translate(a[0], 0)
        else if (eq(u8, name, "translateY") and n >= 1)
            .translate(0, a[0])
        else if (eq(u8, name, "scale") and n >= 1)
            .scale(a[0], if (n > 1) a[1] else a[0])
        else if (eq(u8, name, "scaleX") and n >= 1)
            .scale(a[0], 1)
        else if (eq(u8, name, "scaleY") and n >= 1)
            .scale(1, a[0])
        else if (eq(u8, name, "rotate") and n >= 1)
            (if (n >= 3) Transform.translate(-a[1], -a[2]).then(.rotate(a[0])).then(.translate(a[1], a[2])) else Transform.rotate(a[0]))
        else if (eq(u8, name, "skewX") and n >= 1)
            .{ .m = .{ 1, 0, @tan(a[0] * std.math.pi / 180), 1, 0, 0 } }
        else if (eq(u8, name, "skewY") and n >= 1)
            .{ .m = .{ 1, @tan(a[0] * std.math.pi / 180), 0, 1, 0, 0 } }
        else if (eq(u8, name, "matrix") and n == 6)
            .{ .m = a }
        else
            .{};
        // Each applies before those to its left.
        t = m.then(t);
        rest = rest[close + 1 ..];
    }
    return t;
}

/// `#a` of `url(#a)`, `url("#a")` or a whole address ending in it.
pub fn urlId(v_in: []const u8) ?[]const u8 {
    const v = std.mem.trim(u8, v_in, " \t\r\n");
    if (!std.mem.startsWith(u8, v, "url(")) return null;
    const close = std.mem.indexOfScalar(u8, v, ')') orelse return null;
    const hash = std.mem.lastIndexOfScalar(u8, v[0..close], '#') orelse return null;
    return std.mem.trim(u8, v[hash + 1 .. close], " \"'");
}

/// A custom property's fallback stands for it.
fn orFallback(v_in: []const u8) ?[]const u8 {
    const v = std.mem.trim(u8, v_in, " \t\r\n");
    if (!std.mem.startsWith(u8, v, "var(")) return v;
    const comma = std.mem.indexOfScalar(u8, v, ',') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, v, ')') orelse return null;
    if (close < comma) return null;
    return std.mem.trim(u8, v[comma + 1 .. close], " \t\r\n");
}

pub fn parsePaint(v_in: []const u8) ?Paint {
    const v = orFallback(v_in) orelse return null;
    if (std.mem.eql(u8, v, "none") or std.mem.eql(u8, v, "transparent")) return .none;
    if (std.mem.startsWith(u8, v, "url(")) {
        const id = urlId(v) orelse return .none;
        const close = std.mem.indexOfScalar(u8, v, ')') orelse return .none;
        const after = std.mem.trim(u8, v[close + 1 ..], " \t\r\n");
        var fallback: Fallback = .none;
        if (std.ascii.eqlIgnoreCase(after, "currentColor")) {
            fallback = .current;
        } else if (colors.parse(after)) |c| fallback = .{ .color = c };
        return .{ .url = .{ .id = id, .fallback = fallback } };
    }
    if (std.ascii.eqlIgnoreCase(v, "currentColor")) return .current;
    return if (colors.parse(v)) |c| .{ .color = c } else null;
}

test "a sheet's rules: classes, lists, compounds, and what's passed over" {
    const gpa = std.testing.allocator;
    var sh: Sheet = .{};
    defer sh.deinit(gpa);
    try sh.parse(gpa, "/* x */ .a,.b{fill:#ff0000} path.c { stroke: #00ff00 } @media print { .a { fill: blue } } g .d{fill:#0000ff !important}");
    try std.testing.expectEqual(@as(usize, 3), sh.rules.items.len);
    var it: @import("svg_tags.zig").Tags = .{ .s = "<path class='b c'/><rect class='d'/>" };
    var st: Style = .{};
    apply(&st, it.next().?, &sh);
    try std.testing.expectEqual(@as(f32, 1), st.fill.color[0]);
    try std.testing.expectEqual(@as(f32, 1), st.stroke.color[1]);
    var st2: Style = .{};
    apply(&st2, it.next().?, &sh);
    try std.testing.expectEqual(@as(f32, 1), st2.fill.color[2]);
}

test "transforms in attributes and in CSS's words" {
    const t = transform("translate(10px, 5px) rotate(90deg)");
    const p = t.apply(.{ 1, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 10), p[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 6), p[1], 1e-4);
    try std.testing.expectEqualStrings("g", urlId("url(\"https://x.test/a#g\")").?);
    try std.testing.expectEqual(@as(?f32, 32), length("2em", 0));
    try std.testing.expectEqual(@as(?f32, 12), length("50%", 24));
}
