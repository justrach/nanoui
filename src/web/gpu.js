import { createExternalSources } from "./external.js";
import { createTiming } from "./gpu_timing.js";
// Thin WebGPU imports. Decisions live in Zig; this module owns references.
export function createGPU({ device, memory, done, format = "bgra8unorm", generation = 1, asyncPipelines = false }) {
  const values = [null], generations = [0], serials = [0], free = [], frame = [], diagnostics = [], compilations = [];
  let serial = 0;
  const externalSources=createExternalSources();
  let onTiming = () => {};
  let timing = createTiming(device, sample=>onTiming(sample));
  const pipelineJobs=[];
  const formats = ["bgra8unorm", "rgba8unorm", "r8unorm", "rgba16float"];
  const objects = {
    put(value) {
      const h = free.pop() ?? values.length;
      values[h] = value;
      generations[h] = generation;
      serials[h] = ++serial;
      return h;
    },
    get(h) {
      if (!h || !values[h]) throw new Error(`Invalid WebGPU handle ${h}`);
      return values[h];
    },
    drop(h) {
      if (h && values[h]) { values[h] = null; free.push(h); }
    },
    get size() { return values.length - free.length - 1; },
  };
  let deviceHandle = objects.put(device);
  let canvasContext, copyExternal = false;
  const get = h => objects.get(h);
  const transient = value => { const h = objects.put(value); frame.push(h); return h; };
  const bytes = (ptr, len) => new Uint8Array(memory().buffer, ptr, len);
  const words = (ptr, len) => new Uint32Array(memory().buffer, ptr, len);
  device.addEventListener("uncapturederror", event => diagnostics.push(event.error.message));

  const imports = {
    device: () => deviceHandle,
    device_generation: () => generation,
    preferred_format: () => formats.indexOf(format),
    canvas_texture: () => transient(canvasContext.getCurrentTexture()),
    canvas_view: h => transient(get(h).createView()),
    release(h) { get(h).destroy?.(); objects.drop(h); },
    buffer_create: (size, usage) => objects.put(device.createBuffer({ size, usage })),
    buffer_write(h, offset, ptr, len) { timing.upload(len); device.queue.writeBuffer(get(h), offset, bytes(ptr, len)); },
    texture_create(ptr) {
      const [width, height, f, usage, depth, dimension] = words(ptr, 6);
      return objects.put(device.createTexture({ size: [width, height, depth], dimension: dimension === 3 ? "3d" : "2d", format: formats[f], usage }));
    },
    texture_write(h, ptr, src, len) {
      const [width, height, bytesPerRow, depth, x, y] = words(ptr, 6);
      timing.upload(len);
      device.queue.writeTexture({ texture: get(h), origin:[x,y,0] }, bytes(src, len), { bytesPerRow, rowsPerImage: height }, [width, height, depth]);
    },
    texture_view: h => objects.put(get(h).createView()),
    texture_srgb: h => get(h).format.endsWith("-srgb"),
    texture_format: h => get(h).format.endsWith("-srgb") ? 3 : Math.max(0, formats.indexOf(get(h).format)),
    resource_generation: h => values[h] ? generations[h] : 0,
    resource_serial: h => values[h] ? serials[h] : 0,
    external_import(h) {
      const source = get(h);
      // A media element can decode on a different graphics backend. Chromium
      // may return an invalid external texture instead of throwing, so use the
      // normalized copy for HTML video. VideoFrame sources keep direct import.
      if (copyExternal || (typeof HTMLVideoElement !== "undefined" && source instanceof HTMLVideoElement)) return 0;
      try { return transient(device.importExternalTexture({ source: externalSources.get(source) })); }
      catch { return 0; }
    },
    external_copy(h, texture) {
      try { device.queue.copyExternalImageToTexture({ source: externalSources.get(get(h), true) }, { texture: get(texture) }, [get(texture).width, get(texture).height]); return 1; }
      catch { return 0; }
    },
    sampler_create(filter) {
      const f = filter ? "linear" : "nearest";
      return objects.put(device.createSampler({ minFilter: f, magFilter: f }));
    },
    shader_create(ptr, len) {
      // slice also supports a future shared WebAssembly.Memory.
      const code = new TextDecoder().decode(bytes(ptr, len).slice());
      const shader = device.createShaderModule({ code });
      const shaderGeneration = generation;
      compilations.push(shader.getCompilationInfo().then(info => {
        if (shaderGeneration !== generation) return;
        for (const m of info.messages) diagnostics.push(`${m.type} ${m.lineNum}:${m.linePos}: ${m.message}`);
      }));
      return objects.put(shader);
    },
    layout_create(ptr, count) {
      const data = words(ptr, count * 3), entries = [];
      for (let i = 0; i < count; i++) {
        const [binding, visibility, kind] = data.subarray(i * 3, i * 3 + 3);
        const e = { binding, visibility };
        if (kind === 0) e.buffer = { type: "uniform", hasDynamicOffset: true, minBindingSize: 256 };
        if (kind === 1) e.buffer = { type: "read-only-storage" };
        if (kind === 2) e.texture = { sampleType: "float" };
        if (kind === 3) e.sampler = { type: "filtering" };
        if (kind === 4) e.externalTexture = {};
        if (kind === 5) e.texture = { sampleType: "float", viewDimension: "3d" };
        if (kind === 6) e.sampler = { type: "non-filtering" };
        entries.push(e);
      }
      return objects.put(device.createBindGroupLayout({ entries }));
    },
    pipeline_create(ptr) {
      const [shader, layout, f, kind, sampleLayout] = words(ptr, 5);
      const blend = { srcFactor: kind === 1 ? "zero" : "one", dstFactor: "one-minus-src-alpha", operation: "add" };
      const desc = {
        layout: device.createPipelineLayout({ bindGroupLayouts: [get(layout), ...(sampleLayout ? [get(sampleLayout)] : [])] }),
        vertex: { module: get(shader), entryPoint: kind === 3 || kind === 4 || kind >= 8 ? "pass_vs" : "quad_vs" },
        fragment: { module: get(shader), entryPoint: ({0:"quad_fs",1:"quad_fs",2:"glass_fs",3:"down_fs",4:"blur_fs",5:"external_fs",8:"post_fs",9:"post_external_fs"})[kind], targets: [{ format: formats[f], blend: kind === 3 || kind === 4 || kind >= 8 ? undefined : { color: blend, alpha: blend } }] },
        primitive: { topology: kind === 3 || kind === 4 || kind >= 8 ? "triangle-list" : "triangle-strip" },
      };
      if(!asyncPipelines)return objects.put(device.createRenderPipeline(desc));
      const handle=objects.put({pending:true}), ticket=serials[handle], deviceGeneration=generation;
      pipelineJobs.push(device.createRenderPipelineAsync(desc).then(pipeline=>{
        if(values[handle] && serials[handle]===ticket)values[handle]=pipeline;
      },error=>{if(deviceGeneration===generation)diagnostics.push(error.message);}));
      return handle;
    },
    bind_group_create(layout, ptr, count) {
      const data = words(ptr, count * 5), entries = [];
      for (let i = 0; i < count; i++) {
        const [binding, kind, h, offset, size] = data.subarray(i * 5, i * 5 + 5);
        const resource = kind === 0 ? { buffer: get(h), offset, ...(size ? { size } : {}) } : get(h);
        entries.push({ binding, resource });
      }
      return objects.put(device.createBindGroup({ layout: get(layout), entries }));
    },
    encoder_begin: () => { timing.begin(); return transient(device.createCommandEncoder()); },
    pass_begin(enc, view, load, r, g, b, a) {
      return transient(get(enc).beginRenderPass({ timestampWrites:timing.writes(), colorAttachments: [{
        view: get(view), loadOp: load ? "load" : "clear", storeOp: "store", clearValue: [r, g, b, a],
      }] }));
    },
    pass_set_pipeline(pass, pipeline) { get(pass).setPipeline(get(pipeline)); },
    pass_set_bind_group(pass, index, group, offset) { get(pass).setBindGroup(index, get(group), offset === -1 || offset === 0xffffffff ? [] : [offset]); },
    pass_draw(pass, vertices, instances, first) { timing.draw(); get(pass).draw(vertices, instances, 0, first); },
    pass_end(pass) { get(pass).end(); },
    pass_viewport(pass, width, height) { get(pass).setViewport(0, 0, width, height, 0, 1); },
    encoder_submit(enc) {
      try { timing.resolve(get(enc)); device.queue.submit([get(enc).finish()]); timing.submit(); }
      finally { externalSources.submitted(); for (const h of frame) objects.drop(h); frame.length = 0; }
    },
    read_begin(tex, width, height, f, dest, token) {
      (async () => {
        const pitch = Math.ceil(width * 4 / 256) * 256;
        const buffer = device.createBuffer({ size: pitch * height, usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ });
        try {
          const encoder = device.createCommandEncoder();
          encoder.copyTextureToBuffer({ texture: get(tex) }, { buffer, bytesPerRow: pitch }, [width, height]);
          device.queue.submit([encoder.finish()]);
          await buffer.mapAsync(GPUMapMode.READ);
          const src = new Uint8Array(buffer.getMappedRange());
          const dst = bytes(dest, width * height * 4);
          for (let y = 0; y < height; y++) dst.set(src.subarray(y * pitch, y * pitch + width * 4), y * width * 4);
          if (f === 1) for (let i = 0; i < dst.length; i += 4) [dst[i], dst[i + 2]] = [dst[i + 2], dst[i]];
          buffer.unmap();
        } finally { buffer.destroy(); }
      })().then(() => done(token, 0), error => {
        diagnostics.push(`Readback: ${error.message}`);
        done(token, 1);
      });
    },
  };
  return {
    imports, objects, diagnostics,
    get device() { return device; },
    get generation() { return generation; },
    get stats() { return timing.stats; },
    onTiming(callback) { onTiming=callback; },
    async ready() { await Promise.all([...compilations,...pipelineJobs]); if(diagnostics.length)throw Error(diagnostics.join("\n")); },
    dispose() { timing.destroy(); externalSources.destroy(); },
    forceExternalCopy(on) { copyExternal = on; },
    setCanvas(context) { canvasContext = context; },
    setDevice(next) {
      externalSources.destroy();
      timing.destroy(); timing=createTiming(next,sample=>onTiming(sample));
      objects.drop(deviceHandle);
      device = next;
      generation++;
      diagnostics.length=0;
      deviceHandle = objects.put(next);
      next.addEventListener("uncapturederror", event => diagnostics.push(event.error.message));
    },
    async check() {
      await this.ready();
      await device.queue.onSubmittedWorkDone();
      if (diagnostics.length) throw new Error(diagnostics.join("\n"));
    },
  };
}
