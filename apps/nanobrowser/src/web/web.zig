//! The script world of a page: what the rest of the browser calls. Until the
//! bindings land, a page runs no scripts and every event goes unheard.
const dom = @import("../dom.zig");
const Page = @import("../page.zig").Page;

pub const Modifiers = struct { ctrl: bool = false, shift: bool = false, alt: bool = false, meta: bool = false };

pub const World = struct {
    pub fn destroy(_: *World) void {}
    pub fn stop(_: *World) void {}
};

/// The document has parsed: runs its scripts, in order.
pub fn begin(_: *Page) void {}

pub fn scrolled(_: *Page, _: *dom.Node) void {}

pub fn pointerMoved(_: *Page, _: ?*dom.Node, _: ?*dom.Node, _: f32, _: f32) void {}

/// True when a script prevented what the event would do.
pub fn mouseEvent(_: *Page, _: *dom.Node, _: []const u8, _: f32, _: f32, _: Modifiers) bool {
    return false;
}

pub fn simpleEvent(_: *Page, _: *dom.Node, _: []const u8) void {}

/// True when a script stopped the form.
pub fn submitEvent(_: *Page, _: *dom.Node) bool {
    return false;
}

pub fn runUrl(_: *Page, _: []const u8) void {}
