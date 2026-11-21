//! The host owns device acquisition and recovery, including injected devices.
const api = @import("webgpu_api.zig");
pub fn get() ?api.Handle {
    const h = api.device();
    return if (h == 0) null else h;
}
pub fn generation() u32 {
    return api.device_generation();
}
