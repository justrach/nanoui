//! Tray icons where nanoui has none yet (Linux, Windows, Android).
pub const Click = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, tray: *Tray) void };
pub const Anchor = struct { x: f64, y: f64, width: f64, height: f64 };

pub const Options = struct {
    title: []const u8 = "",
    symbol: []const u8 = "",
    tooltip: []const u8 = "",
    on_click: ?Click = null,
};

pub const Tray = struct {
    pub fn destroy(_: *Tray) void {}
    pub fn setTitle(_: *Tray, _: []const u8) void {}
    pub fn setSymbol(_: *Tray, _: []const u8) void {}
    pub fn setImage(_: *Tray, _: []const u8, _: usize, _: usize, _: f64, _: bool) void {}
    pub fn anchor(_: *Tray) Anchor {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }
};
