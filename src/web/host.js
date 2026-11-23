// Canvas lifecycle and event delivery. Applications opt in to keyboard
// events so they can keep the browser's own shortcuts where appropriate.
const namedKeys = {
  ArrowUp: 0xf700, ArrowDown: 0xf701, ArrowLeft: 0xf702, ArrowRight: 0xf703,
  Escape: 27, Tab: 9, Enter: 13, Backspace: 127, Delete: 0xf728,
  Home: 0xf729, End: 0xf72b, PageUp: 0xf72c, PageDown: 0xf72d,
};

function keyCode(name) {
  if (Object.hasOwn(namedKeys, name)) return namedKeys[name];
  if (/^F(?:[1-9]|1[0-2])$/.test(name)) return 0xf703 + Number(name.slice(1));
  return Array.from(name).length === 1 ? name.codePointAt(0) : 0;
}
export function createHost(canvas, options = {}) {
  let cpuImage;
  let cpu = options.cpu;
  let lastResize;
  let runtime, context, frame = null, timer = null, observer, media;
  let stopped = false, lost = false, paused = true, generation = 0, forceRecovery = false;
  const listeners = [];
  const inputEvents = [];
  const unwind = Symbol("nanoui.run");
  const stats = { callbacks: 0 };
  const raf = options.requestAnimationFrame ?? globalThis.requestAnimationFrame.bind(globalThis);
  const caf = options.cancelAnimationFrame ?? globalThis.cancelAnimationFrame.bind(globalThis);
  const on = (object, name, fn, opts) => { object.addEventListener(name, fn, opts); listeners.push(() => object.removeEventListener(name, fn, opts)); };
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
    observer?.disconnect();
    for (const off of listeners.splice(0)) off();
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
        if (cpuImage?.width !== width || cpuImage?.height !== height)
          cpuImage = context.createImageData(width, height);
        const src = new Uint8Array(runtime.exports.memory.buffer, ptr, width * height * 4);
        const dst = cpuImage.data;
        for (let i = 0; i < src.length; i += 4) {
          dst[i] = src[i + 2];
          dst[i + 1] = src[i + 1];
          dst[i + 2] = src[i];
          dst[i + 3] = 255;
        }
        context.putImageData(cpuImage, 0, 0);
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
      if (canvas.getBoundingClientRect) {
        if (options.keyboard) {
          const forwarded = new Map();
          // AltGr reports Ctrl and Alt on Windows; it types, it is not a shortcut.
          const altGraph = e => !!e.getModifierState?.("AltGraph");
          const mods = e => Number(e.shiftKey) | (Number(e.ctrlKey && !altGraph(e)) << 1) |
            (Number(e.altKey && !altGraph(e)) << 2) | (Number(e.metaKey) << 3) | (Number(e.repeat) << 4);
          const down = e => {
            if (e.defaultPrevented || e.isComposing || !options.keyboard(e)) return;
            const code = keyCode(e.key);
            if (!code) return;
            const typed = Array.from(e.key).length === 1 && (!e.ctrlKey || altGraph(e)) && !e.metaKey ? code : 0;
            forwarded.set(e.code, code);
            key(0, code, mods(e), typed);
            e.preventDefault();
          };
          const up = e => {
            const code = forwarded.get(e.code);
            if (code === undefined) return;
            forwarded.delete(e.code);
            key(1, code, mods(e));
            e.preventDefault();
          };
          on(canvas, "keydown", down);
          on(canvas, "keyup", up);
          on(canvas, "blur", () => {
            forwarded.clear();
            key(2, 0, 0);
          });
        }
        const coords = e => { const r = canvas.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
        const touches = touchInput(pointer, pinch);
        let pressed, lastClick;
        const near = (point, x, y) => Math.hypot(x - point.x, y - point.y) <= 5;
        const touchAction = canvas.style.touchAction;
        canvas.style.touchAction = "none";
        listeners.push(() => { canvas.style.touchAction = touchAction; });
        for (const [event, kind] of [["pointermove", 0], ["pointerdown", 1], ["pointerup", 2], ["pointercancel", 3]]) {
          on(canvas, event, e => {
            const mods = Number(e.shiftKey) | (Number(e.ctrlKey) << 1) | (Number(e.altKey) << 2) | (Number(e.metaKey) << 3);
            if (kind === 1) {
              canvas.setPointerCapture(e.pointerId);
              if (options.keyboard) canvas.focus({ preventScroll: true });
            }
            const [x, y] = coords(e);
            if (e.pointerType === "touch") touches.event(kind, e.pointerId, x, y);
            else {
              if (kind === 1) {
                const repeated = e.button === 0 && lastClick && e.timeStamp - lastClick.time <= 500 && near(lastClick, x, y);
                pressed = e.button === 0 ? { x, y, clicks: repeated ? Math.min(lastClick.clicks + 1, 3) : 1 } : null;
                lastClick = null;
              } else if (kind === 2 || kind === 3) {
                if (kind === 2 && pressed && near(pressed, x, y)) lastClick = { ...pressed, time: e.timeStamp };
                pressed = null;
              }
              pointer(kind, x, y, e.button, mods, pressed?.clicks ?? 1);
            }
            if (kind === 2 || kind === 3) { if (canvas.hasPointerCapture(e.pointerId)) canvas.releasePointerCapture(e.pointerId); }
            e.preventDefault();
          });
        }
        // Off the canvas with no button held: move the UI pointer outside,
        // as the native mouse-exit paths do, so nothing stays hovered. A
        // held button keeps the capture, and its release reports the exit.
        on(canvas, "pointerleave", e => {
          if (e.pointerType !== "touch" && e.buttons === 0) pointer(0, -1e6, -1e6, 0, 0, 1);
        });
        on(canvas, "lostpointercapture", e => {
          if (e.pointerType === "touch") touches.event(3, e.pointerId, ...coords(e));
        });
        // Safari reports a cumulative scale; Chromium and Firefox use
        // ctrl-modified wheel deltas for trackpad pinch gestures.
        let gestureScale = null;
        on(canvas, "gesturestart", e => {
          gestureScale = touches.active() ? null : 1;
          e.preventDefault();
        }, { passive: false });
        on(canvas, "gesturechange", e => {
          if (gestureScale !== null && !touches.active() && e.scale > 0) {
            pinch(...coords(e), e.scale / gestureScale);
            gestureScale = e.scale;
          }
          e.preventDefault();
        }, { passive: false });
        on(canvas, "gestureend", e => {
          gestureScale = null;
          e.preventDefault();
        }, { passive: false });
        on(canvas, "wheel", e => {
          const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? canvas.clientHeight : 1;
          if (e.ctrlKey && e.deltaY !== 0) {
            if (gestureScale === null && !touches.active())
              pinch(...coords(e), Math.exp(Math.max(-1, Math.min(1, -e.deltaY * unit * 0.01))));
          } else wheel(...coords(e), -e.deltaX * unit, -e.deltaY * unit);
          e.preventDefault();
        }, { passive: false });
        on(canvas, "contextmenu", e => e.preventDefault());
        observer = new ResizeObserver(entries => {
          const box = entries[0].devicePixelContentBoxSize?.[0];
          const dpr = options.scale ?? globalThis.devicePixelRatio ?? 1;
          const expected = Math.round(entries[0].contentRect.width * dpr);
          if (box && Math.abs(box.inlineSize - expected) <= 1) resize(box.inlineSize, box.blockSize); else resize();
        });
        try { observer.observe(canvas, { box: "device-pixel-content-box" }); }
        catch { observer.observe(canvas); }
        const dprChanged = () => {
          media?.removeEventListener("change", dprChanged);
          media = matchMedia(`(resolution: ${devicePixelRatio}dppx)`);
          media.addEventListener("change", dprChanged, { once: true });
          resize();
        };
        dprChanged();
        listeners.push(() => media?.removeEventListener("change", dprChanged));
      }
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
function touchInput(pointer, pinch) {
  const contacts = new Map();
  let dragging = false;
  let multi = false;
  let baseline;
  const dragThreshold = 5;

  function measure() {
    const [a, b] = contacts.values();
    if (!b) return undefined;
    return {
      x: (a.x + b.x) / 2,
      y: (a.y + b.y) / 2,
      distance: Math.hypot(a.x - b.x, a.y - b.y),
    };
  }

  function event(kind, id, x, y) {
    if (kind === 1) {
      contacts.set(id, { x, y, startX: x, startY: y });
      if (contacts.size >= 2) {
        if (dragging) pointer(3, x, y);
        multi = true;
        dragging = false;
        baseline = measure();
      }
      return;
    }
    const contact = contacts.get(id);
    if (!contact) return;
    if (kind === 0) {
      contact.x = x;
      contact.y = y;
      if (multi) {
        const next = measure();
        if (next && baseline && next.distance >= 1 && baseline.distance >= 1)
          pinch(next.x, next.y, next.distance / baseline.distance, next.x - baseline.x, next.y - baseline.y);
        baseline = next;
      } else {
        if (!dragging && Math.hypot(x - contact.startX, y - contact.startY) >= dragThreshold) {
          pointer(1, contact.startX, contact.startY);
          dragging = true;
        }
        if (dragging) pointer(0, x, y);
      }
      return;
    }
    if (!multi) {
      if (kind === 2 && !dragging) pointer(1, contact.startX, contact.startY);
      if (dragging || kind === 2) pointer(kind, x, y);
    }
    contacts.delete(id);
    baseline = measure();
    if (contacts.size === 0) {
      dragging = false;
      multi = false;
    }
  }

  return { active: () => contacts.size > 0, event };
}
