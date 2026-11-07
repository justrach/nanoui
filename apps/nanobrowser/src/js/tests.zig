//! Runs every JS engine test. `zig test apps/nanobrowser/src/js/tests.zig`.

test {
    _ = @import("tests_basic.zig");
    _ = @import("tests_lang.zig");
    _ = @import("tests_class.zig");
    _ = @import("tests_gen.zig");
    _ = @import("tests_object.zig");
    _ = @import("tests_array.zig");
    _ = @import("tests_string.zig");
    _ = @import("tests_regexp.zig");
    _ = @import("tests_number.zig");
    _ = @import("tests_json_date.zig");
    _ = @import("tests_collections.zig");
    _ = @import("tests_proxy.zig");
    _ = @import("tests_typed.zig");
    _ = @import("tests_promise.zig");
    _ = @import("tests_module.zig");
    _ = @import("tests_embed.zig");
    _ = @import("tests_gc.zig");
    _ = @import("tests_bundle.zig");
    _ = @import("tests_limits.zig");
    _ = @import("tests_semantics.zig");
}
