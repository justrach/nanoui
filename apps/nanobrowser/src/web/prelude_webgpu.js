// A bounded, real Metal implementation. No capability is advertised without a
// device. State is private; native IDs never serve as public object authority.
(function ($, globalThis) {
  'use strict';
  if (!$.gpuAvailable()) return;
  const state = new WeakMap();
  class GPUValidationError extends Error { constructor(m) { super(m); this.name = 'GPUValidationError'; } }
  class GPUOutOfMemoryError extends Error { constructor(m) { super(m); this.name = 'GPUOutOfMemoryError'; } }
  class GPUInternalError extends Error { constructor(m) { super(m); this.name = 'GPUInternalError'; } }
  class GPUUncapturedErrorEvent extends Event { constructor(t, o) { super(t); this.error = o.error; } }
  const fail = m => { throw new GPUValidationError(m); };
  const uint = (v, max = 0xffffffff) => {
    v = Number(v);
    if (!Number.isInteger(v) || v < 0 || v > max) fail('Invalid unsigned integer or supported limit exceeded');
    return v;
  };
  function get(o, kind, device) {
    const s = state.get(o);
    if (!s || s.kind !== kind || (device && s.device !== device)) fail('Wrong GPU object or device');
    if (s.dead || (s.device && state.get(s.device).dead)) fail('GPU object or device was destroyed');
    return s;
  }
  function report(d, error) {
    const message = String(error.message || error);
    const e = error instanceof GPUValidationError ? error : message.startsWith('GPUOutOfMemoryError:') ? new GPUOutOfMemoryError(message) : message.startsWith('GPUInternalError:') ? new GPUInternalError(message) : new GPUValidationError(message);
    const filter = e instanceof GPUOutOfMemoryError ? 'out-of-memory' : e instanceof GPUInternalError ? 'internal' : 'validation';
    const s = state.get(d);
    if (filter === 'internal' && !s.dead) { s.lost({ reason: 'unknown', message }); d.destroy(); }
    for (let i = s.scopes.length - 1; i >= 0; --i) {
      if (s.scopes[i].filter === filter) { if (!s.scopes[i].error) s.scopes[i].error = e; return; }
    }
    d.dispatchEvent(new GPUUncapturedErrorEvent('uncapturederror', { error: e }));
    if (typeof d.onuncapturederror === 'function') d.onuncapturederror({ type: 'uncapturederror', error: e });
  }
  function attempt(d, fn, fallback = 0) {
    try { get(d, 'device'); return fn(); } catch (e) { report(d, e); return fallback; }
  }
  function own(o, kind, d, extra) {
    const s = Object.assign({ kind, device: d, id: 0, dead: false }, extra || {});
    state.set(o, s);
    if (d) state.get(d).resources.push(o);
    return o;
  }
  const limits = Object.freeze({ maxTextureDimension2D: 4096, maxBindGroups: 1,
    maxStorageBuffersPerShaderStage: 8, maxBufferSize: 67108864,
    maxUniformBuffersPerShaderStage: 8, maxUniformBufferBindingSize: 65536,
    maxStorageBufferBindingSize: 67108864, maxComputeInvocationsPerWorkgroup: 256,
    maxComputeWorkgroupSizeX: 256, maxComputeWorkgroupSizeY: 256,
    maxComputeWorkgroupSizeZ: 256, maxComputeWorkgroupsPerDimension: 65535 });
  class GPU {
    requestAdapter(o = {}) {
      if (o.forceFallbackAdapter) return Promise.resolve(null);
      return Promise.resolve(new GPUAdapter());
    }
    getPreferredCanvasFormat() { return 'bgra8unorm'; }
    wgslLanguageFeatures = new Set();
  }
  class GPUAdapter {
    features = new Set(); limits = limits; isFallbackAdapter = false;
    info = Object.freeze({ vendor: '', architecture: '', device: '', description: 'Metal (bounded WGSL subset)' });
    requestDevice(o = {}) {
      try {
        const s = state.get(this);
        if (s && s.requested) fail('Adapter already used to request a device');
        if (o.requiredFeatures && Array.from(o.requiredFeatures).length) fail('No optional GPU features supported');
        for (const k of Object.keys(o.requiredLimits || {}))
          if (!(k in limits) || uint(o.requiredLimits[k]) > limits[k]) fail('Requested device limit is unsupported');
        state.set(this, { requested: true });
        return Promise.resolve(new GPUDevice(o.label || ''));
      } catch (e) { return Promise.reject(e); }
    }
  }
  class GPUDevice extends EventTarget {
    constructor(label) {
      super(); this.label = label; this.features = new Set(); this.limits = limits;
      state.set(this, { kind: 'device', scopes: [], resources: [], dead: false });
      this.lost = new Promise(resolve => { state.get(this).lost = resolve; });
      this.queue = new GPUQueue(this);
    }
    destroy() {
      const s = state.get(this); if (s.dead) return;
      for (const o of s.resources) {
        const r = state.get(o); if (r.id) $.gpuDestroy(r.id);
        if (r.ranges) for (const range of r.ranges) $.gpuDetach(range.buffer);
        r.dead = true;
      }
      s.dead = true; s.lost({ reason: 'destroyed', message: 'Device destroyed' });
    }
    pushErrorScope(filter) {
      if (!['validation', 'out-of-memory', 'internal'].includes(filter)) throw new TypeError('Invalid GPU error filter');
      state.get(this).scopes.push({ filter, error: null });
    }
    popErrorScope() {
      const s = state.get(this).scopes.pop();
      return s ? Promise.resolve(s.error) : Promise.reject(new DOMException('No error scope', 'OperationError'));
    }
    createBuffer(desc) {
      const b = own(new GPUBuffer(), 'buffer', this, { size: 0, usage: 0, map: 'unmapped', ranges: [] });
      const s = state.get(b); b.label = String(desc.label || '');
      s.id = attempt(this, () => {
        s.size = uint(desc.size, limits.maxBufferSize); s.usage = uint(desc.usage, 1023);
        if ((s.usage & 1) && (s.usage & ~9)) fail('MAP_READ may only combine with COPY_DST');
        if ((s.usage & 2) && (s.usage & ~6)) fail('MAP_WRITE may only combine with COPY_SRC');
        if (desc.mappedAtCreation && s.size % 4) fail('Mapped buffer size must be 4-byte aligned');
        return $.gpuBuffer(s.size, s.usage);
      });
      if (desc.mappedAtCreation && s.id) { s.map = 'mapped'; s.mode = 2; s.mapOffset = 0; s.mapSize = s.size; }
      return b;
    }
    createShaderModule(desc) {
      const m = own(new GPUShaderModule(), 'shader', this, { messages: [] }); m.label = String(desc.label || '');
      const s = state.get(m);
      s.id = attempt(this, () => {
        if (desc.compilationHints && desc.compilationHints.length) fail('Compilation hints unsupported');
        try { return $.gpuShader(String(desc.code)); }
        catch (e) {
          s.messages.push({ message: String(e.message), type: 'error', lineNum: 0, linePos: 0, offset: 0, length: 0 });
          throw e;
        }
      });
      return m;
    }
    createComputePipeline(desc) {
      const p = own(new GPUComputePipeline(), 'compute', this); p.label = String(desc.label || '');
      const s = state.get(p);
      s.id = attempt(this, () => {
        if (desc.compute.constants && Object.keys(desc.compute.constants).length) fail('Pipeline constants unsupported');
        const m = get(desc.compute.module, 'shader', this);
        $.wg.pipelineLayout(this, p, desc.layout, [Object.assign({}, desc.compute, { visibility: 4 })]);
        return $.gpuCompute(m.id, String(desc.compute.entryPoint || 'main'));
      }); return p;
    }
    createComputePipelineAsync(desc) {
      const p = this.createComputePipeline(desc);
      return state.get(p).id ? Promise.resolve(p) : Promise.reject(new GPUValidationError('Compute pipeline compilation failed'));
    }
    createRenderPipeline(desc) { return $.wg.createRenderPipeline(this, desc); }
    createRenderPipelineAsync(desc) {
      const p = this.createRenderPipeline(desc);
      return state.get(p).id ? Promise.resolve(p) : Promise.reject(new GPUValidationError('Render pipeline compilation failed'));
    }
    createBindGroup(desc) { return $.wg.createBindGroup(this, desc); }
    createTexture(desc) { return $.wg.createTexture(this, desc); }
    createCommandEncoder(desc = {}) { return $.wg.encoder(this, desc); }
    createBindGroupLayout(desc) { return $.wg.createBindGroupLayout(this, desc); }
    createPipelineLayout(desc) { return $.wg.createPipelineLayout(this, desc); }
    createSampler() { attempt(this, () => fail('Sampling unsupported')); return own({}, 'invalid', this); }
    createQuerySet() { attempt(this, () => fail('Queries unsupported')); return own({}, 'invalid', this); }
  }
  class GPUBuffer {
    get size() { return state.get(this).size; }
    get usage() { return state.get(this).usage; }
    get mapState() { const s = state.get(this); return s.dead ? 'unmapped' : s.map; }
    mapAsync(mode, offset = 0, size) {
      let s;
      try {
        s = get(this, 'buffer'); offset = uint(offset); size = size === undefined ? s.size - offset : uint(size);
        if (!s.id || s.map !== 'unmapped' || (mode !== 1 && mode !== 2) || !(s.usage & mode)) fail('Invalid mapping state or usage');
        if (offset % 8 || size % 4 || offset > s.size || size > s.size - offset) fail('Invalid mapping alignment or range');
        s.map = 'pending'; s.mode = mode; s.mapOffset = offset; s.mapSize = size;
        const token = {}; s.pending = token;
        return Promise.resolve().then(() => {
          if (s.dead || s.map !== 'pending' || s.pending !== token) throw new DOMException('Mapping cancelled', 'AbortError');
          s.map = 'mapped';
        });
      } catch (e) { if (s) report(s.device, e); return Promise.reject(e); }
    }
    getMappedRange(offset = 0, size) {
      const s = get(this, 'buffer'); offset = uint(offset); size = size === undefined ? s.size - offset : uint(size);
      if (s.map !== 'mapped' || offset % 8 || size % 4 || offset < s.mapOffset || offset + size > s.mapOffset + s.mapSize)
        throw new DOMException('Invalid mapped range', 'OperationError');
      for (const r of s.ranges) if (offset < r.offset + r.size && r.offset < offset + size)
        throw new DOMException('Mapped ranges overlap', 'OperationError');
      const buffer = $.gpuRead(s.id, offset, size);
      s.ranges.push({ offset, size, buffer }); return buffer;
    }
    unmap() {
      const s = state.get(this);
      for (const r of s.ranges) {
        if (!s.dead && s.mode === 2) $.gpuWrite(s.id, r.offset, r.buffer);
        $.gpuDetach(r.buffer);
      }
      s.ranges = []; s.map = 'unmapped'; s.pending = null;
    }
    destroy() { const s = state.get(this); if (s.dead) return; this.unmap(); $.gpuDestroy(s.id); s.dead = true; }
  }
  class GPUShaderModule { getCompilationInfo() { return Promise.resolve({ messages: state.get(this).messages.slice() }); } }
  class GPUComputePipeline {
    getBindGroupLayout(index) { return $.wg.getBindGroupLayout(this, index, 'compute'); }
  }
  class GPUBindGroupLayout {}
  class GPUBindGroup {}
  class GPUQueue {
    constructor(d) { own(this, 'queue', d); }
    writeBuffer(buffer, offset, data, dataOffset = 0, size) {
      const d = state.get(this).device;
      attempt(d, () => {
        const s = get(buffer, 'buffer', d); offset = uint(offset); dataOffset = uint(dataOffset);
        if (!(s.usage & 8) || s.map !== 'unmapped') fail('writeBuffer requires unmapped COPY_DST buffer');
        const view = ArrayBuffer.isView(data);
        const element = view && data.BYTES_PER_ELEMENT || 1;
        const bytes = view ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : new Uint8Array(data);
        const begin = dataOffset * element, n = size === undefined ? bytes.byteLength - begin : uint(size) * element;
        if (begin > bytes.byteLength || n < 0 || n > bytes.byteLength - begin || offset % 4 || n % 4 || offset + n > s.size) fail('Invalid writeBuffer range or alignment');
        $.gpuWrite(s.id, offset, bytes.slice(begin, begin + n).buffer);
      });
    }
    submit(commands) { $.wg.submit(state.get(this).device, commands); }
    onSubmittedWorkDone() { return Promise.resolve(); }
  }
  $.wg = { state, get, own, fail, uint, report, attempt, limits };
  const globals = { GPU, GPUAdapter, GPUDevice, GPUBuffer, GPUShaderModule, GPUComputePipeline, GPUBindGroup, GPUBindGroupLayout, GPUQueue,
    GPUValidationError, GPUOutOfMemoryError, GPUInternalError, GPUUncapturedErrorEvent,
    GPUBufferUsage: Object.freeze({ MAP_READ: 1, MAP_WRITE: 2, COPY_SRC: 4, COPY_DST: 8, INDEX: 16, VERTEX: 32, UNIFORM: 64, STORAGE: 128, INDIRECT: 256, QUERY_RESOLVE: 512 }),
    GPUMapMode: Object.freeze({ READ: 1, WRITE: 2 }), GPUShaderStage: Object.freeze({ VERTEX: 1, FRAGMENT: 2, COMPUTE: 4 }),
    GPUTextureUsage: Object.freeze({ COPY_SRC: 1, COPY_DST: 2, TEXTURE_BINDING: 4, STORAGE_BINDING: 8, RENDER_ATTACHMENT: 16 }) };
  for (const name of Object.keys(globals)) globalThis[name] = globals[name];
  Object.defineProperty(navigator, 'gpu', { value: new GPU(), enumerable: true });
});
