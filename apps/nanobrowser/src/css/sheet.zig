//! What a stylesheet parses to: declarations and flat style rules. Nesting
//! and conditional groups are gone by here: a nested rule is a rule whose
//! selector matches through its parent, and a group is a `Cond` on each rule.
const std = @import("std");
const tk = @import("tokenizer.zig");
const sel = @import("selectors.zig");
const media = @import("media.zig");
const prop = @import("prop.zig");

pub const Token = tk.Token;
pub const Prop = prop.Prop;

/// A CSS-wide keyword as a value.
pub const Wide = enum(u8) { none, inherit, initial, unset, revert };

pub const Declaration = struct {
    prop: Prop,
    /// The name as written lowercased, or a custom property's in its own case.
    name: []const u8,
    /// Trimmed; `!important` removed.
    value: []const Token,
    important: bool = false,
    /// Holds `var()` or `env()`: substituted when computed.
    has_var: bool = false,
    wide: Wide = .none,
    /// A custom property's name hash.
    hash: u32 = 0,
    /// See `prop.phase`.
    phase: u2 = 2,
};

pub const Declarations = struct {
    items: []const Declaration = &.{},
    has_important: bool = false,
    has_custom: bool = false,
    has_content: bool = false,

    /// The last declaration for a name, for script reads of `element.style`.
    pub fn find(d: *const Declarations, name: []const u8) ?*const Declaration {
        var i = d.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, d.items[i].name, name)) return &d.items[i];
        }
        return null;
    }
};

/// The media or other conditions a rule sits under.
pub const Cond = struct {
    media: *const media.List,
    parent: ?*const Cond = null,

    pub fn matches(c: *const Cond, v: media.Viewport) bool {
        var at: ?*const Cond = c;
        while (at) |x| : (at = x.parent) if (!x.media.matches(v)) return false;
        return true;
    }
};

/// `@container name (size query)`: which container, and what it's asked. Nested
/// `@container` rules go by `parent`.
pub const ContainerCond = struct {
    name: []const u8 = "",
    query: ?*const media.Cond = null,
    parent: ?*const ContainerCond = null,
};

pub const Rule = struct {
    selectors: []const sel.Selector,
    decls: *const Declarations,
    cond: ?*const Cond = null,
    container: ?*const ContainerCond = null,
    /// The dotted cascade layer; "" when unlayered.
    layer: []const u8 = "",
};

pub const Import = struct {
    /// Resolved against the sheet's base URL.
    url: []const u8,
    /// Null means all media.
    media: ?*const media.List = null,
    /// `layer(name)`'s name; "" for none. Recorded only: the imported sheet's
    /// rules stay unlayered.
    layer: []const u8 = "",
    /// `supports(...)` was false: the host should not fetch it.
    skip: bool = false,
};

pub const FontFace = struct {
    decls: *const Declarations,
};

/// One `from`, `to` or percentage of `@keyframes`.
pub const Keyframe = struct {
    /// 0 to 1.
    at: f32,
    decls: *const Declarations,
};

pub const Keyframes = struct {
    name: []const u8,
    /// In order of `at`.
    frames: []const Keyframe = &.{},
    cond: ?*const Cond = null,
};

/// `@property`: what a custom property starts as, and whether it inherits.
pub const PropertyRule = struct {
    name: []const u8,
    /// Null: it starts invalid (`syntax: "*"` with no `initial-value`).
    initial: ?[]const Token = null,
    inherits: bool = true,
};

pub const Sheet = struct {
    rules: []const Rule = &.{},
    /// The `@import`s, in order: the host fetches them and passes the results
    /// to `Engine.setSheets` before this sheet.
    imports: []const Import = &.{},
    font_faces: []const FontFace = &.{},
    /// `@keyframes`, by name; the last of a name wins (`Engine.keyframes`).
    keyframes: []const Keyframes = &.{},
    properties: []const PropertyRule = &.{},
    /// Layer names in the order first mentioned.
    layers: []const []const u8 = &.{},
    /// Every condition, for telling when a viewport change matters.
    conds: []const *const Cond = &.{},
    /// The sheet's own media: `<link media>`, `<style media>`, an import's. The
    /// host may set it.
    media: ?*const media.List = null,
    base_url: []const u8 = "",

    pub fn active(s: *const Sheet, v: media.Viewport) bool {
        const m = s.media orelse return true;
        return m.matches(v);
    }
};
