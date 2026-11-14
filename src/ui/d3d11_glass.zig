//! Direct3D 11 Liquid Glass backdrop passes, split out of `d3d11.zig` to keep
//! each backend module small and focused.
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const glass = @import("glass.zig");
const api = @import("d3d11_glue.zig");
const d3d11 = @import("d3d11.zig");

const Com = api.Com;
const Box = api.Box;
const Params = api.Params;
const Draw = api.Draw;
const VSSetShader = api.VSSetShader;
const PSSetShader = api.PSSetShader;
const PSSetShaderResources = api.PSSetShaderResources;
const CopySubresourceRegion = api.CopySubresourceRegion;

/// Pane `at`: its backdrop averaged and blurred from what was drawn, then the
/// pane itself over the frame.
pub fn drawPane(r: *d3d11.Renderer, instances: []const gpu.Instance, at: usize, size: types.Size, scale: f32) void {
    // Whatever happens below, the frame is bound again and its viewport set
    // when this returns: a pane that cannot draw must never leave the renderer
    // pointed at a backdrop texture, or every later instance is drawn where no
    // one sees it.
    const g = r.context;
    defer {
        d3d11.setViewport(g, @floatFromInt(r.frame_w), @floatFromInt(r.frame_h));
        d3d11.bindTarget(g, r.frame.rtv.?);
        // The passes rebound the target, the vertex shader and its resources:
        // `setState` puts back what the next quad draw needs.
        r.setState();
    }
    const b = glass.backdropFor(instances[at], scale, r.frame_w, r.frame_h) orelse return;
    const pass_vs = r.pass_vs;
    const down_ps = r.down_ps;
    const blur_ps = if (b.sigma > 0) r.blur_ps else null;
    const w: usize = @intCast(b.w);
    const h: usize = @intCast(b.h);
    r.a.reserve(r.device, w, h, false);
    r.b.reserve(r.device, w, h, false);
    if (r.a.rtv == null or r.a.srv == null or r.b.rtv == null or r.b.srv == null) return;
    // The panes read what was drawn before them. Direct3D 11 leaves a texture's
    // reads undefined while its render target view is bound, so the frame is
    // copied first: `snap` is what `down_ps` samples. Its RTV is never bound,
    // only its SRV is read.
    r.snap.reserve(r.device, r.frame_w, r.frame_h, false);
    if (r.snap.srv == null or r.snap.texture == null or r.frame.texture == null) return;
    const frame_box: Box = .{ .right = @intCast(r.frame_w), .bottom = @intCast(r.frame_h) };
    g.slot(*const fn (*Com, *Com, u32, u32, u32, u32, *Com, u32, ?*const Box) callconv(.winapi) void, CopySubresourceRegion)(g, r.snap.texture.?, 0, 0, 0, 0, r.frame.texture.?, 0, &frame_box);
    // The passes read the frame's area in `down`-pixel squares and write
    // `size` texels: both are the backdrop's, not the frame's.
    const back: Params = .{
        .area = b.area,
        .down = @floatFromInt(b.down),
        .frame_height = @intCast(r.frame_h),
        .radius = b.radius,
        .sigma = b.sigma,
        .progressive = b.progressive,
        .size = .{ @floatFromInt(b.w), @floatFromInt(b.h) },
    };
    pass(r, pass_vs, down_ps, r.snap.srv.?, r.a.rtv.?, back, b.w, b.h);
    if (blur_ps) |ps| {
        var across = back;
        across.dir = .{ 1, 0 };
        pass(r, pass_vs, ps, r.a.srv.?, r.b.rtv.?, across, b.w, b.h);
        var down_dir = back;
        down_dir.dir = .{ 0, 1 };
        pass(r, pass_vs, ps, r.b.srv.?, r.a.rtv.?, down_dir, b.w, b.h);
    }
    // The pane itself over the frame, reading `a` as its backdrop.
    d3d11.setViewport(g, @floatFromInt(r.frame_w), @floatFromInt(r.frame_h));
    d3d11.bindTarget(g, r.frame.rtv.?);
    r.setBlend(true);
    r.drawRange(true, size, scale, at, 1, .{
        .origin = .{ @floatFromInt(b.area[0]), @floatFromInt(b.area[1]) },
        .size = .{ @floatFromInt(b.w), @floatFromInt(b.h) },
        .down = @floatFromInt(b.down),
    });
}

/// One pass of a pane's backdrop: `ps` reading `src` into `dst`, the whole
/// target covered by one triangle.
fn pass(r: *d3d11.Renderer, pass_vs: *Com, ps: *Com, src: *Com, dst: *Com, p: Params, w: i32, h: i32) void {
    const g = r.context;
    d3d11.setViewport(g, @floatFromInt(w), @floatFromInt(h));
    d3d11.bindTarget(g, dst);
    r.setBlend(false);
    r.setParams(.{ .w = @floatFromInt(w), .h = @floatFromInt(h) }, 1, p);
    g.slot(*const fn (*Com, ?*Com, ?*const anyopaque, u32) callconv(.winapi) void, VSSetShader)(g, pass_vs, null, 0);
    g.slot(*const fn (*Com, ?*Com, ?*const anyopaque, u32) callconv(.winapi) void, PSSetShader)(g, ps, null, 0);
    var srcs = [1]?*Com{src};
    g.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, PSSetShaderResources)(g, 0, 1, &srcs);
    g.slot(*const fn (*Com, u32, u32) callconv(.winapi) void, Draw)(g, 3, 0);
}
