// Dedicated Worker entry for a nanoui WASM command drawing to an
// OffscreenCanvas. Start it from the page with startWorker() in
// worker_page.js, which transfers the canvas and forwards input.
import { start } from "./nanoui.js";
let runtime;
let receiveReplacement;
// The page can report a size before the runtime has started.
let earlyResize;

function requestReplacement() {
  return new Promise(resolve => {
    receiveReplacement = resolve;
    self.postMessage({ replaceCanvas: true });
  });
}

self.onmessage = async ({ data }) => {
  try {
    if (Object.hasOwn(data, "fallbackCanvas")) {
      const receive = receiveReplacement;
      receiveReplacement = undefined;
      receive?.(data.fallbackCanvas);
    } else if (data.canvas) {
      if (!data.url) throw new Error("worker.js needs the URL of the WASM command");
      runtime = await start({
        canvas: data.canvas, url: data.url,
        width: data.width, height: data.height, scale: data.scale ?? 1,
        cpuFallback: !!data.cpuFallback, replaceOffscreenCanvas: requestReplacement,
        onError: error => self.postMessage({ error: error.message }),
      });
      if (earlyResize) runtime.host.resize(...earlyResize);
      self.postMessage({ ready: true });
    } else if (data.info) {
      if (!runtime) return self.postMessage({ id: data.info, starting: true });
      // Diagnostics: frame counts, the renderer and named app exports that
      // take no arguments. nanoui's own and WASI exports are not callable here.
      const exports = {};
      for (const name of data.read ?? []) {
        const read = runtime.exports[name];
        if (typeof read !== "function" || read.length !== 0 || name.startsWith("_") || name.startsWith("nanoui_")) continue;
        const value = read();
        if (value !== undefined) exports[name] = Number(value);
      }
      self.postMessage({
        id: data.info, frames: runtime.exports.nanoui_web_frames(),
        callbacks: runtime.host.stats.callbacks, generation: runtime.gpu?.generation ?? 0,
        renderer: runtime.gpu ? "WebGPU" : "Canvas 2D", exports,
      });
    }
    else if (data.resize) {
      if (runtime) runtime.host.resize(...data.resize);
      else earlyResize = data.resize;
    }
    else if (data.pointer) runtime?.host.pointer(...data.pointer);
    else if (data.pinch) runtime?.host.pinch(...data.pinch);
    else if (data.wheel) runtime?.host.wheel(...data.wheel);
    else if (data.key) runtime?.host.key(...data.key);
    else if (data.destroy) {
      runtime?.destroy();
      receiveReplacement?.(null);
      self.postMessage({ destroyed: true });
      self.close();
    }
  } catch (error) { self.postMessage({ error: error.message }); }
};
