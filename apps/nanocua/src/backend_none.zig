//! Where nanocua can't act yet (Linux and Windows, next): every tool says so.
const mcp = @import("mcp.zig");
const tools = @import("tools.zig");

pub const None = struct {
    pub fn backend(n: *None) mcp.Backend {
        return .{ .ptr = n, .call = call };
    }

    fn call(_: *anyopaque, _: tools.Tool, _: tools.Args, reply: *mcp.Reply) void {
        reply.fail("nanocua controls macOS so far; Linux (X11) and Windows are next.");
    }
};
