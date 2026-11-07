//! Selectors' data (Selectors Level 4). Parsing is in `selector_parser.zig`,
//! matching in `selector_match.zig`. A compound's `combinator` joins it to the
//! compound on its left; a selector is held left to right, the subject last.
const parser = @import("selector_parser.zig");

pub const Parser = parser.Parser;
pub const parseText = parser.parseText;
pub const maxSpecificity = parser.maxSpecificity;

pub const Combinator = enum(u8) { descendant, child, next, later };
pub const AttrOp = enum(u8) { exists, equals, includes, dash, prefix, suffix, substring };
pub const PseudoElement = enum(u8) { none, before, after, placeholder, marker, backdrop, slotted, part, other };

pub const PseudoClass = enum(u8) {
    root,
    empty,
    first_child,
    last_child,
    only_child,
    first_of_type,
    last_of_type,
    only_of_type,
    link,
    any_link,
    visited,
    hover,
    active,
    focus,
    focus_visible,
    focus_within,
    checked,
    disabled,
    enabled,
    required,
    optional,
    placeholder_shown,
    read_only,
    read_write,
    scope,
    target,
    defined,
    default,
    valid,
    indeterminate,
    modal,
    popover_open,
    /// `:open`: an open `<details>`, `<dialog>`, `<select>`.
    open,
    /// Known to exist, never true here (`:fullscreen`, `:-webkit-autofill`).
    never,
};

pub const Attr = struct {
    name: []const u8,
    /// Lowercase `name`, for HTML elements.
    lower: []const u8,
    value: []const u8 = "",
    op: AttrOp = .exists,
    /// The `i` flag; `s` clears it.
    ci: ?bool = null,
};

pub const Nth = struct {
    a: i32,
    b: i32,
    of_type: bool = false,
    from_end: bool = false,
    of: []const Selector = &.{},
};

pub const Simple = union(enum) {
    tag: []const u8,
    universal,
    id: []const u8,
    class: []const u8,
    attr: Attr,
    pseudo: PseudoClass,
    nth: Nth,
    not: []const Selector,
    is: []const Selector,
    has: []const Selector,
    lang: []const u8,
    /// `:host` and `:host(list)`, the list empty for the former.
    host: []const Selector,
    /// `:host-context(list)`.
    host_context: []const Selector,
};

pub const Compound = struct {
    simples: []const Simple,
    combinator: Combinator = .descendant,
};

pub const Selector = struct {
    compounds: []const Compound,
    /// (ids, classes, tags) in a byte each: higher wins.
    specificity: u32 = 0,
    pseudo: PseudoElement = .none,
    /// Uses `:hover`, `:active`, `:focus` and their kin anywhere.
    uses_state: bool = false,
    /// In `:has()`: how the leftmost compound relates to the anchor.
    leading: Combinator = .descendant,
    /// `::slotted(list)`: what it asks of the slotted element.
    slotted: []const Selector = &.{},
    /// `::part(name)`.
    part: []const u8 = "",
};
