// Buffer-only layouts shared by compute and render pipelines. Explicit layouts
// compare structurally; automatic layouts stay exclusive to their pipeline.
(function ($, globalThis) {
  'use strict';
  if (!$.wg) return;
  const { state, get, own, fail, uint, attempt } = $.wg;
  class GPUPipelineLayout {}
  $.wg.createBindGroupLayout = (d, desc) => {
    const layout = own(new GPUBindGroupLayout(), 'layout', d, { entries: [], valid: false, pipeline: null });
    layout.label = String(desc.label || '');
    attempt(d, () => {
      const entries = state.get(layout).entries;
      for (const e of desc.entries) {
        const binding = uint(e.binding, 7), visibility = uint(e.visibility, 7), b = e.buffer;
        if (!b || e.sampler || e.texture || e.storageTexture || e.externalTexture) fail('Only buffer layouts supported');
        if (entries.some(x => x.binding === binding)) fail('Duplicate layout binding');
        const type = b.type === undefined ? 'uniform' : String(b.type);
        if (!['uniform', 'storage', 'read-only-storage'].includes(type) || b.hasDynamicOffset) fail('Unsupported buffer layout');
        const minBindingSize = uint(b.minBindingSize || 0, $.wg.limits.maxBufferSize);
        if (type === 'storage' && (visibility & 1)) fail('Writable storage is not supported in the vertex stage');
        entries.push({ binding, visibility, type, minBindingSize });
      }
      entries.sort((a, b) => a.binding - b.binding);
      state.get(layout).valid = true;
    });
    return layout;
  };
  $.wg.createPipelineLayout = (d, desc) => {
    const layout = own(new GPUPipelineLayout(), 'pipelineLayout', d, { layouts: [], valid: false });
    layout.label = String(desc.label || '');
    attempt(d, () => {
      const layouts = Array.from(desc.bindGroupLayouts);
      if (layouts.length > 1) fail('Only bind group 0 supported');
      for (const l of layouts) {
        const s = get(l, 'layout', d);
        if (!s.valid || s.pipeline) fail('Pipeline layouts require valid explicit bind group layouts');
      }
      state.get(layout).layouts = layouts;
      state.get(layout).valid = true;
    });
    return layout;
  };
  $.wg.pipelineLayout = (d, pipeline, layout, stages) => {
    const entries = [];
    for (const stage of stages) {
      const shader = get(stage.module, 'shader', d);
      for (const b of $.gpuBindings(shader.id, String(stage.entryPoint || 'main'))) {
        const existing = entries.find(e => e.binding === b.binding);
        if (existing) {
          if (existing.type !== b.type) fail('Shader binding types disagree between stages');
          existing.visibility |= stage.visibility;
          existing.minBindingSize = Math.max(existing.minBindingSize, b.minBindingSize);
        } else entries.push({ binding: b.binding, type: b.type, visibility: stage.visibility, minBindingSize: b.minBindingSize });
      }
    }
    entries.sort((a, b) => a.binding - b.binding);
    let layouts;
    if (layout === 'auto') {
      layouts = [own(new GPUBindGroupLayout(), 'layout', d, { entries, valid: true, pipeline })];
    } else {
      const s = get(layout, 'pipelineLayout', d);
      if (!s.valid) fail('Invalid pipeline layout');
      layouts = s.layouts.slice();
      const declared = layouts.length ? get(layouts[0], 'layout', d).entries : [];
      for (const b of entries) {
        const e = declared.find(e => e.binding === b.binding);
        if (!e || e.type !== b.type || (e.visibility & b.visibility) !== b.visibility || (e.minBindingSize && e.minBindingSize < b.minBindingSize))
          fail('Pipeline layout does not match shader bindings');
      }
    }
    state.get(pipeline).layouts = layouts;
  };
  $.wg.getBindGroupLayout = (p, index, kind) => {
    const s = get(p, kind);
    return attempt(s.device, () => {
      index = uint(index, 0);
      if (!s.id || !s.layouts[index]) fail('Invalid bind group index or pipeline');
      return s.layouts[index];
    }, null);
  };
  $.wg.createBindGroup = (d, desc) => {
    const group = own(new GPUBindGroup(), 'bindgroup', d, { buffers: Array(8).fill(null), layout: null, valid: false });
    group.label = String(desc.label || '');
    attempt(d, () => {
      const layout = get(desc.layout, 'layout', d), s = state.get(group);
      if (!layout.valid) fail('Invalid bind group layout');
      s.layout = desc.layout;
      let count = 0;
      for (const e of desc.entries) {
        const binding = uint(e.binding, 7), entry = layout.entries.find(x => x.binding === binding), r = e.resource;
        if (!entry || s.buffers[binding]) fail('Unexpected or duplicate binding');
        const b = get(r.buffer, 'buffer', d);
        if (!b.id || (r.offset || 0) !== 0 || (r.size !== undefined && r.size !== b.size)) fail('Only valid whole-buffer bindings supported');
        const usage = entry.type === 'uniform' ? 64 : 128;
        if (!(b.usage & usage) || b.size < entry.minBindingSize || (entry.type === 'uniform' && b.size > $.wg.limits.maxUniformBufferBindingSize))
          fail('Buffer binding usage or size does not match layout');
        s.buffers[binding] = r.buffer;
        count++;
      }
      if (count !== layout.entries.length) fail('Missing bind group entry');
      s.valid = true;
    });
    return group;
  };
  function compatible(a, b) {
    if (a === b) return true;
    const x = state.get(a), y = state.get(b);
    if (x.pipeline || y.pipeline || x.entries.length !== y.entries.length) return false;
    return x.entries.every((e, i) => {
      const f = y.entries[i];
      return e.binding === f.binding && e.type === f.type && e.visibility === f.visibility && e.minBindingSize === f.minBindingSize;
    });
  }
  $.wg.bindingIds = (d, p, group) => {
    const pipeline = state.get(p), expected = pipeline.layouts[0];
    if (!group) {
      if (expected && state.get(expected).entries.length) fail('Missing bind group');
      return Array(8).fill(0);
    }
    const g = get(group, 'bindgroup', d);
    if (!g.valid || !expected || !compatible(g.layout, expected)) fail('Bind group layout incompatible with pipeline');
    return g.buffers.map(b => {
      if (!b) return 0;
      const s = get(b, 'buffer', d);
      if (!s.id || s.map !== 'unmapped') fail('Buffer is invalid or mapped');
      return s.id;
    });
  };
  globalThis.GPUPipelineLayout = GPUPipelineLayout;
});
