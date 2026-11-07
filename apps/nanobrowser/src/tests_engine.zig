//! The test root for the HTML parser and the CSS engine; it sits here so
//! that `html/` and `css/` can both reach `dom.zig`.
//! `zig test apps/nanobrowser/src/tests_engine.zig`
const std = @import("std");

test {
    _ = @import("html/tests.zig");
    _ = @import("css/tests.zig");
}
