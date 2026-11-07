//! CSS-wide keywords: copying what a property governs from one `Style` to
//! another. `inherit` copies from the parent, `initial` from the initial style,
//! `revert` from the style the UA sheet alone gives.
const std = @import("std");
const style = @import("style.zig");
const prop = @import("prop.zig");

const Prop = prop.Prop;
const Style = style.Style;

fn sides(d: *Style, s: *const Style, comptime names: []const []const u8) void {
    inline for (names) |n| @field(d, n) = @field(s, n);
}

/// Copies the fields `p` sets from `s` to `d`. Properties with no field do
/// nothing.
pub fn copy(p: Prop, d: *Style, s: *const Style) void {
    switch (p) {
        .custom, .all => {},
        .color_scheme => d.dark_scheme = s.dark_scheme,
        .direction => d.rtl = s.rtl,
        .font => sides(d, s, &.{ "font_size", "font_weight", "italic", "mono", "serif", "mono_generic", "font_family", "font_stretch", "font_size_abs", "line_height", "line_height_factor" }),
        .font_size => sides(d, s, &.{ "font_size", "font_size_abs" }),
        .font_family => sides(d, s, &.{ "mono", "serif", "mono_generic", "font_family" }),
        .font_stretch => d.font_stretch = s.font_stretch,
        .font_variant_numeric => d.tabular = s.tabular,
        .font_weight => d.font_weight = s.font_weight,
        .font_style => d.italic = s.italic,
        .line_height => sides(d, s, &.{ "line_height", "line_height_factor" }),
        .color => d.color = s.color,
        .display => sides(d, s, &.{ "display", "flow_root" }),
        .position => d.position = s.position,
        .float => d.float = s.float,
        .clear => d.clear = s.clear,
        .box_sizing => d.box_sizing = s.box_sizing,
        .visibility => d.visibility = s.visibility,
        .opacity => d.opacity = s.opacity,
        .z_index => d.z_index = s.z_index,
        .overflow => sides(d, s, &.{ "overflow_x", "overflow_y" }),
        .overflow_x => d.overflow_x = s.overflow_x,
        .overflow_y => d.overflow_y = s.overflow_y,
        .cursor => d.cursor = s.cursor,
        .pointer_events => d.pointer_events = s.pointer_events,
        .width, .inline_size => d.width = s.width,
        .height, .block_size => d.height = s.height,
        .min_width, .min_inline_size => d.min_width = s.min_width,
        .min_height, .min_block_size => d.min_height = s.min_height,
        .max_width, .max_inline_size => d.max_width = s.max_width,
        .max_height, .max_block_size => d.max_height = s.max_height,
        .aspect_ratio => sides(d, s, &.{ "aspect_ratio", "aspect_auto" }),
        .margin => sides(d, s, &.{ "margin_top", "margin_right", "margin_bottom", "margin_left" }),
        .margin_top, .margin_block_start => d.margin_top = s.margin_top,
        .margin_right => d.margin_right = s.margin_right,
        .margin_bottom, .margin_block_end => d.margin_bottom = s.margin_bottom,
        .margin_left => d.margin_left = s.margin_left,
        .margin_inline => sides(d, s, &.{ "margin_left", "margin_right" }),
        .margin_block => sides(d, s, &.{ "margin_top", "margin_bottom" }),
        .margin_inline_start => if (d.rtl) {
            d.margin_right = s.margin_right;
        } else {
            d.margin_left = s.margin_left;
        },
        .margin_inline_end => if (d.rtl) {
            d.margin_left = s.margin_left;
        } else {
            d.margin_right = s.margin_right;
        },
        .padding => sides(d, s, &.{ "padding_top", "padding_right", "padding_bottom", "padding_left" }),
        .padding_top, .padding_block_start => d.padding_top = s.padding_top,
        .padding_right => d.padding_right = s.padding_right,
        .padding_bottom, .padding_block_end => d.padding_bottom = s.padding_bottom,
        .padding_left => d.padding_left = s.padding_left,
        .padding_inline => sides(d, s, &.{ "padding_left", "padding_right" }),
        .padding_block => sides(d, s, &.{ "padding_top", "padding_bottom" }),
        .padding_inline_start => if (d.rtl) {
            d.padding_right = s.padding_right;
        } else {
            d.padding_left = s.padding_left;
        },
        .padding_inline_end => if (d.rtl) {
            d.padding_left = s.padding_left;
        } else {
            d.padding_right = s.padding_right;
        },
        .top, .inset_block_start => d.top = s.top,
        .right => d.right = s.right,
        .bottom, .inset_block_end => d.bottom = s.bottom,
        .left => d.left = s.left,
        .inset => sides(d, s, &.{ "top", "right", "bottom", "left" }),
        .inset_inline, .inset_inline_start, .inset_inline_end => sides(d, s, &.{ "left", "right" }),
        .inset_block => sides(d, s, &.{ "top", "bottom" }),
        .border => sides(d, s, &.{ "border_top", "border_right", "border_bottom", "border_left" }),
        .border_width, .border_style, .border_color => sides(d, s, &.{ "border_top", "border_right", "border_bottom", "border_left" }),
        .border_top, .border_top_width, .border_top_style, .border_top_color, .border_block_start => d.border_top = s.border_top,
        .border_right, .border_right_width, .border_right_style, .border_right_color => d.border_right = s.border_right,
        .border_bottom, .border_bottom_width, .border_bottom_style, .border_bottom_color, .border_block_end => d.border_bottom = s.border_bottom,
        .border_left, .border_left_width, .border_left_style, .border_left_color => d.border_left = s.border_left,
        .border_inline, .border_inline_start, .border_inline_end, .border_inline_width, .border_inline_color, .border_inline_style => sides(d, s, &.{ "border_left", "border_right" }),
        .border_block, .border_block_width, .border_block_color, .border_block_style => sides(d, s, &.{ "border_top", "border_bottom" }),
        .border_radius => sides(d, s, &.{ "radius", "radius_pct", "radius_y", "radius_y_pct" }),
        .border_top_left_radius, .border_start_start_radius => corner(d, s, 0),
        .border_top_right_radius, .border_start_end_radius => corner(d, s, 1),
        .border_bottom_right_radius, .border_end_end_radius => corner(d, s, 2),
        .border_bottom_left_radius, .border_end_start_radius => corner(d, s, 3),
        .outline, .outline_width, .outline_style, .outline_color => d.outline = s.outline,
        .outline_offset => d.outline_offset = s.outline_offset,
        .background => sides(d, s, &.{ "background", "background_image", "background_gradient", "background_more", "background_clip", "background_size", "background_size_x", "background_size_y", "background_repeat", "background_x", "background_y", "background_x_px", "background_y_px", "background_origin", "background_fixed", "bg_sizes", "bg_positions", "bg_repeats", "bg_clips", "bg_origins", "bg_fixed" }),
        .fill => d.svg.fill = s.svg.fill,
        .fill_opacity => d.svg.fill_opacity = s.svg.fill_opacity,
        .fill_rule => d.svg.fill_evenodd = s.svg.fill_evenodd,
        .clip_rule => d.svg.clip_evenodd = s.svg.clip_evenodd,
        .stroke => d.svg.stroke = s.svg.stroke,
        .stroke_width => d.svg.stroke_width = s.svg.stroke_width,
        .stroke_opacity => d.svg.stroke_opacity = s.svg.stroke_opacity,
        .stroke_linecap => d.svg.cap = s.svg.cap,
        .stroke_linejoin => d.svg.join = s.svg.join,
        .stroke_miterlimit => d.svg.miter_limit = s.svg.miter_limit,
        .stroke_dasharray => d.svg.dash = s.svg.dash,
        .stroke_dashoffset => d.svg.dash_offset = s.svg.dash_offset,
        .stop_color => d.svg.stop_color = s.svg.stop_color,
        .stop_opacity => d.svg.stop_opacity = s.svg.stop_opacity,
        .paint_order => d.svg.stroke_first = s.svg.stroke_first,
        .vector_effect => d.svg.non_scaling_stroke = s.svg.non_scaling_stroke,
        .object_position => sides(d, s, &.{ "object_x", "object_y", "object_x_px", "object_y_px" }),
        .background_color => d.background = s.background,
        .background_image => sides(d, s, &.{ "background_image", "background_gradient", "background_more" }),
        .background_clip => sides(d, s, &.{ "background_clip", "bg_clips" }),
        .background_origin => sides(d, s, &.{ "background_origin", "bg_origins" }),
        .background_attachment => sides(d, s, &.{ "background_fixed", "bg_fixed" }),
        .background_size => sides(d, s, &.{ "background_size", "background_size_x", "background_size_y", "bg_sizes" }),
        .background_repeat => sides(d, s, &.{ "background_repeat", "bg_repeats" }),
        .background_position => sides(d, s, &.{ "background_x", "background_y", "background_x_px", "background_y_px", "bg_positions" }),
        .background_position_x => sides(d, s, &.{ "background_x", "background_x_px" }),
        .background_position_y => sides(d, s, &.{ "background_y", "background_y_px" }),
        .box_shadow => sides(d, s, &.{ "shadow", "shadows" }),
        .text_shadow => d.text_shadows = s.text_shadows,
        .text_fill_color => d.text_fill = s.text_fill,
        .accent_color => d.accent = s.accent,
        .appearance => d.appearance_none = s.appearance_none,
        .isolation, .mix_blend_mode, .will_change => d.makes_context = s.makes_context,
        .clip => d.clip_rect = s.clip_rect,
        .clip_path => {
            d.clip_path = s.clip_path;
            d.svg.clip_path = s.svg.clip_path;
        },
        .filter => d.filters = s.filters,
        .backdrop_filter => d.backdrop_blur = s.backdrop_blur,
        .rotate => d.rotate = s.rotate,
        .transform_origin => sides(d, s, &.{ "transform_origin_x", "transform_origin_y" }),
        .animation, .animation_name, .animation_duration, .animation_delay, .animation_timing_function, .animation_iteration_count, .animation_direction, .animation_fill_mode, .animation_play_state => d.anim_raw = s.anim_raw,
        .transition, .transition_delay, .transition_duration, .transition_property, .transition_timing_function => d.trans_raw = s.trans_raw,
        .object_fit => d.object_fit = s.object_fit,
        .transform => d.transform = s.transform,
        .translate => sides(d, s, &.{ "translate_x", "translate_y" }),
        .scale => sides(d, s, &.{ "scale_x", "scale_y" }),
        .letter_spacing => d.letter_spacing = s.letter_spacing,
        .word_spacing => d.word_spacing = s.word_spacing,
        .text_align => sides(d, s, &.{ "text_align", "center_children" }),
        .text_indent => d.text_indent = s.text_indent,
        .white_space, .white_space_collapse, .text_wrap, .text_wrap_mode => {
            d.white_space = s.white_space;
            d.text_balance = s.text_balance;
        },
        .text_transform => d.text_transform = s.text_transform,
        .list_style => sides(d, s, &.{ "list_style", "list_inside" }),
        .list_style_type => d.list_style = s.list_style,
        .list_style_position => d.list_inside = s.list_inside,
        .text_decoration => sides(d, s, &.{ "underline", "line_through", "overline", "text_decoration_color" }),
        .text_decoration_line => sides(d, s, &.{ "underline", "line_through", "overline" }),
        .text_decoration_color => d.text_decoration_color = s.text_decoration_color,
        .vertical_align => d.vertical_align = s.vertical_align,
        .text_overflow => d.text_overflow_ellipsis = s.text_overflow_ellipsis,
        .flex => sides(d, s, &.{ "flex_grow", "flex_shrink", "flex_basis" }),
        .flex_direction => d.flex_direction = s.flex_direction,
        .flex_wrap => d.flex_wrap = s.flex_wrap,
        .flex_flow => sides(d, s, &.{ "flex_direction", "flex_wrap" }),
        .flex_grow => d.flex_grow = s.flex_grow,
        .flex_shrink => d.flex_shrink = s.flex_shrink,
        .flex_basis => d.flex_basis = s.flex_basis,
        .order => d.order = s.order,
        .justify_content => d.justify_content = s.justify_content,
        .justify_items => d.justify_items = s.justify_items,
        .justify_self => d.justify_self = s.justify_self,
        .align_items => d.align_items = s.align_items,
        .align_self => d.align_self = s.align_self,
        .align_content => d.align_content = s.align_content,
        .place_items => sides(d, s, &.{ "align_items", "justify_items" }),
        .place_content => sides(d, s, &.{ "align_content", "justify_content" }),
        .place_self => sides(d, s, &.{ "align_self", "justify_self" }),
        .gap, .grid_gap => sides(d, s, &.{ "row_gap", "column_gap" }),
        .row_gap, .grid_row_gap => d.row_gap = s.row_gap,
        .column_gap, .grid_column_gap => d.column_gap = s.column_gap,
        .grid_template, .grid => sides(d, s, &.{ "grid_template_columns", "grid_template_rows" }),
        .grid_template_columns => d.grid_template_columns = s.grid_template_columns,
        .grid_template_rows => d.grid_template_rows = s.grid_template_rows,
        .grid_auto_rows => d.grid_auto_rows = s.grid_auto_rows,
        .grid_auto_columns => d.grid_auto_columns = s.grid_auto_columns,
        .grid_column, .grid_column_start, .grid_column_end => d.grid_column = s.grid_column,
        .grid_row, .grid_row_start, .grid_row_end => d.grid_row = s.grid_row,
        .grid_area => sides(d, s, &.{ "grid_row", "grid_column" }),
        .grid_template_areas => d.grid_areas = s.grid_areas,
        .grid_auto_flow => {
            d.grid_auto_flow_column = s.grid_auto_flow_column;
            d.grid_auto_flow_dense = s.grid_auto_flow_dense;
        },
        .mask, .mask_image => d.mask_image = s.mask_image,
        .content => sides(d, s, &.{ "content", "content_parts", "marker_hidden" }),
        .border_collapse => d.border_collapse = s.border_collapse,
        .border_spacing => sides(d, s, &.{ "border_spacing", "border_spacing_y" }),
        .table_layout => d.table_fixed = s.table_fixed,
        .caption_side => d.caption_bottom = s.caption_bottom,
        .word_break => d.word_break_all = s.word_break_all,
        .line_break => d.line_break_anywhere = s.line_break_anywhere,
        .overflow_wrap, .word_wrap => d.overflow_wrap_anywhere = s.overflow_wrap_anywhere,
        .tab_size => d.tab_size = s.tab_size,
        .container => sides(d, s, &.{ "container_type", "container_names" }),
        .container_type => d.container_type = s.container_type,
        .container_name => d.container_names = s.container_names,
        .contain => sides(d, s, &.{ "contain_size", "contain_inline_size", "contain_flow", "makes_context" }),
        .columns => sides(d, s, &.{ "column_count", "column_width" }),
        .column_count => d.column_count = s.column_count,
        .column_width => d.column_width = s.column_width,
        .column_span => d.column_span_all = s.column_span_all,
        .counter_reset => d.counter_reset = s.counter_reset,
        .counter_increment => d.counter_increment = s.counter_increment,
        .counter_set => d.counter_set = s.counter_set,
        .scroll_margin_top, .scroll_margin_block_start, .scroll_margin, .scroll_margin_block => d.scroll_margin_top = s.scroll_margin_top,
        .scroll_padding_top, .scroll_padding_block_start, .scroll_padding, .scroll_padding_block => d.scroll_padding_top = s.scroll_padding_top,
        else => {},
    }
}

fn corner(d: *Style, s: *const Style, i: usize) void {
    d.radius[i] = s.radius[i];
    d.radius_pct[i] = s.radius_pct[i];
    d.radius_y[i] = s.radius_y[i];
    d.radius_y_pct[i] = s.radius_y_pct[i];
}

/// A new element's start: initial values, with the inherited ones from `p`.
pub fn inherit(p: *const Style) Style {
    var s: Style = .{};
    sides(&s, p, &.{
        "visibility",      "cursor",           "pointer_events",       "color",
        "font_size",       "font_weight",      "italic",               "mono",
        "serif",           "mono_generic",     "font_family",          "font_stretch",
        "tabular",         "font_size_abs",    "line_height",          "line_height_factor",
        "letter_spacing",  "word_spacing",     "text_align",           "text_indent",
        "center_children", "white_space",      "text_transform",       "list_style",
        "list_inside",     "rtl",              "inherited_visibility", "border_collapse",
        "border_spacing",  "border_spacing_y", "word_break_all",       "line_break_anywhere", "overflow_wrap_anywhere",
        "caption_bottom",  "tab_size",         "dark_scheme",          "text_fill",
        "text_shadows",    "accent",
        "text_balance",    "list_style_text",
    });
    s.svg = p.svg.inherited();
    return s;
}

/// `all`, as one pass of the cascade sees it: only the fields that pass
/// governs, so that later declarations of earlier passes survive it.
pub fn copyAll(d: *Style, s: *const Style, phase: u2) void {
    const font_fields = [_][]const u8{ "font_size", "font_weight", "italic", "mono", "serif", "mono_generic", "font_family", "font_stretch", "font_size_abs" };
    const text_fields = [_][]const u8{ "line_height", "line_height_factor", "color" };
    switch (phase) {
        0 => sides(d, s, &font_fields),
        1 => sides(d, s, &text_fields),
        else => {
            const saved = d.*;
            d.* = s.*;
            sides(d, &saved, &font_fields);
            sides(d, &saved, &text_fields);
            d.rtl = saved.rtl;
            d.dark_scheme = saved.dark_scheme;
        },
    }
}
