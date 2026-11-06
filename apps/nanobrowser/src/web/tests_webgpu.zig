//! Headless end-to-end tests: JS promises, real Metal results, canvas pixels.
const std = @import("std");
const testing = std.testing;
const u = @import("tests_util.zig");
const gpu = @import("../gpu/context.zig");
comptime {
    _ = @import("../gpu/tests_native.zig");
}

fn start(r: *u.Run) !void {
    if (!gpu.supported) return error.SkipZigTest;
    try r.start();
    errdefer r.stop();
    try r.html("<!doctype html><canvas id=c width=32 height=32></canvas>");
    if (std.mem.eql(u8, try r.eval("typeof navigator.gpu"), "undefined")) return error.SkipZigTest;
    _ = try r.eval("var device, done=false, failure=''; navigator.gpu.requestAdapter().then(a=>a.requestDevice()).then(d=>{device=d;done=true}).catch(e=>{failure=String(e);done=true})");
    try r.waitJs("done");
    try r.expectJs("failure", "");
    _ = try r.eval("device.onuncapturederror=e=>{failure+=e.error.message+';'}");
}

test "WebGPU JS real compute queue submit map readback and resource validation" {
    var r: u.Run = undefined;
    try start(&r);
    defer r.stop();
    _ = try r.eval(
        \\var module = device.createShaderModule({code:'@group(0) @binding(0) var<storage,read_write> data: array<f32>; @compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id: vec3u) { if(id.x < arrayLength(&data)){data[id.x] = data[id.x] * 2.0;} }'});
        \\var pipeline = device.createComputePipeline({layout:'auto', compute:{module,entryPoint:'main'}});
        \\var input = device.createBuffer({size:16, usage:GPUBufferUsage.STORAGE|GPUBufferUsage.COPY_SRC|GPUBufferUsage.COPY_DST});
        \\var output = device.createBuffer({size:16, usage:GPUBufferUsage.MAP_READ|GPUBufferUsage.COPY_DST});
        \\device.queue.writeBuffer(input,0,new Float32Array([1,-2,3.5,0.25]));
        \\var group = device.createBindGroup({layout:pipeline.getBindGroupLayout(0),entries:[{binding:0,resource:{buffer:input}}]});
        \\var encoder = device.createCommandEncoder(), pass = encoder.beginComputePass();
        \\pass.setPipeline(pipeline); pass.setBindGroup(0,group); pass.dispatchWorkgroups(4); pass.end();
        \\encoder.copyBufferToBuffer(input,0,output,0,16); var commands=encoder.finish(); device.queue.submit([commands]);
        \\done=false; var result=''; output.mapAsync(GPUMapMode.READ).then(()=>{result=Array.from(new Float32Array(output.getMappedRange())).join(','); output.unmap();done=true}).catch(e=>{failure=String(e);done=true});
    );
    try r.waitJs("done");
    try r.expectJs("failure", "");
    try r.expectJs("result", "2,-4,7,0.5");
    try r.expectJs("output.mapState", "unmapped");
    _ = try r.eval("device.pushErrorScope('validation');device.queue.submit([commands]);var scoped='';device.popErrorScope().then(e=>scoped=e&&e.message)");
    try r.waitJs("scoped");
    try r.expectJs("scoped.includes('already submitted')", "true");
    _ = try r.eval("var mapped=device.createBuffer({size:16,usage:GPUBufferUsage.COPY_SRC,mappedAtCreation:true});var range=mapped.getMappedRange();new Uint32Array(range)[0]=123;mapped.unmap()");
    try r.expectJs("range.byteLength", "0");
    _ = try r.eval("var me=device.createCommandEncoder();me.copyBufferToBuffer(mapped,0,output,0,16);device.queue.submit([me.finish()]);done=false;var mappedResult=0;output.mapAsync(1).then(()=>{mappedResult=new Uint32Array(output.getMappedRange())[0];output.unmap();done=true})");
    try r.waitJs("done");
    try r.expectJs("mappedResult", "123");
    // A missing shader binding invalidates the entire submission, not just the
    // dispatch after this copy. Readback must still contain the mapped upload.
    _ = try r.eval("device.pushErrorScope('validation');var be=device.createCommandEncoder();be.copyBufferToBuffer(input,0,output,0,16);var bp=be.beginComputePass();bp.setPipeline(pipeline);bp.dispatchWorkgroups(4);bp.end();device.queue.submit([be.finish()]);scoped='';device.popErrorScope().then(e=>scoped=e&&e.message)");
    try r.waitJs("scoped");
    _ = try r.eval("done=false;output.mapAsync(1).then(()=>{mappedResult=new Uint32Array(output.getMappedRange())[0];output.unmap();done=true})");
    try r.waitJs("done");
    try r.expectJs("mappedResult", "123");
    _ = try r.eval("device.pushErrorScope('validation');input.destroy();device.queue.writeBuffer(input,0,new Float32Array([9]));scoped='';device.popErrorScope().then(e=>scoped=e&&e.message)");
    try r.waitJs("scoped");
    try r.expectJs("scoped.includes('destroyed')", "true");
    try r.expectNoErrors();
}

test "WebGPU shader diagnostics and error scopes never fake a pipeline" {
    var r: u.Run = undefined;
    try start(&r);
    defer r.stop();
    _ = try r.eval(
        \\device.pushErrorScope('validation');
        \\var bad=device.createShaderModule({code:'@compute @workgroup_size(1) fn main(){loop{}}'});
        \\var messages='', scoped=''; bad.getCompilationInfo().then(i=>messages=i.messages.map(m=>m.message).join(';'));
        \\device.popErrorScope().then(e=>scoped=e&&e.message);
    );
    try r.waitJs("messages && scoped");
    try r.expectJs("messages.includes('unsupported') && scoped.includes('WGSL')", "true");
    _ = try r.eval("device.pushErrorScope('validation');var rejected='';device.createComputePipelineAsync({layout:'auto',compute:{module:bad,entryPoint:'main'}}).catch(e=>rejected=e.message);device.popErrorScope()");
    try r.waitJs("rejected");
    try r.expectJs("rejected.includes('failed')", "true");
    try r.expectNoErrors();
}

test "WebGPU canvas real triangle BGRA top-row pixels resize and unconfigure" {
    var r: u.Run = undefined;
    try start(&r);
    defer r.stop();
    _ = try r.eval(
        \\var context=c.getContext('webgpu');
        \\context.configure({device,format:navigator.gpu.getPreferredCanvasFormat(),alphaMode:'opaque'});
        \\var shader=device.createShaderModule({code:'@vertex fn vs(@builtin(vertex_index) i:u32)->@builtin(position) vec4f {let p=array<vec2f,3>(vec2f(-0.8,-0.8),vec2f(0.8,-0.8),vec2f(0,0.8));return vec4f(p[i],0,1);}@fragment fn fs()->@location(0) vec4f{return vec4f(1,0,0,1);}'});
        \\var pipeline=device.createRenderPipeline({layout:'auto',vertex:{module:shader,entryPoint:'vs'},fragment:{module:shader,entryPoint:'fs',targets:[{format:'bgra8unorm'}]}});
        \\function renderTriangle(){var e=device.createCommandEncoder();var p=e.beginRenderPass({colorAttachments:[{view:context.getCurrentTexture().createView(),loadOp:'clear',storeOp:'store',clearValue:[0,0,1,1]}]});p.setPipeline(pipeline);p.draw(3);p.end();device.queue.submit([e.finish()]);}
        \\renderTriangle();
    );
    try r.expectJs("context===c.getContext('webgpu')", "true");
    const page = r.page();
    try testing.expectEqual(@as(usize, 1), page.gpu.canvases.items.len);
    const node = page.gpu.canvases.items[0].node;
    const pixels = page.canvases.pixelsOf(node) orelse return error.TestFailed;
    try testing.expectEqual(@as(u32, 32), pixels.width);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, pixels.bgra[(16 * 32 + 16) * 4 ..][0..4]);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, pixels.bgra[0..4]);
    _ = try r.eval("c.width=64;renderTriangle()");
    const resized = page.canvases.pixelsOf(node) orelse return error.TestFailed;
    try testing.expectEqual(@as(u32, 64), resized.width);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, resized.bgra[(16 * 64 + 32) * 4 ..][0..4]);
    _ = try r.eval("context.unconfigure()");
    try testing.expect(page.canvases.pixelsOf(node) == null);
    _ = try r.eval("context.configure({device,format:'bgra8unorm'});renderTriangle()");
    try testing.expect(page.canvases.pixelsOf(node) != null);
    _ = try r.eval("device.pushErrorScope('validation');context.configure({device,format:'rgba16float'});var scoped='';device.popErrorScope().then(e=>scoped=e&&e.message)");
    try r.waitJs("scoped");
    try r.expectJs("context.getConfiguration()", "null");
    try testing.expect(page.canvases.pixelsOf(node) == null);
    try r.expectNoErrors();
}

test "WebGPU unsupported platforms do not expose navigator.gpu" {
    if (gpu.supported) return error.SkipZigTest;
    var r: u.Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><p>GPU capability</p>");
    try r.expectJs("typeof navigator.gpu", "undefined");
}
