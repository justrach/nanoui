//! The CSS engine's interface, for layout, paint and the DOM bindings.
const cascade = @import("cascade.zig");
const query = @import("query.zig");
const sheet = @import("sheet.zig");
const media = @import("media.zig");
const tokenizer = @import("tokenizer.zig");
const parser = @import("parser.zig");

pub const style = @import("style.zig");
pub const url = @import("url.zig");

pub const Engine = cascade.Engine;
pub const Flip = @import("cascade_state.zig").Flip;
pub const Change = cascade.Change;
pub const Viewport = cascade.Viewport;
pub const Sheet = sheet.Sheet;
pub const Declarations = sheet.Declarations;
pub const Declaration = sheet.Declaration;
pub const Import = sheet.Import;
pub const MediaList = media.List;

pub const parseSheet = parser.parseSheet;
pub const parseSheetMedia = parser.parseSheetMedia;
pub const parseDeclarations = parser.parseDeclarations;
/// Text of a media query list, for `<link media>` and `<style media>`.
pub const parseMedia = media.parseText;
/// A value's tokens back to text, for `element.style`.
pub const serializeTokens = tokenizer.serialize;

pub const QueryError = query.Error;
pub const querySelector = query.querySelector;
pub const querySelectorAll = query.querySelectorAll;
pub const matchesSelector = query.matchesSelector;
pub const closest = query.closest;
