//! Every test of the script world.
test {
    _ = @import("cookies.zig");
    _ = @import("api_style.zig");
    _ = @import("tests_basic.zig");
    _ = @import("tests_dom.zig");
    _ = @import("tests_scripts.zig");
    _ = @import("tests_events.zig");
    _ = @import("tests_window.zig");
    _ = @import("tests_custom.zig");
    _ = @import("tests_robust.zig");
    _ = @import("tests_react.zig");
    _ = @import("tests_typing.zig");
    _ = @import("tests_net.zig");
    _ = @import("tests_misc.zig");
    _ = @import("tests_frames.zig");
    _ = @import("tests_worker.zig");
    _ = @import("tests_gaps.zig");
}
