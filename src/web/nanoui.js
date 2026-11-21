import { createGPU } from "./gpu.js";
import { createWASI } from "./wasi.js";
import { createHost } from "./host.js";

// Reactor loader, usable in either the main thread or a dedicated Worker.
// Inject a GPUDevice to share it with a compositor on the same thread.
export async function load({ url, device, format = "bgra8unorm", imports = {}, asyncPipelines = false }) {
  const ownsDevice = !device;
  if (!device) {
    const adapter = await globalThis.navigator?.gpu?.requestAdapter({ powerPreference: "high-performance" });
    if (!adapter) throw new Error("WebGPU is unavailable");
    device = await adapter.requestDevice();
  }
  let instance;
  const runtime = {};
  const gpu = createGPU({
    device, format, asyncPipelines, memory: () => instance.exports.memory,
    done(token, status) { instance.exports.nanoui_gpu_done(token, status); runtime.onReadback?.(status); },
  });
  try {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Loading wasm: HTTP ${response.status}`);
    ({ instance } = await WebAssembly.instantiate(await response.arrayBuffer(), {
      wasi_snapshot_preview1: createWASI(() => instance.exports.memory),
      nanoui_gpu: gpu.imports, ...imports,
    }));
    instance.exports._initialize?.();
  } catch (error) {
    gpu.dispose();
    if (ownsDevice) device.destroy();
    throw error;
  }
  Object.assign(runtime, { exports: instance.exports, gpu });
  Object.defineProperty(runtime, "device", { get: () => gpu.device });
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
  const device = options.device ?? await acquireDevice();
  const host = createHost(options.canvas, { ...options, format, ownsDevice: !options.device, acquireDevice });
  let runtime;
  try {
    runtime = await load({ ...options, asyncPipelines:true, device, format, imports: { ...options.imports, nanoui_web: host.imports } });
    host.attach(runtime);
    try { runtime.exports._start(); }
    catch (error) { if (error !== host.unwind) throw error; }
    await runtime.gpu.ready();
    host.listen();
    return Object.assign(runtime, { host, setDevice: host.setDevice, destroy: host.destroy, requestFrame: host.requestFrame });
  } catch (error) {
    host.destroy();
    // Loading can fail before the host has the runtime to dispose.
    if (!runtime && !options.device) device.destroy();
    throw error;
  }
}
