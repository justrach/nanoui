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
};

pub const Camera = struct {
    center: Coord,
    /// Degrees of latitude shown top to bottom.
    span: f64 = 0.008,
    animated: bool = true,
};

pub const Options = struct {
    pins: []const Pin = &.{},
    line: ?Line = null,
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
    line: std.ArrayList(Coord) = .empty,
    line_color: ui.Color = .hex(0x1A73E8),
    line_width: f32 = 5,
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
        m.line.clearRetainingCapacity();
        if (opts.line) |l| {
            m.line.appendSlice(m.gpa, l.points) catch {};
            m.line_color = l.color;
            m.line_width = l.width;
        }
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
    try std.testing.expectEqualStrings("83139", m.pins.items[0].label());
    try std.testing.expect(m.takeTap() == null);
}
