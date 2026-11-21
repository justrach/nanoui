// Example OffscreenCanvas entry point. DOM input can be forwarded as messages.
import { start } from "./nanoui.js";
let runtime;
self.onmessage = async ({ data }) => {
  try {
    if (data.canvas) {
      runtime = await start({ canvas: data.canvas, url: data.url ?? "./counter.wasm", width: data.width, height: data.height, scale: data.scale ?? 1 });
      self.postMessage({ ready: true });
    } else if (data.info) self.postMessage({ id:data.info, frames:runtime.exports.nanoui_web_frames(), callbacks:runtime.host.stats.callbacks, value:Number(runtime.exports.counter_value()), generation:runtime.gpu.generation });
    else if (data.resize) runtime.host.resize(...data.resize);
    else if (data.pointer) runtime.host.pointer(...data.pointer);
    else if (data.pinch) runtime.host.pinch(...data.pinch);
    else if (data.wheel) runtime.host.wheel(...data.wheel);
    else if (data.destroy) { runtime.destroy(); self.close(); }
  } catch (error) { self.postMessage({ error: error.message }); }
};
