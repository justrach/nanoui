//! A map: on iOS a MapKit view under the UI, seen through a hole cut in
//! the frame (`ui.hole`), so cards, chips and glass draw over it. Pins are
//! labeled chips (a stop's code, a bus's service), a polyline draws a
//! route, the camera glides to where it's told, and the device's own dot
//! shows when location is allowed. Elsewhere it draws a placeholder.
//!
//! The app keeps the `Map` in its state (it must not move) and says what
//! it shows every frame; only what changed reaches MapKit:
//!
//!     s.map.view(c, .{ .pins = s.pins(), .camera = .{ .center = stop } });
//!     if (s.map.takeTap()) |id| s.select(id);
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("../ui/ui.zig");
const ios = builtin.os.tag == .ios;
const native = if (ios) @import("../ios/map.zig") else struct {
    pub const Native = struct {
        pub fn deinit(_: *@This()) void {}
    };
};

pub const Coord = struct { lat: f64, lng: f64 };

pub const PinStyle = enum {
    /// A yellow chip with a bus stop's code.
    stop,
    /// A dark pill with a bus's service number.
    bus,
};

pub const Pin = struct {
    /// Stable across frames: a pin whose `at` changes glides there.
    id: u64,
    at: Coord,
    /// Up to 15 bytes.
    label: []const u8,
    style: PinStyle = .stop,
    selected: bool = false,
};

pub const Line = struct {
    points: []const Coord,
    color: ui.Color = .hex(0x1A73E8),
    width: f32 = 5,
    /// Dotted, as a walk is drawn.
    dashed: bool = false,
};

/// One line as the map keeps it: a run of `Map.line`'s points.
pub const Seg = struct { start: u32, len: u32, color: ui.Color, width: f32, dashed: bool };

pub const Camera = struct {
    center: Coord,
    /// Degrees of latitude shown top to bottom.
    span: f64 = 0.008,
    animated: bool = true,
};

pub const Options = struct {
    pins: []const Pin = &.{},
    line: ?Line = null,
    /// More lines, drawn over `line` in order (a trip's walks and rides).
    lines: []const Line = &.{},
    /// Moves the camera when it differs from the last one given.
    camera: ?Camera = null,
    /// The device's location dot (asks nothing: start `location` for it).
    user: bool = false,
    /// MapKit's muted style, without points of interest.
    muted: bool = true,
    radius: f32 = 0,
    key: []const u8 = "map",
};

/// A pin as the map keeps it: its label copied.
pub const Want = struct {
    id: u64,
    at: Coord,
    label_buf: [15]u8 = undefined,
    label_len: u8 = 0,
    style: PinStyle,
    selected: bool,

    pub fn label(w: *const Want) []const u8 {
        return w.label_buf[0..w.label_len];
    }

    pub fn same(a: Want, b: Want) bool {
        return a.style == b.style and a.selected == b.selected and std.mem.eql(u8, a.label(), b.label());
    }
};

pub const Map = struct {
    gpa: std.mem.Allocator,
    /// What the last frame asked for.
    pins: std.ArrayList(Want) = .empty,
    /// Every line's points, one after another, and the runs that are lines.
    line: std.ArrayList(Coord) = .empty,
    segs: std.ArrayList(Seg) = .empty,
    camera: ?Camera = null,
    user: bool = false,
    muted: bool = true,
    radius: f32 = 0,
    /// The hole's box id this frame, and whether it was drawn.
    id: u64 = 0,
    seen: bool = false,
    /// A pin the user tapped, until `takeTap`.
    tapped: ?u64 = null,
    native: native.Native = .{},

    pub fn init(gpa: std.mem.Allocator) Map {
        return .{ .gpa = gpa };
    }

    pub fn deinit(m: *Map) void {
        m.native.deinit();
        m.pins.deinit(m.gpa);
        m.line.deinit(m.gpa);
        m.segs.deinit(m.gpa);
    }

    /// The map, filling the box it's in.
    pub fn view(m: *Map, c: *ui.Context, opts: Options) void {
        m.pins.clearRetainingCapacity();
        for (opts.pins) |p| {
            var w: Want = .{ .id = p.id, .at = p.at, .style = p.style, .selected = p.selected };
            const n = @min(p.label.len, w.label_buf.len);
            @memcpy(w.label_buf[0..n], p.label[0..n]);
            w.label_len = @intCast(n);
            m.pins.append(m.gpa, w) catch break;
        }
        m.setLines(opts.line, opts.lines);
        if (opts.camera) |cam| m.camera = cam;
        m.user = opts.user;
        m.muted = opts.muted;
        m.radius = opts.radius;
        if (ios) {
            m.id = ui.hole(c, opts.key, opts.radius);
            m.seen = true;
            native.want(m);
        } else placeholder(c, opts);
    }

    fn setLines(m: *Map, first: ?Line, more: []const Line) void {
        m.line.clearRetainingCapacity();
        m.segs.clearRetainingCapacity();
        if (first) |l| m.addLine(l);
        for (more) |l| m.addLine(l);
    }

    fn addLine(m: *Map, l: Line) void {
        if (l.points.len < 2) return;
        const start = m.line.items.len;
        m.line.appendSlice(m.gpa, l.points) catch return;
        m.segs.append(m.gpa, .{ .start = @intCast(start), .len = @intCast(l.points.len), .color = l.color, .width = l.width, .dashed = l.dashed }) catch {
            m.line.shrinkRetainingCapacity(start);
        };
    }

    /// The points of line `i`.
    pub fn segPoints(m: *const Map, i: usize) []const Coord {
        const sg = m.segs.items[i];
        return m.line.items[sg.start .. sg.start + sg.len];
    }

    /// The pin tapped since the last call, if any.
    pub fn takeTap(m: *Map) ?u64 {
        defer m.tapped = null;
        return m.tapped;
    }
};

/// Off iOS: a tinted box listing what the map would show.
fn placeholder(c: *ui.Context, opts: Options) void {
    c.next_key = opts.key;
    const box = ui.div(c).sizeFull().column().center().gap(4).bg(c.theme.surface_hover).rounded(opts.radius);
    defer box.end();
    ui.text(c, "Map", .{ .size = 15, .weight = .semibold, .color = c.theme.muted });
    var buf: [48]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{d} pins", .{opts.pins.len}) catch "";
    ui.text(c, line, .{ .size = 12, .color = c.theme.muted });
}

test "a map keeps what it was asked to show, labels copied" {
    var m: Map = .init(std.testing.allocator);
    defer m.deinit();
    var label = "83139".*;
    const pins = [_]Pin{.{ .id = 7, .at = .{ .lat = 1.3, .lng = 103.9 }, .label = &label }};
    // No context needed for the bookkeeping: what `view` copies.
    m.pins.clearRetainingCapacity();
    for (pins) |p| {
        var w: Want = .{ .id = p.id, .at = p.at, .style = p.style, .selected = p.selected };
        @memcpy(w.label_buf[0..p.label.len], p.label);
        w.label_len = @intCast(p.label.len);
        try m.pins.append(m.gpa, w);
    }
    label[0] = 'X';
    const walk = [_]Coord{ .{ .lat = 1.30, .lng = 103.8 }, .{ .lat = 1.31, .lng = 103.8 } };
    const ride = [_]Coord{ walk[1], .{ .lat = 1.32, .lng = 103.9 }, .{ .lat = 1.33, .lng = 103.9 } };
    m.setLines(null, &.{ .{ .points = &walk, .dashed = true }, .{ .points = ride[0..1] }, .{ .points = &ride } });
    try std.testing.expectEqual(@as(usize, 2), m.segs.items.len);
    try std.testing.expect(m.segs.items[0].dashed and !m.segs.items[1].dashed);
    try std.testing.expectEqual(@as(usize, 3), m.segPoints(1).len);
    try std.testing.expectEqualStrings("83139", m.pins.items[0].label());
    try std.testing.expect(m.takeTap() == null);
}
