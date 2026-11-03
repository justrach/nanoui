//! SVG path data (`d`) and the shapes that are paths too (rect, circle,
//! ellipse, line, polyline, polygon), into a `Flattener`. Every command,
//! absolute and relative, with repeats, compact numbers (`1.5.5`, `-.4`,
//! `1e-3`) and arc flags without separators (`a1 1 0 011 1`).
const std = @import("std");
const geom = @import("svg_geom.zig");
const Point = geom.Point;
const Flattener = geom.Flattener;

pub const Scanner = struct {
    s: []const u8,
    i: usize = 0,

    fn skip(sc: *Scanner) void {
        while (sc.i < sc.s.len and (std.ascii.isWhitespace(sc.s[sc.i]) or sc.s[sc.i] == ',')) sc.i += 1;
    }

    pub fn done(sc: *Scanner) bool {
        sc.skip();
        return sc.i >= sc.s.len;
    }

    /// The next number, or null (a command letter or the end is next).
    pub fn number(sc: *Scanner) ?f32 {
        sc.skip();
        const start = sc.i;
        var i = sc.i;
        if (i < sc.s.len and (sc.s[i] == '-' or sc.s[i] == '+')) i += 1;
        var digits = false;
        while (i < sc.s.len and std.ascii.isDigit(sc.s[i])) : (i += 1) digits = true;
        if (i < sc.s.len and sc.s[i] == '.') {
            i += 1;
            while (i < sc.s.len and std.ascii.isDigit(sc.s[i])) : (i += 1) digits = true;
        }
        if (!digits) return null;
        if (i < sc.s.len and (sc.s[i] == 'e' or sc.s[i] == 'E')) {
            var j = i + 1;
            if (j < sc.s.len and (sc.s[j] == '-' or sc.s[j] == '+')) j += 1;
            if (j < sc.s.len and std.ascii.isDigit(sc.s[j])) {
                i = j;
                while (i < sc.s.len and std.ascii.isDigit(sc.s[i])) i += 1;
            }
        }
        sc.i = i;
        return std.fmt.parseFloat(f32, sc.s[start..i]) catch null;
    }

    /// An arc's flag: one character, 0 or 1.
    fn flag(sc: *Scanner) ?bool {
        sc.skip();
        if (sc.i >= sc.s.len) return null;
        const c = sc.s[sc.i];
        if (c != '0' and c != '1') return null;
        sc.i += 1;
        return c == '1';
    }

    fn point(sc: *Scanner) ?Point {
        const x = sc.number() orelse return null;
        const y = sc.number() orelse return null;
        return .{ x, y };
    }
};

/// Draws path data `d` into `f`; what can't be read ends the path there,
/// as browsers do.
pub fn path(f: *Flattener, d: []const u8) !void {
    var sc: Scanner = .{ .s = d };
    var cmd: u8 = 0;
    // The last control point, for S and T's reflection.
    var ctrl: ?Point = null;
    var last: u8 = 0;
    while (!sc.done()) {
        const c = sc.s[sc.i];
        if (std.ascii.isAlphabetic(c)) {
            cmd = c;
            sc.i += 1;
        } else if (cmd == 0 or cmd == 'z' or cmd == 'Z') return;
        const rel = std.ascii.isLower(cmd);
        const o: Point = if (rel) f.pen else .{ 0, 0 };
        const up = std.ascii.toUpper(cmd);
        switch (up) {
            'M' => {
                const p = sc.point() orelse return;
                try f.moveTo(add(o, p));
                // Pairs after a moveto are linetos.
                cmd = if (rel) 'l' else 'L';
            },
            'L' => try f.lineTo(add(o, sc.point() orelse return)),
            'H' => {
                const x = sc.number() orelse return;
                try f.lineTo(.{ if (rel) f.pen[0] + x else x, f.pen[1] });
            },
            'V' => {
                const y = sc.number() orelse return;
                try f.lineTo(.{ f.pen[0], if (rel) f.pen[1] + y else y });
            },
            'C' => {
                const c1 = add(o, sc.point() orelse return);
                const c2 = add(o, sc.point() orelse return);
                const p = add(o, sc.point() orelse return);
                try f.cubicTo(c1, c2, p);
                ctrl = c2;
            },
            'S' => {
                const c1 = if (ctrl != null and (last == 'C' or last == 'S')) reflect(ctrl.?, f.pen) else f.pen;
                const c2 = add(o, sc.point() orelse return);
                const p = add(o, sc.point() orelse return);
                try f.cubicTo(c1, c2, p);
                ctrl = c2;
            },
            'Q' => {
                const q = add(o, sc.point() orelse return);
                const p = add(o, sc.point() orelse return);
                try f.quadTo(q, p);
                ctrl = q;
            },
            'T' => {
                const q = if (ctrl != null and (last == 'Q' or last == 'T')) reflect(ctrl.?, f.pen) else f.pen;
                const p = add(o, sc.point() orelse return);
                try f.quadTo(q, p);
                ctrl = q;
            },
            'A' => {
                const rx = sc.number() orelse return;
                const ry = sc.number() orelse return;
                const rot = sc.number() orelse return;
                const large = sc.flag() orelse return;
                const sweep = sc.flag() orelse return;
                try f.arcTo(rx, ry, rot, large, sweep, add(o, sc.point() orelse return));
            },
            'Z' => f.close(),
            else => return,
        }
        last = up;
    }
}

fn add(a: Point, b: Point) Point {
    return .{ a[0] + b[0], a[1] + b[1] };
}

fn reflect(c: Point, about: Point) Point {
    return .{ 2 * about[0] - c[0], 2 * about[1] - c[1] };
}

/// `rect`: its corners rounded by `rx`, `ry` (either standing for both).
pub fn rect(f: *Flattener, x: f32, y: f32, w: f32, h: f32, rx_in: ?f32, ry_in: ?f32) !void {
    if (w <= 0 or h <= 0) return;
    const rx = @min(rx_in orelse ry_in orelse 0, w / 2);
    const ry = @min(ry_in orelse rx_in orelse 0, h / 2);
    if (rx <= 0 or ry <= 0) {
        try f.moveTo(.{ x, y });
        try f.lineTo(.{ x + w, y });
        try f.lineTo(.{ x + w, y + h });
        try f.lineTo(.{ x, y + h });
        return f.close();
    }
    try f.moveTo(.{ x + rx, y });
    try f.lineTo(.{ x + w - rx, y });
    try f.arcTo(rx, ry, 0, false, true, .{ x + w, y + ry });
    try f.lineTo(.{ x + w, y + h - ry });
    try f.arcTo(rx, ry, 0, false, true, .{ x + w - rx, y + h });
    try f.lineTo(.{ x + rx, y + h });
    try f.arcTo(rx, ry, 0, false, true, .{ x, y + h - ry });
    try f.lineTo(.{ x, y + ry });
    try f.arcTo(rx, ry, 0, false, true, .{ x + rx, y });
    f.close();
}

pub fn ellipse(f: *Flattener, cx: f32, cy: f32, rx: f32, ry: f32) !void {
    if (rx <= 0 or ry <= 0) return;
    try f.moveTo(.{ cx + rx, cy });
    try f.arcTo(rx, ry, 0, false, true, .{ cx, cy + ry });
    try f.arcTo(rx, ry, 0, false, true, .{ cx - rx, cy });
    try f.arcTo(rx, ry, 0, false, true, .{ cx, cy - ry });
    try f.arcTo(rx, ry, 0, false, true, .{ cx + rx, cy });
    f.close();
}

/// `points` of a polyline (open) or polygon (closed).
pub fn poly(f: *Flattener, points: []const u8, closed: bool) !void {
    var sc: Scanner = .{ .s = points };
    var first = true;
    while (sc.point()) |p| {
        if (first) try f.moveTo(p) else try f.lineTo(p);
        first = false;
    }
    if (closed and !first) f.close();
}

const testing = std.testing;

test "compact numbers, relative commands, repeats and smooth curves" {
    var sc: Scanner = .{ .s = "1.5.5-.4 1e-1,2E+1" };
    try testing.expectEqual(@as(?f32, 1.5), sc.number());
    try testing.expectEqual(@as(?f32, 0.5), sc.number());
    try testing.expectEqual(@as(?f32, -0.4), sc.number());
    try testing.expectApproxEqAbs(@as(f32, 0.1), sc.number().?, 1e-6);
    try testing.expectEqual(@as(?f32, 20), sc.number());
    try testing.expect(sc.number() == null);

    var f: Flattener = .{ .gpa = testing.allocator };
    defer f.deinit();
    // A relative moveto's extra pairs are relative linetos; H and V; Z.
    try path(&f, "m2 2 3 0 0 3h-3z M10 10 v2");
    try testing.expectEqual(@as(usize, 2), f.subpaths.items.len);
    try testing.expect(f.subpaths.items[0].closed);
    const a = f.of(f.subpaths.items[0]);
    try testing.expectEqual(Point{ 5, 2 }, a[1]);
    try testing.expectEqual(Point{ 5, 5 }, a[2]);
    try testing.expectEqual(Point{ 2, 5 }, a[3]);
    try testing.expectEqual(Point{ 10, 12 }, f.of(f.subpaths.items[1])[1]);
    // Arc flags packed with the numbers after them.
    f.clear();
    try path(&f, "M0 0a1 1 0 012 0");
    const arc = f.of(f.subpaths.items[0]);
    try testing.expectEqual(Point{ 2, 0 }, arc[arc.len - 1]);
    // S reflects the previous control point.
    f.clear();
    try path(&f, "M0 0C0 4 4 4 4 0S8-4 8 0");
    const s = f.of(f.subpaths.items[0]);
    try testing.expectEqual(Point{ 8, 0 }, s[s.len - 1]);
    var lowest: f32 = 0;
    for (s) |q| lowest = @min(lowest, q[1]);
    try testing.expect(lowest < -2);
}

test "a rounded rect and a polygon close" {
    var f: Flattener = .{ .gpa = testing.allocator };
    defer f.deinit();
    try rect(&f, 0, 0, 10, 6, 2, null);
    try testing.expect(f.subpaths.items[0].closed);
    try poly(&f, "0,0 4,0 4,4", true);
    try testing.expectEqual(@as(usize, 3), f.subpaths.items[1].len);
}
