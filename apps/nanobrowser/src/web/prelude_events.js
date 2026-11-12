// Events: DOMException, the Event classes, EventTarget and dispatch, in JS.
// Listeners live on the target under a hidden symbol, so they last as long as
// the target's wrapper does. Called with `$`, the private natives, and the global.
(function ($, g) {
"use strict";
const def = (o, name, v) => $.defHidden(o, name, v);
$.def = def;
$.ep = 0;

const codes = { IndexSizeError: 1, HierarchyRequestError: 3, WrongDocumentError: 4, InvalidCharacterError: 5, NoModificationAllowedError: 7, NotFoundError: 8, NotSupportedError: 9, InvalidStateError: 11, SyntaxError: 12, InvalidModificationError: 13, NamespaceError: 14, InvalidAccessError: 15, SecurityError: 18, NetworkError: 19, AbortError: 20, QuotaExceededError: 22, TimeoutError: 23, DataCloneError: 25 };

class DOMException extends Error {
  constructor(message = "", name = "Error") {
    super(message);
    def(this, "name", String(name));
    def(this, "code", codes[name] || 0);
  }
}
def(g, "DOMException", DOMException);
$.hook("domException", (message, name) => new DOMException(message, name));

// Private state also brands events from another same-origin realm. The frame
// bridge carries this record by reference, so cancellation and dispatch flags
// belong to the original event, not a copy or the receiving realm's prototype.
const STATE = Symbol("state");
const state = $.eventState = (event) => {
  const s = event && event[STATE];
  return (s && s.owner === event ? s : null) || $.remoteEventState?.(event);
};

const matOf = (slot) => $.materializePath(slot);

class Event {
  constructor(type, init) {
    if (arguments.length === 0) throw new TypeError("Event: 1 argument required");
    def(this, STATE, { owner: this, stop: false, stopNow: false, path: null, activePath: null, mat: null, slot: -1, passive: false, active: false, canceled: false });
    this.type = String(type);
    this.bubbles = !!(init && init.bubbles);
    this.cancelable = !!(init && init.cancelable);
    this.composed = !!(init && init.composed);
    this.target = null;
    this.currentTarget = null;
    this.eventPhase = 0;
    this.isTrusted = false;
    this.timeStamp = $.now();
  }
  get defaultPrevented() { return state(this).canceled; }
  get srcElement() { return this.target; }
  get cancelBubble() { return state(this).stop; }
  set cancelBubble(v) { if (v) state(this).stop = true; }
  get returnValue() { return !state(this).canceled; }
  set returnValue(v) { if (!v) this.preventDefault(); }
  stopPropagation() { state(this).stop = true; }
  stopImmediatePropagation() { const st = state(this); st.stop = true; st.stopNow = true; }
  preventDefault() { const st = state(this); if (this.cancelable && !st.passive) st.canceled = true; }
  composedPath() {
    const st = state(this);
    let p = st.path;
    if (!p && st.slot >= 0 && st.mat) p = st.path = st.mat(st.slot) || st.activePath;
    return p ? p.slice() : [];
  }
  initEvent(type, bubbles, cancelable) {
    const st = state(this);
    if (st.active) return;
    this.type = String(type);
    this.bubbles = !!bubbles;
    this.cancelable = !!cancelable;
    st.stop = st.stopNow = st.canceled = false;
  }
}
for (const [name, value] of [["NONE", 0], ["CAPTURING_PHASE", 1], ["AT_TARGET", 2], ["BUBBLING_PHASE", 3]]) {
  Object.defineProperty(Event, name, { value, enumerable: true });
  Object.defineProperty(Event.prototype, name, { value, enumerable: true });
}

class CustomEvent extends Event {
  constructor(type, init) { super(type, init); this.detail = init && init.detail !== undefined ? init.detail : null; }
  initCustomEvent(type, bubbles, cancelable, detail) { this.initEvent(type, bubbles, cancelable); this.detail = detail; }
}
class UIEvent extends Event {
  constructor(type, init) { super(type, init); this.view = init && init.view || null; this.detail = init && init.detail || 0; }
  get which() { return 0; }
}
const mods = (e, i) => { e.ctrlKey = !!(i && i.ctrlKey); e.shiftKey = !!(i && i.shiftKey); e.altKey = !!(i && i.altKey); e.metaKey = !!(i && i.metaKey); };
class MouseEvent extends UIEvent {
  constructor(type, i) {
    super(type, i);
    this.clientX = i && i.clientX || 0; this.clientY = i && i.clientY || 0;
    this.screenX = i && i.screenX || 0; this.screenY = i && i.screenY || 0;
    this.movementX = i && i.movementX || 0; this.movementY = i && i.movementY || 0;
    this.button = i && i.button || 0; this.buttons = i && i.buttons || 0;
    this.relatedTarget = i && i.relatedTarget || null;
    mods(this, i);
  }
  get x() { return this.clientX; } get y() { return this.clientY; }
  get pageX() { return this.clientX + g.scrollX; } get pageY() { return this.clientY + g.scrollY; }
  get offsetX() { const r = this.target && this.target.getBoundingClientRect ? this.target.getBoundingClientRect() : null; return r ? this.clientX - r.left : this.clientX; }
  get offsetY() { const r = this.target && this.target.getBoundingClientRect ? this.target.getBoundingClientRect() : null; return r ? this.clientY - r.top : this.clientY; }
  get which() { return this.button + 1; }
  getModifierState(k) { return { Control: this.ctrlKey, Shift: this.shiftKey, Alt: this.altKey, Meta: this.metaKey }[k] || false; }
}
class PointerEvent extends MouseEvent {
  constructor(type, i) {
    super(type, i);
    this.pointerId = i && i.pointerId || 1; this.width = i && i.width || 1; this.height = i && i.height || 1;
    this.pressure = i && i.pressure || 0; this.tiltX = 0; this.tiltY = 0;
    this.pointerType = i && i.pointerType || "mouse"; this.isPrimary = i ? i.isPrimary !== false : true;
  }
}
class WheelEvent extends MouseEvent {
  constructor(type, i) { super(type, i); this.deltaX = i && i.deltaX || 0; this.deltaY = i && i.deltaY || 0; this.deltaZ = i && i.deltaZ || 0; this.deltaMode = i && i.deltaMode || 0; }
}
for (const [n, v] of [["DOM_DELTA_PIXEL", 0], ["DOM_DELTA_LINE", 1], ["DOM_DELTA_PAGE", 2]]) Object.defineProperty(WheelEvent, n, { value: v, enumerable: true });
class KeyboardEvent extends UIEvent {
  constructor(type, i) {
    super(type, i);
    this.key = i && i.key || ""; this.code = i && i.code || "";
    this.location = i && i.location || 0; this.repeat = !!(i && i.repeat); this.isComposing = !!(i && i.isComposing);
    this.keyCode = i && i.keyCode || 0; this.charCode = i && i.charCode || 0;
    mods(this, i);
  }
  get which() { return this.keyCode || this.charCode; }
  getModifierState(k) { return { Control: this.ctrlKey, Shift: this.shiftKey, Alt: this.altKey, Meta: this.metaKey }[k] || false; }
}
class InputEvent extends UIEvent {
  constructor(type, i) { super(type, i); this.data = i && i.data !== undefined ? i.data : null; this.inputType = i && i.inputType || ""; this.isComposing = !!(i && i.isComposing); }
}
class FocusEvent extends UIEvent {
  constructor(type, i) { super(type, i); this.relatedTarget = i && i.relatedTarget || null; }
}
class CompositionEvent extends UIEvent { constructor(type, i) { super(type, i); this.data = i && i.data || ""; } }
class TouchEvent extends UIEvent {}
class HashChangeEvent extends Event { constructor(type, i) { super(type, i); this.oldURL = i && i.oldURL || ""; this.newURL = i && i.newURL || ""; } }
class PopStateEvent extends Event { constructor(type, i) { super(type, i); this.state = i && i.state !== undefined ? i.state : null; } }
class PageTransitionEvent extends Event { constructor(type, i) { super(type, i); this.persisted = !!(i && i.persisted); } }
class ErrorEvent extends Event {
  constructor(type, i) { super(type, i); this.message = i && i.message || ""; this.filename = i && i.filename || ""; this.lineno = i && i.lineno || 0; this.colno = i && i.colno || 0; this.error = i && i.error !== undefined ? i.error : null; }
}
class MessageEvent extends Event {
  constructor(type, i) { super(type, i); this.data = i && i.data !== undefined ? i.data : null; this.origin = i && i.origin || ""; this.lastEventId = i && i.lastEventId || ""; this.source = i && i.source || null; this.ports = i && i.ports || []; }
}
class PromiseRejectionEvent extends Event { constructor(type, i) { super(type, i); this.promise = i && i.promise; this.reason = i && i.reason; } }
class StorageEvent extends Event { constructor(type, i) { super(type, i); this.key = i && i.key || null; this.oldValue = i && i.oldValue || null; this.newValue = i && i.newValue || null; this.url = i && i.url || ""; this.storageArea = i && i.storageArea || null; } }
class AnimationEvent extends Event { constructor(type, i) { super(type, i); this.animationName = i && i.animationName || ""; this.elapsedTime = i && i.elapsedTime || 0; this.pseudoElement = i && i.pseudoElement || ""; } }
class TransitionEvent extends Event { constructor(type, i) { super(type, i); this.propertyName = i && i.propertyName || ""; this.elapsedTime = i && i.elapsedTime || 0; this.pseudoElement = i && i.pseudoElement || ""; } }
class SubmitEvent extends Event { constructor(type, i) { super(type, i); this.submitter = i && i.submitter || null; } }
class BeforeUnloadEvent extends Event {}
class ClipboardEvent extends Event { constructor(type, i) { super(type, i); this.clipboardData = i && i.clipboardData || null; } }
class DragEvent extends MouseEvent { constructor(type, i) { super(type, i); this.dataTransfer = i && i.dataTransfer || null; } }
for (const c of [Event, CustomEvent, UIEvent, MouseEvent, PointerEvent, WheelEvent, KeyboardEvent, InputEvent, FocusEvent, CompositionEvent, TouchEvent, HashChangeEvent, PopStateEvent, PageTransitionEvent, ErrorEvent, MessageEvent, PromiseRejectionEvent, StorageEvent, AnimationEvent, TransitionEvent, SubmitEvent, BeforeUnloadEvent, ClipboardEvent, DragEvent]) def(g, c.name, c);
$.Event = Event;

const LS = Symbol("listeners");
const HANDLERS = Symbol("handlers");

const targetOf = (t) => (t === undefined || t === null ? g : t);

function addEventListener(type, cb, opts) {
  const t = targetOf(this);
  if (cb === null || cb === undefined) return;
  type = String(type);
  const capture = typeof opts === "boolean" ? opts : !!(opts && opts.capture);
  const once = !!(opts && typeof opts === "object" && opts.once);
  const passive = !!(opts && typeof opts === "object" && opts.passive);
  const signal = opts && typeof opts === "object" ? opts.signal : undefined;
  if (signal && signal.aborted) return;
  let map = t[LS];
  if (!map) { map = new Map(); def(t, LS, map); $.markTarget(t); }
  let list = map.get(type);
  if (!list) { list = []; map.set(type, list); }
  for (let i = 0; i < list.length; i++) {
    const l = list[i];
    if (l.cb === cb && l.capture === capture) return;
  }
  const l = { cb, capture, once, passive, removed: false, handler: false };
  list.push(l);
  $.ep++;
  $.listen(type);
  if (signal) signal.addEventListener("abort", () => removeFrom(t, type, l));
}

function removeFrom(t, type, l) {
  l.removed = true;
  const map = t[LS]; if (!map) return;
  const list = map.get(type); if (!list) return;
  const i = list.indexOf(l);
  if (i >= 0) list.splice(i, 1);
}

function removeEventListener(type, cb, opts) {
  const t = targetOf(this);
  const map = t[LS]; if (!map) return;
  type = String(type);
  const list = map.get(type); if (!list) return;
  const capture = typeof opts === "boolean" ? opts : !!(opts && opts.capture);
  for (let i = 0; i < list.length; i++) {
    const l = list[i];
    if (l.cb === cb && l.capture === capture) return removeFrom(t, type, l);
  }
}

// A `load` stops at the document: the window's own is its own event.
function pathOf(target, type) {
  return $.eventPath(target, type);
}

function report(e) { $.reportError(e); }

// `this` for an inline handler's free names: `value`, `form`, `submit()`. There is
// no `with` here, so the names it uses that the element, its form or the document
// have are passed in as parameters: reads work, assigning to a bare one doesn't.
function compileInline(t, type, src) {
  const names = [], values = [];
  const scopes = [t];
  if (t.form) scopes.push(t.form);
  if (t.ownerDocument) scopes.push(t.ownerDocument);
  const seen = new Set(["event", "this"]);
  for (const m of src.matchAll(/(^|[^.\w$])([A-Za-z_$][\w$]*)/g)) {
    const name = m[2];
    if (seen.has(name)) continue;
    seen.add(name);
    if (name in g && !(name in t)) continue;
    for (const s of scopes) {
      if (name in s && !/^(?:if|else|for|while|do|return|function|var|let|const|new|typeof|void|delete|in|of|this|null|true|false|try|catch|finally|throw|switch|case|default|break|continue|class|with|yield|await|async|instanceof|super|export|import|extends)$/.test(name)) {
        names.push(name);
        const v = s[name];
        values.push(typeof v === "function" ? v.bind(s) : v);
        break;
      }
    }
  }
  const f = new Function("event", ...names, src);
  return function (ev) { return f.call(this, ev, ...values); };
}

function handlerStore(t) {
  let s = t[HANDLERS];
  if (!s) { s = Object.create(null); def(t, HANDLERS, s); $.markTarget(t); }
  return s;
}

// The function an attribute's text compiles to, kept until the text changes.
function inlineHandler(t, type, src) {
  const s = handlerStore(t);
  const key = "attr:" + type;
  const c = s[key];
  if (c && c.src === src) return c.f;
  let f = null;
  try { f = compileInline(t, type, src); } catch (e) { report(e); }
  s[key] = { src, f };
  return f;
}

const windowBodyEvents = new Set(["load", "unload", "beforeunload", "resize", "scroll", "hashchange", "popstate", "message", "pageshow", "pagehide", "online", "offline", "error", "focus", "blur"]);

function callHandler(t, ev, f) {
  try {
    let r;
    if (t === g && ev.type === "error" && ev instanceof ErrorEvent) {
      r = f.call(t, ev.message, ev.filename, ev.lineno, ev.colno, ev.error);
      if (r === true) ev.preventDefault();
      return;
    }
    r = f.call(t, ev);
    if (ev.type === "beforeunload") return;
    if (r === false) ev.preventDefault();
  } catch (e) { report(e); }
}

// The `on…` handler of this target: its property, else its attribute's.
function runHandler(t, ev) {
  const s = t[HANDLERS];
  const type = ev.type;
  if (!s && t === g && !windowBodyEvents.has(type)) return;
  const src = t === g ? (windowBodyEvents.has(type) && g.document && g.document.body ? $.inlineAttr(g.document.body, type) : null) : $.inlineAttr(t, type);
  if (!s && src === null) return;
  const key = "prop:" + type;
  // A property holds unless the attribute was set after it.
  if (s && s[key] !== undefined && s["src:" + type] === src) {
    if (typeof s[key] === "function") callHandler(t, ev, s[key]);
    else if (s[key] && typeof s[key].handleEvent === "function") callHandler(t, ev, (e) => s[key].handleEvent(e));
    return;
  }
  if (src !== null) {
    const f = inlineHandler(t, type, src);
    if (f) callHandler(t, ev, f);
  }
}

function invoke(t, ev, phase, st) {
  if (st.stop) return;
  const map = t[LS];
  if (phase === 1) {
    if (!map) return;
    const list = map.get(ev.type);
    if (!list || list.length === 0) return;
    ev.currentTarget = t;
    ev.eventPhase = 1;
  } else {
    ev.currentTarget = t;
    ev.eventPhase = phase;
    runHandler(t, ev);
    if (st.stopNow || !map) return;
  }
  const list = map.get(ev.type); if (!list || list.length === 0) return;
  if (list.length === 1) {
    const l = list[0];
    if (l.removed || (phase === 1 && !l.capture) || (phase === 3 && l.capture)) return;
    if (l.once) removeFrom(t, ev.type, l);
    st.passive = l.passive;
    try {
      const cb = l.cb;
      if (typeof cb === "function") cb.call(t, ev);
      else if (typeof cb.handleEvent === "function") cb.handleEvent(ev);
    } catch (e) { report(e); }
    st.passive = false;
    return;
  }
  let any = false;
  for (let i = 0; i < list.length; i++) {
    const l = list[i];
    if (!l.removed && !(phase === 1 && !l.capture) && !(phase === 3 && l.capture)) { any = true; break; }
  }
  if (!any) return;
  const copy = list.slice();
  for (let i = 0; i < copy.length; i++) {
    const l = copy[i];
    if (l.removed) continue;
    if (phase === 1 && !l.capture) continue;
    if (phase === 3 && l.capture) continue;
    if (l.once) removeFrom(t, ev.type, l);
    st.passive = l.passive;
    try {
      const cb = l.cb;
      if (typeof cb === "function") cb.call(t, ev);
      else if (typeof cb.handleEvent === "function") cb.handleEvent(ev);
    } catch (e) { report(e); }
    st.passive = false;
    if (st.stopNow) break;
  }
}

let dispatchDepth = 0;
function dispatch(target, ev, st = state(ev)) {
  ev.target = target;
  st.active = true;
  st.stop = false; st.stopNow = false;
  let slot = -1, path;
  if (dispatchDepth < 8) {
    slot = dispatchDepth++;
    path = $.pushPath(target, ev.type);
    st.slot = slot;
    st.mat = matOf;
    st.activePath = path;
    st.path = null;
  } else {
    path = pathOf(target, ev.type);
    st.slot = -1;
    st.mat = null;
    st.path = path;
  }
  let ep = $.ep;
  const savedEvent = g.event;
  g.event = ev;
  for (let i = path.length - 1; i > 0; i--) {
    const cur = path[i];
    invoke(cur, ev, 1, st);
    if (ep !== $.ep && slot >= 0) {
      ep = $.ep;
      path = st.path || (st.path = $.materializePath(slot) || path);
      i = path.indexOf(cur);
    }
  }
  invoke(target, ev, 2, st);
  if (ep !== $.ep && slot >= 0) {
    ep = $.ep;
    path = st.path || (st.path = $.materializePath(slot) || path);
  }
  if (ev.bubbles) {
    for (let i = 1; i < path.length; i++) {
      const cur = path[i];
      invoke(cur, ev, 3, st);
      if (ep !== $.ep && slot >= 0) {
        ep = $.ep;
        path = st.path || (st.path = $.materializePath(slot) || path);
        i = path.indexOf(cur);
      }
    }
  }
  g.event = savedEvent;
  if (slot >= 0) { dispatchDepth--; $.popPath(); }
  st.active = false;
  ev.currentTarget = null;
  ev.eventPhase = 0;
  st.path = null;
  st.activePath = null;
  st.mat = null;
  st.slot = -1;
  return !st.canceled;
}

function dispatchEvent(ev) {
  const st = state(ev);
  if (!st) throw new TypeError("dispatchEvent: parameter 1 is not of type 'Event'");
  if (st.active) throw new DOMException("The event is already being dispatched.", "InvalidStateError");
  return dispatch(targetOf(this), ev, st);
}
$.dispatch = dispatch;

const et = EventTarget.prototype;
def(et, "addEventListener", addEventListener);
def(et, "removeEventListener", removeEventListener);
def(et, "dispatchEvent", dispatchEvent);

// `el.onclick` and friends.
function eventDesc(type) {
  return {
    configurable: true, enumerable: true,
    get() {
      const t = targetOf(this);
      const s = t[HANDLERS];
      const src = t === g ? null : $.inlineAttr(t, type);
      if (s && s["prop:" + type] !== undefined && (t === g || s["src:" + type] === src)) return s["prop:" + type];
      return src === null ? null : inlineHandler(t, type, src);
    },
    set(v) {
      const t = targetOf(this);
      const s = handlerStore(t);
      s["prop:" + type] = typeof v === "function" || (v && typeof v === "object") ? v : null;
      s["src:" + type] = t === g ? (g.document && g.document.body ? $.inlineAttr(g.document.body, type) : null) : $.inlineAttr(t, type);
      $.ep++;
      $.listen(type);
    },
  };
}
const allEvents = ["abort", "animationcancel", "animationend", "animationiteration", "animationstart", "auxclick", "beforeinput", "blur", "cancel", "canplay", "canplaythrough", "change", "click", "close", "contextmenu", "copy", "cut", "dblclick", "drag", "dragend", "dragenter", "dragleave", "dragover", "dragstart", "drop", "durationchange", "emptied", "ended", "error", "focus", "focusin", "focusout", "formdata", "gotpointercapture", "input", "invalid", "keydown", "keypress", "keyup", "load", "loadeddata", "loadedmetadata", "loadstart", "lostpointercapture", "mousedown", "mouseenter", "mouseleave", "mousemove", "mouseout", "mouseover", "mouseup", "paste", "pause", "play", "playing", "pointercancel", "pointerdown", "pointerenter", "pointerleave", "pointermove", "pointerout", "pointerover", "pointerup", "progress", "ratechange", "reset", "resize", "scroll", "scrollend", "seeked", "seeking", "select", "selectionchange", "stalled", "submit", "suspend", "timeupdate", "toggle", "touchcancel", "touchend", "touchmove", "touchstart", "transitioncancel", "transitionend", "transitionrun", "transitionstart", "volumechange", "waiting", "wheel"];
const windowOnly = ["afterprint", "beforeprint", "beforeunload", "hashchange", "languagechange", "message", "messageerror", "offline", "online", "pagehide", "pageshow", "popstate", "rejectionhandled", "storage", "unhandledrejection", "unload"];
for (const t of allEvents) { const name = "on" + t, d = eventDesc(t); Object.defineProperty(HTMLElement.prototype, name, d); Object.defineProperty(SVGElement.prototype, name, d); Object.defineProperty(Document.prototype, name, d); Object.defineProperty(g, name, d); }
for (const t of windowOnly) { const name = "on" + t, d = eventDesc(t); Object.defineProperty(g, name, d); Object.defineProperty(HTMLBodyElement.prototype, name, d); }
Object.defineProperty(Document.prototype, "onreadystatechange", eventDesc("readystatechange"));

// The Zig side's way in.
$.hook("fire", (target, type, bubbles, cancelable) => {
  let e;
  if (type === "input") e = new InputEvent(type, { bubbles, cancelable, inputType: "insertText" });
  else if (type === "submit") e = new SubmitEvent(type, { bubbles, cancelable });
  else e = new Event(type, { bubbles, cancelable });
  e.isTrusted = true;
  return dispatch(target, e);
});

$.hook("fireAnimation", (target, type, name, elapsed, pseudo) => {
  const e = type.startsWith("transition")
    ? new TransitionEvent(type, { bubbles: true, propertyName: name, elapsedTime: elapsed, pseudoElement: pseudo })
    : new AnimationEvent(type, { bubbles: true, animationName: name, elapsedTime: elapsed, pseudoElement: pseudo });
  e.isTrusted = true;
  return dispatch(target, e);
});

const trusted = (e) => { e.isTrusted = true; return e; };
let buttonsDown = 0;
const fireMouse = (target, type, x, y, ctrlKey, shiftKey, altKey, metaKey, related) => {
  const pointer = type === "mousedown" ? "pointerdown" : type === "mouseup" ? "pointerup" : null;
  if (type === "mousedown") buttonsDown = 1;
  const init = { bubbles: true, cancelable: true, composed: true, view: g, clientX: x, clientY: y, screenX: x, screenY: y, ctrlKey, shiftKey, altKey, metaKey, buttons: buttonsDown, button: 0, detail: type === "click" || pointer ? 1 : 0, relatedTarget: related || null };
  if (type === "mouseup") buttonsDown = 0;
  if (pointer) dispatch(target, trusted(new PointerEvent(pointer, init)));
  const e = new (type === "click" || type === "auxclick" || type === "contextmenu" ? PointerEvent : MouseEvent)(type, init);
  return dispatch(target, trusted(e));
};
$.hook("fireMouse", fireMouse);
$.hook("fireClick", (target) => dispatch(target, new MouseEvent("click", { bubbles: true, cancelable: true, composed: true, view: g, detail: 0 })));

// The pointer moved from `old` to `now`: over, out, enter, leave, move.
$.hook("firePointerMove", (old, now, x, y) => {
  const init = (extra) => Object.assign({ bubbles: true, cancelable: true, composed: true, view: g, clientX: x, clientY: y, screenX: x, screenY: y, buttons: buttonsDown }, extra);
  const both = (t, name, i) => {
    dispatch(t, trusted(new PointerEvent("pointer" + name, i)));
    dispatch(t, trusted(new MouseEvent("mouse" + name, i)));
  };
  if (old !== now) {
    if (old && old.isConnected) both(old, "out", init({ relatedTarget: now }));
    if (old && old.isConnected) for (let n = old; n && n.nodeType === 1 && !(now && n.contains(now)); n = n.parentElement) both(n, "leave", init({ relatedTarget: now, bubbles: false, cancelable: false }));
    if (now) both(now, "over", init({ relatedTarget: old }));
    if (now) {
      const entered = [];
      for (let n = now; n && n.nodeType === 1 && !(old && n.contains(old)); n = n.parentElement) entered.push(n);
      for (let i = entered.length - 1; i >= 0; i--) both(entered[i], "enter", init({ relatedTarget: old, bubbles: false, cancelable: false }));
    }
  }
  if (now) both(now, "move", init({}));
});

$.hook("fireWheel", (target, x, y, dx, dy, ctrlKey, shiftKey, altKey, metaKey) => dispatch(target, trusted(new WheelEvent("wheel", { bubbles: true, cancelable: true, composed: true, view: g, clientX: x, clientY: y, deltaX: dx, deltaY: dy, ctrlKey, shiftKey, altKey, metaKey }))));

$.hook("fireFocus", (old, now) => {
  if (old) {
    dispatch(old, trusted(new FocusEvent("blur", { view: g, relatedTarget: now })));
    dispatch(old, trusted(new FocusEvent("focusout", { bubbles: true, view: g, relatedTarget: now })));
  }
  if (now) {
    dispatch(now, trusted(new FocusEvent("focus", { view: g, relatedTarget: old })));
    dispatch(now, trusted(new FocusEvent("focusin", { bubbles: true, view: g, relatedTarget: old })));
  }
});

const keyCodes = { Backspace: 8, Tab: 9, Enter: 13, Escape: 27, PageUp: 33, PageDown: 34, End: 35, Home: 36, ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40, Delete: 46, F1: 112, F2: 113, F3: 114, F4: 115, F5: 116, F6: 117, F7: 118, F8: 119, F9: 120, F10: 121, F11: 122, F12: 123 };
function codeFor(key) {
  if (key.length === 1) {
    const c = key.toUpperCase();
    if (c >= "A" && c <= "Z") return "Key" + c;
    if (c >= "0" && c <= "9") return "Digit" + c;
    if (c === " ") return "Space";
    return "";
  }
  return key;
}
// True when no script prevented the key's default.
$.hook("fireKey", (target, key, printable, ctrlKey, shiftKey, altKey, metaKey) => {
  const keyCode = keyCodes[key] || (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0);
  const init = { bubbles: true, cancelable: true, composed: true, view: g, key, code: codeFor(key), keyCode, ctrlKey, shiftKey, altKey, metaKey };
  const go = dispatch(target, trusted(new KeyboardEvent("keydown", init)));
  if (go && (printable || key === "Enter")) {
    dispatch(target, trusted(new KeyboardEvent("keypress", Object.assign({}, init, { charCode: key === "Enter" ? 13 : key.charCodeAt(0), keyCode: key === "Enter" ? 13 : key.charCodeAt(0) }))));
  }
  dispatch(target, trusted(new KeyboardEvent("keyup", init)));
  return go;
});

$.hook("reportError", (e) => {
  $.reportError(e);
});
$.reportError = (e) => {
  const isErr = e instanceof Error;
  const message = isErr ? `${e.name}: ${e.message}` : "Uncaught " + String(e);
  const ev = new ErrorEvent("error", { bubbles: false, cancelable: true, message, filename: "", lineno: 0, colno: 0, error: e });
  ev.isTrusted = true;
  let handled = false;
  try { handled = !dispatch(g, ev); } catch (x) {}
  if (!handled) $.log(3, "Uncaught " + (isErr && e.stack ? e.stack : message));
};
$.hook("unhandled", (promise, reason) => {
  const ev = new PromiseRejectionEvent("unhandledrejection", { cancelable: true, promise, reason });
  ev.isTrusted = true;
  if (dispatch(g, ev)) {
    const isErr = reason instanceof Error;
    $.log(3, "Uncaught (in promise) " + (isErr && reason.stack ? reason.stack : String(reason)));
  }
});
})
