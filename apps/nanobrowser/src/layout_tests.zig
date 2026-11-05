//! Root of the layout engine's tests: `zig test` on this file, so that
//! `layout/` can reach `dom.zig` and `css/`.
test {
    _ = @import("layout/layout.zig");
    _ = @import("layout/tests_block.zig");
    _ = @import("layout/tests_inline.zig");
    _ = @import("layout/tests_float.zig");
    _ = @import("layout/tests_flex.zig");
    _ = @import("layout/tests_grid.zig");
    _ = @import("layout/tests_table.zig");
    _ = @import("layout/tests_gen.zig");
    _ = @import("layout/tests_robust.zig");
    _ = @import("layout/tests_html.zig");
    _ = @import("layout/tests_flow.zig");
}
