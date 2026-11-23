import { bindInput } from "./input.js";

// Canvas lifecycle and event delivery. Applications opt in to keyboard
// events so they can keep the browser's own shortcuts where appropriate.
export function createHost(canvas, options = {}) {
  let cpu = options.cpu;
  let lastResize;
  let runtime, context, frame = null, timer = null, unbindInput;
  let stopped = false, lost = false, paused = true, generation = 0, forceRecovery = false;
  const inputEvents = [];
  const unwind = Symbol("nanoui.run");
  const stats = { callbacks: 0 };
  const raf = options.requestAnimationFrame ?? globalThis.requestAnimationFrame.bind(globalThis);
  const caf = options.cancelAnimationFrame ?? globalThis.cancelAnimationFrame.bind(globalThis);
  function request() {
    if (stopped || lost || paused || frame !== null) return;
    if (timer !== null) { clearTimeout(timer); timer = null; }
    frame = raf(time => {
      frame = null;
      stats.callbacks++;
      // A device replacement pauses until its pipelines compile; a frame
      // queued before it must not draw with the placeholders.
      if (!stopped && !lost && !paused) {
        // Preserve button transitions across frames. A quick down/up in
        // one browser task must still produce a pressed frame for drags.
        while (inputEvents.length) {
          const event = inputEvents.shift();
          if (event[0] === "pinch") runtime.exports.nanoui_web_pinch(...event.slice(1));
          else if (event[0] === "key") runtime.exports.nanoui_web_key(...event.slice(1));
          else runtime.exports.nanoui_web_pointer(...event);
          if (event[0] !== 0 && !(event[0] === "key" && event[1] === 3)) break;
        }
        const submitted = runtime.gpu?.stats.frames;
        const more=runtime.exports.nanoui_web_frame(time);
        const sample=runtime.gpu?.stats.samples.at(-1);
        if(sample && runtime.gpu?.stats.frames !== submitted)sample.log_index=runtime.exports.nanoui_web_last_record();
        if(more || inputEvents.length)request();
      }
    });
  }
  function after(ms) {
    if (stopped || lost || frame !== null || timer !== null) return;
    timer = setTimeout(() => { timer = null; request(); }, Math.max(0, ms));
  }
  function resize(width, height, scale = options.scale ?? globalThis.devicePixelRatio ?? 1) {
    if (stopped || !runtime) return;
    if (width === undefined) {
      const rect = canvas.getBoundingClientRect?.();
      width = Math.round((rect?.width ?? canvas.width / scale) * scale);
      height = Math.round((rect?.height ?? canvas.height / scale) * scale);
    }
    if (![width, height, scale].every(Number.isFinite) || width < 1 || height < 1 || scale <= 0) return;
    lastResize = [width, height, scale];
    // Phones report DPR 3; the CPU raster costs per pixel, so it renders at
    // most at cpuMaxScale and the browser scales the canvas up.
    const cpuMaxScale = options.cpuMaxScale ?? 2;
    if (cpu && scale > cpuMaxScale) {
      const ratio = cpuMaxScale / scale;
      width = Math.max(1, Math.round(width * ratio));
      height = Math.max(1, Math.round(height * ratio));
      scale = cpuMaxScale;
    }
    if (cpu && width * height > 4096 * 4096) {
      const ratio = Math.sqrt((4096 * 4096) / (width * height));
      width = Math.max(1, Math.floor(width * ratio));
      height = Math.max(1, Math.floor(height * ratio));
      scale *= ratio;
    }
    if (canvas.width !== width) canvas.width = width;
    if (canvas.height !== height) canvas.height = height;
    runtime.exports.nanoui_web_resize(width, height, scale);
  }
  function pointer(kind, x, y, button = 0, mods = 0, clicks = 1) {
    if (stopped || lost) return;
    const event=[kind,x,y,button,mods,clicks];
    if(kind===0 && inputEvents.at(-1)?.[0]===0)inputEvents[inputEvents.length-1]=event;
    else inputEvents.push(event);
    request();
  }
  function pinch(x, y, factor, dx = 0, dy = 0) {
    if (stopped || lost || !Number.isFinite(factor) || factor <= 0) return;
    const last = inputEvents.at(-1);
    if (last?.[0] === "pinch") {
      last[1] = x;
      last[2] = y;
      last[3] *= factor;
      last[4] += dx;
      last[5] += dy;
    } else inputEvents.push(["pinch", x, y, factor, dx, dy]);
    request();
  }
  function wheel(x, y, dx, dy) {
    if (!stopped && !lost) runtime.exports.nanoui_web_wheel(x, y, dx, dy);
  }
  function key(kind, code, mods, typed = 0) {
    if (stopped) return;
    if (kind === 2) {
      // If focus is gone, releases still need to arrive after recovery.
      if (lost) inputEvents.length = 0;
    } else if (lost) return;
    inputEvents.push(["key", kind, code, mods, typed]);
    request();
  }
  function configure() {
    context.configure({ device: runtime.gpu.device, format: options.format,
      alphaMode: "opaque", usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_SRC | GPUTextureUsage.COPY_DST });
    runtime.gpu.setCanvas(context);
  }
  function cancelFrame() {
    if (frame !== null) { caf(frame); frame = null; }
    if (timer !== null) { clearTimeout(timer); timer = null; }
  }
  function detachListeners() {
    unbindInput?.();
    unbindInput = null;
  }
  function useCpu(replacement) {
    const nextContext = replacement.getContext("2d", { alpha: false });
    if (!nextContext) return false;
    const previous = canvas;
    const restoreFocus = previous.ownerDocument?.activeElement === previous;
    runtime.exports.nanoui_web_use_cpu();
    const gpu = runtime.gpu;
    const device = gpu.device;
    context.unconfigure();
    gpu.retire();
    device.destroy();
    runtime.gpu = null;
    cpu = true;
    lost = false;
    detachListeners();
    if (previous.ownerDocument) {
      replacement.style.touchAction = previous.style.touchAction;
      previous.replaceWith(replacement);
    }
    canvas = replacement;
    context = nextContext;
    host.listen();
    if (restoreFocus) replacement.focus({ preventScroll: true });
    request();
    return true;
  }
  async function recoverOnCpu(operation, error) {
    if (stopped || operation !== generation) return;
    if (options.cpuFallback) {
      // A canvas keeps its context type, so Canvas 2D needs a fresh element.
      try {
        const replacement = canvas.ownerDocument && canvas.parentNode && canvas.cloneNode(false);
        if (stopped || operation !== generation) return;
        if (replacement && replacement !== canvas && useCpu(replacement)) return;
      } catch (fallbackError) {
        error = fallbackError;
      }
    }
    options.onError?.(error);
  }
  function watchDevice() {
    const device = runtime.gpu.device;
    const current = ++generation;
    device.lost.then(async info => {
      if (stopped || current !== generation) return;
      lost = true;
      runtime.exports.nanoui_web_device_lost();
      cancelFrame();
      // A release can arrive while rendering is suspended.
      runtime.exports.nanoui_web_cancel_input();
      inputEvents.length = 0;
      const recover = info.reason !== "destroyed" || forceRecovery;
      forceRecovery = false;
      options.onDeviceLost?.(info);
      if (options.ownsDevice && recover && !stopped && current === generation) {
        let operation = current;
        try {
          const next = await options.acquireDevice();
          if (stopped || current !== generation) {
            next.destroy();
            return;
          }
          operation = ++generation;
          await replaceDevice(next, operation);
        } catch (error) {
          await recoverOnCpu(operation, error);
        }
      }
    });
  }
  async function replaceDevice(device, operation) {
    paused = true;
    cancelFrame();
    const previous = runtime.device;
    runtime.gpu.setDevice(device);
    if (options.ownsDevice && previous !== device) previous.destroy();
    configure();
    if (runtime.exports.nanoui_web_device()) throw new Error("Could not recreate WebGPU renderer");
    await Promise.race([
      runtime.gpu.ready(),
      device.lost.then(info => { throw new Error(info.message || "Replacement WebGPU device was lost"); }),
    ]);
    if (stopped || operation !== generation) return;
    lost = false; paused = false;
    watchDevice();
    request();
  }
  async function setDevice(device) {
    if (stopped) return;
    if (cpu) throw new Error("The canvas is using its CPU renderer");
    await replaceDevice(device, ++generation);
  }
  const host = {
    get canvas() { return canvas; },
    stats, unwind, requestFrame: request, resize, pointer, wheel, pinch, key, setDevice,
    imports: {
      cpu_backend: () => Number(cpu),
      present_cpu(ptr, width, height) {
        if (!context || stopped) return;
        // Zig wrote opaque RGBA; ImageData can view WASM memory directly.
        const pixels = new Uint8ClampedArray(runtime.exports.memory.buffer, ptr, width * height * 4);
        context.putImageData(new ImageData(pixels, width, height), 0, 0);
      },
      request_frame: request, request_after: after, now_ms: () => performance.now(), run_forever() { throw unwind; },
    },
    attach(value) {
      runtime = value;
      if (cpu) {
        context = canvas.getContext("2d", { alpha: false });
        if (!context) throw new Error("Canvas 2D context is unavailable");
        return;
      }
      context = canvas.getContext("webgpu");
      if (!context) throw new Error("Canvas WebGPU context is unavailable");
      configure();
      runtime.gpu.onTiming(sample=>{
        if(sample.log_index!==undefined && sample.log_index!==0xffffffff)runtime.exports.nanoui_web_gpu_time(sample.log_index,sample.gpu_ms);
      });
      watchDevice();
    },
    listen() {
      paused = false;
      resize(...(lastResize ?? [options.width, options.height, options.scale]));
      if (canvas.getBoundingClientRect) unbindInput = bindInput(canvas, { pointer, pinch, wheel, key, resize }, {
        keyboard: options.keyboard, scale: options.scale,
      });
    },
    debugLoseDevice() { forceRecovery = true; runtime.gpu.device.destroy(); },
    destroy() {
      if (stopped) return;
      stopped = true; generation++;
      inputEvents.length=0;
      cancelFrame();
      detachListeners();
      runtime?.exports.nanoui_web_destroy();
      context?.unconfigure?.();
      runtime?.gpu?.dispose();
      if (options.ownsDevice) runtime?.device?.destroy();
    },
  };
  return host;
}


// A finger becomes an editor pointer on a drag or a tap. A second finger
// takes over as a pinch, canceling any speculative edit from the first.
