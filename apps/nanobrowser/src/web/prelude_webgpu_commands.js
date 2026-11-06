// Command recording, validation before submission, offscreen render targets.
(function ($, globalThis) {
  'use strict';
  if (!$.wg) return;
  const { state, get, own, fail, uint, attempt } = $.wg;
  function record(o, kind, fn) {
    const s = state.get(o), d = s.device;
    return attempt(d, () => {
      get(o, kind, d);
      if (s.finished || s.invalid) fail('Encoder already finished or invalid');
      try { return fn(s); } catch (e) { s.invalid = true; throw e; }
    }, null);
  }
  function usableBuffer(o, d) {
    const b = get(o, 'buffer', d);
    if (!b.id || b.map !== 'unmapped') fail('Buffer is invalid or mapped');
    return b;
  }
  class GPUCommandEncoder {
    beginComputePass(desc = {}) {
      return record(this, 'encoder', s => {
        if (s.pass || desc.timestampWrites) fail('Encoder locked or timestamps unsupported');
        const p = own(new GPUComputePassEncoder(), 'computePass', s.device, { encoder: this, commands: [], pipeline: null, group: null });
        s.pass = p; return p;
      });
    }
    beginRenderPass(desc) {
      return record(this, 'encoder', s => {
        if (s.pass || desc.depthStencilAttachment || desc.occlusionQuerySet || desc.timestampWrites) fail('Unsupported render pass attachment or encoder locked');
        if (!desc.colorAttachments || desc.colorAttachments.length !== 1) fail('Exactly one color attachment supported');
        const a = desc.colorAttachments[0], v = get(a.view, 'view', s.device), t = get(v.texture, 'texture', s.device);
        if (!(t.usage & 16) || a.resolveTarget || !['clear', 'load'].includes(a.loadOp) || a.storeOp !== 'store') fail('Unsupported color attachment operation');
        let clear = null;
        if (a.loadOp === 'clear') {
          const c = a.clearValue || [0, 0, 0, 0];
          clear = Array.isArray(c) ? c.slice() : [c.r, c.g, c.b, c.a];
          if (clear.length !== 4 || clear.some(n => !Number.isFinite(Number(n)))) fail('Invalid clear color');
        }
        const p = own(new GPURenderPassEncoder(), 'renderPass', s.device, { encoder: this, texture: v.texture, clear, commands: [], pipeline: null, group: null });
        s.pass = p; return p;
      });
    }
    copyBufferToBuffer(src, so, dst, offset, size) {
      record(this, 'encoder', s => {
        if (s.pass) fail('Encoder locked by pass');
        s.commands.push({ kind: 'copy', src, so: uint(so), dst, offset: uint(offset), size: uint(size) });
      });
    }
    finish(desc = {}) {
      const s = state.get(this);
      const result = own(new GPUCommandBuffer(), 'commands', s.device, { commands: [], valid: false, used: false });
      result.label = String(desc.label || '');
      record(this, 'encoder', e => {
        if (e.pass) fail('Pass must end before encoder finishes');
        state.get(result).commands = e.commands.slice(); state.get(result).valid = true; e.finished = true;
      }); return result;
    }
    clearBuffer() { record(this, 'encoder', () => fail('clearBuffer unsupported; use writeBuffer')); }
    copyTextureToBuffer() { record(this, 'encoder', () => fail('Texture copies unsupported')); }
    copyBufferToTexture() { record(this, 'encoder', () => fail('Texture copies unsupported')); }
    copyTextureToTexture() { record(this, 'encoder', () => fail('Texture copies unsupported')); }
  }
  class GPUCommandBuffer {}
  function endPass(p, kind) {
    record(p, kind, s => {
      const e = get(s.encoder, 'encoder', s.device);
      if (e.pass !== p || e.finished) fail('Pass is not active');
      e.commands.push({ kind: kind === 'computePass' ? 'compute' : 'render', pass: s });
      e.pass = null; s.finished = true;
    });
  }
  class GPUComputePassEncoder {
    setPipeline(p) { record(this, 'computePass', s => { get(p, 'compute', s.device); s.pipeline = p; }); }
    setBindGroup(index, group, dynamicOffsets = []) {
      record(this, 'computePass', s => {
        if (index !== 0 || dynamicOffsets.length) fail('Only bind group 0 without dynamic offsets supported');
        get(group, 'bindgroup', s.device); s.group = group;
      });
    }
    dispatchWorkgroups(x, y = 1, z = 1) {
      record(this, 'computePass', s => {
        if (!s.pipeline) fail('No compute pipeline');
        s.commands.push({ pipeline: s.pipeline, group: s.group, groups: [uint(x, 65535), uint(y, 65535), uint(z, 65535)] });
      });
    }
    dispatchWorkgroupsIndirect() { record(this, 'computePass', () => fail('Indirect dispatch unsupported')); }
    end() { endPass(this, 'computePass'); }
  }
  class GPURenderPassEncoder {
    setPipeline(p) { record(this, 'renderPass', s => { get(p, 'render', s.device); s.pipeline = p; }); }
    draw(vertexCount, instanceCount = 1, firstVertex = 0, firstInstance = 0) {
      record(this, 'renderPass', s => {
        if (!s.pipeline || instanceCount !== 1 || firstInstance !== 0) fail('Only non-instanced draws supported');
        s.commands.push({ pipeline: s.pipeline, group: s.group, count: uint(vertexCount, 65535), first: uint(firstVertex, 65535) });
      });
    }
    setVertexBuffer() { record(this, 'renderPass', () => fail('Vertex buffers unsupported; use vertex_index')); }
    setIndexBuffer() { record(this, 'renderPass', () => fail('Index buffers unsupported')); }
    setBindGroup(index, group, dynamicOffsets = []) {
      record(this, 'renderPass', s => {
        if (index !== 0 || dynamicOffsets.length) fail('Only bind group 0 without dynamic offsets supported');
        get(group, 'bindgroup', s.device); s.group = group;
      });
    }
    drawIndexed() { record(this, 'renderPass', () => fail('Indexed rendering unsupported')); }
    setViewport() { record(this, 'renderPass', () => fail('Custom viewports unsupported')); }
    setScissorRect() { record(this, 'renderPass', () => fail('Scissor rectangles unsupported')); }
    end() { endPass(this, 'renderPass'); }
  }
  class GPURenderPipeline {
    getBindGroupLayout(index) { return $.wg.getBindGroupLayout(this, index, 'render'); }
  }
  class GPUTexture {
    get width() { return state.get(this).width; }
    get height() { return state.get(this).height; }
    get depthOrArrayLayers() { return 1; }
    get mipLevelCount() { return 1; }
    get sampleCount() { return 1; }
    get dimension() { return '2d'; }
    get format() { return 'bgra8unorm'; }
    get usage() { return state.get(this).usage; }
    createView(desc = {}) {
      const s = state.get(this);
      return attempt(s.device, () => {
        get(this, 'texture');
        for (const k of Object.keys(desc)) if (k !== 'label') fail('Nondefault texture views unsupported');
        return own(new GPUTextureView(), 'view', s.device, { texture: this });
      }, null);
    }
    destroy() { const s = state.get(this); if (s.dead) return; $.gpuDestroy(s.id); s.dead = true; }
  }
  class GPUTextureView {}
  $.wg.createTexture = (d, desc) => {
    const t = own(new GPUTexture(), 'texture', d, { width: 0, height: 0, usage: 0 });
    t.label = String(desc.label || ''); const s = state.get(t);
    s.id = attempt(d, () => {
      const size = desc.size, arr = Array.isArray(size);
      s.width = uint(arr ? size[0] : size.width, 4096);
      s.height = uint((arr ? size[1] : size.height) === undefined ? 1 : (arr ? size[1] : size.height), 4096);
      const depth = arr ? size[2] : size.depthOrArrayLayers;
      s.usage = uint(desc.usage);
      if (desc.format !== 'bgra8unorm' || (desc.dimension && desc.dimension !== '2d') || (depth !== undefined && depth !== 1) ||
          (desc.mipLevelCount !== undefined && desc.mipLevelCount !== 1) || (desc.sampleCount !== undefined && desc.sampleCount !== 1) ||
          (desc.viewFormats && desc.viewFormats.length) || s.usage !== 16) fail('Only single-layer bgra8unorm RENDER_ATTACHMENT textures supported');
      return $.gpuTexture(s.width, s.height);
    }); return t;
  };
  $.wg.createRenderPipeline = (d, desc) => {
    const p = own(new GPURenderPipeline(), 'render', d); p.label = String(desc.label || '');
    state.get(p).id = attempt(d, () => {
      const v = desc.vertex, f = desc.fragment, primitive = desc.primitive || {}, ms = desc.multisample || {};
      if (!v || !f || desc.depthStencil || (v.buffers && v.buffers.length) ||
          (v.constants && Object.keys(v.constants).length) || (f.constants && Object.keys(f.constants).length) ||
          (primitive.topology && primitive.topology !== 'triangle-list') || (primitive.cullMode && primitive.cullMode !== 'none') ||
          (primitive.frontFace && primitive.frontFace !== 'ccw') || primitive.stripIndexFormat || primitive.unclippedDepth ||
          (ms.count !== undefined && ms.count !== 1) || ms.alphaToCoverageEnabled || (ms.mask !== undefined && ms.mask !== 0xffffffff))
        fail('Unsupported render pipeline state');
      if (!f.targets || f.targets.length !== 1 || f.targets[0].format !== 'bgra8unorm' || f.targets[0].blend ||
          (f.targets[0].writeMask !== undefined && f.targets[0].writeMask !== 15)) fail('Only one unblended bgra8unorm target supported');
      $.wg.pipelineLayout(d, p, desc.layout, [Object.assign({}, v, { visibility: 1 }), Object.assign({}, f, { visibility: 2 })]);
      return $.gpuRender(get(v.module, 'shader', d).id, String(v.entryPoint || 'main'), get(f.module, 'shader', d).id, String(f.entryPoint || 'main'));
    }); return p;
  };
  $.wg.encoder = (d, desc) => {
    get(d, 'device');
    const e = own(new GPUCommandEncoder(), 'encoder', d, { commands: [], pass: null }); e.label = String(desc.label || ''); return e;
  };
  $.wg.submit = (d, buffers) => attempt(d, () => {
    const all = Array.from(buffers), seen = new Set();
    for (const b of all) {
      const s = get(b, 'commands', d);
      if (!s.valid || s.used || seen.has(b)) fail('Invalid or already submitted command buffer');
      seen.add(b);
      for (const c of s.commands) {
        if (c.kind === 'copy') {
          const src = usableBuffer(c.src, d), dst = usableBuffer(c.dst, d);
          if (c.src === c.dst || !(src.usage & 4) || !(dst.usage & 8) || (c.so | c.offset | c.size) % 4 ||
              c.so + c.size > src.size || c.offset + c.size > dst.size) fail('Invalid buffer copy');
        } else {
          const pass = c.pass; if (pass.invalid) fail('Invalid pass encoder');
          if (c.kind === 'render' && !get(pass.texture, 'texture', d).id) fail('Invalid texture');
          for (const cmd of pass.commands) {
            if (!get(cmd.pipeline, c.kind === 'compute' ? 'compute' : 'render', d).id) fail('Invalid pipeline');
            const ids = $.wg.bindingIds(d, cmd.pipeline, cmd.group);
            if (c.kind === 'compute') $.gpuValidateDispatch(state.get(cmd.pipeline).id, ids, cmd.groups[0], cmd.groups[1], cmd.groups[2]);
            else $.gpuValidateRenderBindings(state.get(cmd.pipeline).id, ids);
          }
        }
      }
    }
    // All commands, including native shader-reflected bindings, have been
    // validated before the first GPU write.
    for (const b of all) {
      const s = state.get(b); s.used = true;
      for (const c of s.commands) {
        if (c.kind === 'copy') $.gpuCopy(state.get(c.src).id, c.so, state.get(c.dst).id, c.offset, c.size);
        else if (c.kind === 'compute') {
          for (const cmd of c.pass.commands) {
            const ids = $.wg.bindingIds(d, cmd.pipeline, cmd.group);
            $.gpuDispatch(state.get(cmd.pipeline).id, ids, cmd.groups[0], cmd.groups[1], cmd.groups[2]);
          }
        } else {
          const pass = c.pass, id = state.get(pass.texture).id;
          if (pass.clear) $.gpuDraw(id, 0, 0, 0, pass.clear);
          for (const cmd of pass.commands) $.gpuDraw(id, state.get(cmd.pipeline).id, cmd.count, cmd.first, null, $.wg.bindingIds(d, cmd.pipeline, cmd.group));
        }
      }
    }
  });
  const contexts = new WeakMap();
  class GPUCanvasContext {
    get canvas() { return state.get(this).canvas; }
    configure(desc) {
      const s = state.get(this), d = desc.device;
      get(d, 'device'); this.unconfigure();
      attempt(d, () => {
        if (desc.format !== 'bgra8unorm' || (desc.usage !== undefined && desc.usage !== 16) || (desc.viewFormats && desc.viewFormats.length) ||
            (desc.alphaMode && !['opaque', 'premultiplied'].includes(desc.alphaMode)) ||
            (desc.colorSpace && desc.colorSpace !== 'srgb') || desc.toneMapping) fail('Unsupported canvas configuration');
        s.config = { device: d, format: 'bgra8unorm', usage: 16, alphaMode: desc.alphaMode || 'opaque', colorSpace: 'srgb' };
      });
    }
    unconfigure() {
      const s = state.get(this); if (s.texture) s.texture.destroy(); s.texture = null; s.config = null; $.gpuUnconfigure(s.canvas);
    }
    getConfiguration() { const s = state.get(this); return s.config ? Object.assign({}, s.config) : null; }
    getCurrentTexture() {
      const s = state.get(this), cfg = s.config;
      if (!cfg) throw new DOMException('Canvas is not configured', 'InvalidStateError');
      const width = uint(s.canvas.width, 4096), height = uint(s.canvas.height, 4096);
      if (!width || !height) fail('Zero-sized canvas');
      if (!s.texture || state.get(s.texture).dead || s.texture.width !== width || s.texture.height !== height) {
        if (s.texture) s.texture.destroy();
        s.texture = cfg.device.createTexture({ size: [width, height], format: cfg.format, usage: 16 });
        $.gpuAttach(s.canvas, state.get(s.texture).id, cfg.alphaMode === 'opaque');
      }
      return s.texture;
    }
  }
  $.webgpuContext = canvas => {
    if (canvas.__nbContextKind && canvas.__nbContextKind !== 'webgpu') return null;
    if (contexts.has(canvas)) return contexts.get(canvas);
    canvas.__nbContextKind = 'webgpu';
    const c = new GPUCanvasContext(); state.set(c, { canvas, config: null, texture: null }); contexts.set(canvas, c); return c;
  };
  const previousGetContext = HTMLCanvasElement.prototype.getContext;
  Object.defineProperty(HTMLCanvasElement.prototype, 'getContext', {
    configurable: true, writable: true, enumerable: true,
    value: function (kind, ...args) {
      kind = String(kind);
      if (kind === 'webgpu') return $.webgpuContext(this);
      if (this.__nbContextKind === 'webgpu') return null;
      return previousGetContext.call(this, kind, ...args);
    }
  });
  const globals = { GPUCommandEncoder, GPUCommandBuffer, GPUComputePassEncoder, GPURenderPassEncoder, GPURenderPipeline, GPUTexture, GPUTextureView, GPUCanvasContext,
    GPUColorWrite: Object.freeze({ RED: 1, GREEN: 2, BLUE: 4, ALPHA: 8, ALL: 15 }) };
  for (const name of Object.keys(globals)) globalThis[name] = globals[name];
});
