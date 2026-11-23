import { createGPU } from "./gpu.js";
import { createWASI } from "./wasi.js";
import { createHost } from "./host.js";

// Reactor loader, usable in either the main thread or a dedicated Worker.
// Inject a GPUDevice to share it with a compositor on the same thread.
export async function load({ url, device, format = "bgra8unorm", imports = {}, asyncPipelines = false, cpu = false }) {
  const ownsDevice = !cpu && !device;
  if (!cpu && !device) {
    const adapter = await globalThis.navigator?.gpu?.requestAdapter({ powerPreference: "high-performance" });
    if (!adapter) throw new Error("WebGPU is unavailable");
    device = await adapter.requestDevice();
  }
  let instance;
  const runtime = {};
  const gpu = cpu ? null : createGPU({
    device, format, asyncPipelines, memory: () => instance.exports.memory,
    done(token, status) { instance.exports.nanoui_gpu_done(token, status); runtime.onReadback?.(status); },
  });
  try {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Loading wasm: HTTP ${response.status}`);
    ({ instance } = await WebAssembly.instantiate(await response.arrayBuffer(), {
      wasi_snapshot_preview1: createWASI(() => instance.exports.memory),
      nanoui_gpu: gpu?.imports ?? new Proxy({
        device: () => 0,
        device_generation: () => 0,
      }, { get: (target, key) => target[key] ?? (() => { throw new Error("WebGPU resources are unavailable on the CPU renderer"); }) }), ...imports,
    }));
    instance.exports._initialize?.();
  } catch (error) {
    gpu?.dispose();
    if (ownsDevice) device.destroy();
    throw error;
  }
  Object.assign(runtime, { exports: instance.exports, gpu });
  Object.defineProperty(runtime, "device", { get: () => runtime.gpu?.device });
  return runtime;
}

export async function start(options) {
  const format = options.format ?? navigator.gpu?.getPreferredCanvasFormat();
  const acquireDevice = async () => {
    const adapter = await navigator.gpu?.requestAdapter({ powerPreference: "high-performance" });
    if (!adapter) throw new Error("WebGPU is unavailable");
    const requiredFeatures = ["timestamp-query", "float32-filterable", "texture-formats-tier1"].filter(f => adapter.features.has(f));
    return adapter.requestDevice({ requiredFeatures });
  };
  let device = options.cpu ? undefined : options.device;
  if (!device && !options.cpu) {
    try { device = await acquireDevice(); }
    catch (error) { if (!options.cpuFallback) throw error; }
  }
  const cpu = !device;
  const host = createHost(options.canvas, { ...options, format, cpu, ownsDevice: !cpu && !options.device, acquireDevice });
  let runtime;
  try {
    runtime = await load({ ...options, cpu, asyncPipelines:true, device, format, imports: { ...options.imports, nanoui_web: host.imports } });
    host.attach(runtime);
    try { runtime.exports._start(); }
    catch (error) { if (error !== host.unwind) throw error; }
    await runtime.gpu?.ready();
    host.listen();
    Object.defineProperty(runtime, "canvas", { get: () => host.canvas });
    return Object.assign(runtime, { host, setDevice: host.setDevice, destroy: host.destroy, requestFrame: host.requestFrame });
  } catch (error) {
    host.destroy();
    // Loading can fail before the host has the runtime to dispose.
    if (!runtime && !options.device) device?.destroy();
    throw error;
  }
}
