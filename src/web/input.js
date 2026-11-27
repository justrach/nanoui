// DOM input for a nanoui canvas: keys, pointers, touch, pinch, wheel and
// size. The page-hosted runtime and the Worker page helper share it, and
// each passes its own sink.
const namedKeys = {
  ArrowUp: 0xf700, ArrowDown: 0xf701, ArrowLeft: 0xf702, ArrowRight: 0xf703,
  Escape: 27, Tab: 9, Enter: 13, Backspace: 127, Delete: 0xf728,
  Home: 0xf729, End: 0xf72b, PageUp: 0xf72c, PageDown: 0xf72d,
};

export function keyCode(name) {
  if (Object.hasOwn(namedKeys, name)) return namedKeys[name];
  if (/^F(?:[1-9]|1[0-2])$/.test(name)) return 0xf703 + Number(name.slice(1));
  return Array.from(name).length === 1 ? name.codePointAt(0) : 0;
}
// Listen on `canvas` and report input through `sink`: pointer(kind, x, y,
// button, mods, clicks), pinch(x, y, factor, dx, dy), wheel(x, y, dx, dy),
// key(kind, code, mods, typed) and resize(width?, height?). Coordinates are
// CSS pixels from the canvas origin. focusAt(x, y) may name an element to
// focus instead of the canvas for a press there. Returns a function that
// removes every listener.
export function bindInput(canvas, sink, { keyboard, keyTargets = [canvas], scale, focusAt } = {}) {
  const { pointer, pinch, wheel, key, resize } = sink;
  const listeners = [];
  const on = (object, name, fn, opts) => { object.addEventListener(name, fn, opts); listeners.push(() => object.removeEventListener(name, fn, opts)); };
  if (keyboard) {
    const forwarded = new Map();
    // AltGr reports Ctrl and Alt on Windows; it types, it is not a shortcut.
    const altGraph = e => !!e.getModifierState?.("AltGraph");
    const mods = e => Number(e.shiftKey) | (Number(e.ctrlKey && !altGraph(e)) << 1) |
      (Number(e.altKey && !altGraph(e)) << 2) | (Number(e.metaKey) << 3) | (Number(e.repeat) << 4);
    const down = e => {
      if (e.defaultPrevented || e.isComposing || !keyboard(e)) return;
      if (e.target.tagName === "BUTTON" && (e.key === "Enter" || e.key === " ")) return;
      const code = keyCode(e.key);
      if (!code) return;
      const printable = Array.from(e.key).length === 1 && (!e.ctrlKey || altGraph(e)) && !e.metaKey;
      if (printable && (e.target.tagName === "TEXTAREA" || e.target.tagName === "INPUT")) return;
      const typed = printable ? code : 0;
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
    for (const target of keyTargets) if (target) {
      on(target, "keydown", down);
      on(target, "keyup", up);
    }
    on(canvas, "blur", () => {
      forwarded.clear();
      key(2, 0, 0);
    });
    // Keys held in another key target are released when focus leaves them all.
    for (const target of keyTargets) if (target && target !== canvas) on(target, "focusout", e => {
      if (keyTargets.some(t => t && (t === e.relatedTarget || t.contains?.(e.relatedTarget)))) return;
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
      const [x, y] = coords(e);
      if (kind === 1) canvas.setPointerCapture(e.pointerId);
      // Focus inside the gesture: iOS shows its keyboard only then. A touch
      // focuses on release so a scroll does not close the editor.
      if (keyboard && (kind === 1 ? e.pointerType !== "touch" : kind === 2 && e.pointerType === "touch"))
        (focusAt?.(x, y) ?? canvas).focus({ preventScroll: true });
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
  const observer = new ResizeObserver(entries => {
    const box = entries[0].devicePixelContentBoxSize?.[0];
    const dpr = scale ?? globalThis.devicePixelRatio ?? 1;
    const expected = Math.round(entries[0].contentRect.width * dpr);
    if (box && Math.abs(box.inlineSize - expected) <= 1) resize(box.inlineSize, box.blockSize); else resize();
  });
  try { observer.observe(canvas, { box: "device-pixel-content-box" }); }
  catch { observer.observe(canvas); }
  listeners.push(() => observer.disconnect());
  let media;
  const dprChanged = () => {
    media?.removeEventListener("change", dprChanged);
    media = matchMedia(`(resolution: ${devicePixelRatio}dppx)`);
    media.addEventListener("change", dprChanged, { once: true });
    resize();
  };
  dprChanged();
  listeners.push(() => media?.removeEventListener("change", dprChanged));
  return () => { for (const off of listeners.splice(0)) off(); };
}

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
