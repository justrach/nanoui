// What is left of the HTML element classes: reflected attributes, and each tag's
// class of its own. Canvas `getContext` answers null, media elements are inert,
// an iframe has no document: scripts see them as not available.
(function ($, g) {
"use strict";
const def = $.def;
const accessor = (o, name, get, set) => Object.defineProperty(o, name, { get, set, configurable: true, enumerable: true });

const str = (proto, ...names) => {
  for (const name of names) {
    const attr = name.toLowerCase();
    accessor(proto, name, function () { const v = this.getAttribute(attr); return v === null ? "" : v; }, function (v) { this.setAttribute(attr, v); });
  }
};
const bool = (proto, ...names) => {
  for (const name of names) {
    const attr = name.toLowerCase();
    accessor(proto, name, function () { return this.hasAttribute(attr); }, function (v) { if (v) this.setAttribute(attr, ""); else this.removeAttribute(attr); });
  }
};
const num = (proto, dflt, ...names) => {
  for (const name of names) {
    const attr = name.toLowerCase();
    accessor(proto, name, function () { const v = parseInt(this.getAttribute(attr), 10); return v === v ? v : dflt; }, function (v) { this.setAttribute(attr, String(v)); });
  }
};
const url = (proto, ...names) => {
  for (const name of names) {
    const attr = name.toLowerCase();
    accessor(proto, name, function () { const v = this.getAttribute(attr); if (v === null) return ""; const r = $.resolveUrl(v); return r === null ? v : r; }, function (v) { this.setAttribute(attr, v); });
  }
};

const HP = HTMLElement.prototype;
str(HP, "title", "lang", "accessKey", "nonce", "slot");
bool(HP, "hidden", "inert", "autofocus");
accessor(HP, "dir", function () { return this.getAttribute("dir") || ""; }, function (v) { this.setAttribute("dir", v); });
accessor(HP, "tabIndex", function () { const v = parseInt(this.getAttribute("tabindex"), 10); return v === v ? v : /^(?:A|AREA|BUTTON|INPUT|SELECT|TEXTAREA|IFRAME)$/.test(this.tagName) ? 0 : -1; }, function (v) { this.setAttribute("tabindex", String(v)); });
accessor(HP, "contentEditable", function () { return this.getAttribute("contenteditable") || "inherit"; }, function (v) { this.setAttribute("contenteditable", v); });
accessor(HP, "isContentEditable", function () { return this.hasAttribute("contenteditable"); });
accessor(HP, "draggable", function () { return this.getAttribute("draggable") === "true"; }, function (v) { this.setAttribute("draggable", String(!!v)); });
accessor(HP, "spellcheck", function () { return this.getAttribute("spellcheck") !== "false"; }, function (v) { this.setAttribute("spellcheck", String(!!v)); });
accessor(HP, "translate", function () { return this.getAttribute("translate") !== "no"; }, function (v) { this.setAttribute("translate", v ? "yes" : "no"); });
accessor(HP, "innerText", function () { return this.textContent; }, function (v) { this.textContent = v; });
accessor(HP, "outerText", function () { return this.textContent; }, function (v) { this.textContent = v; });
accessor(HP, "autocapitalize", function () { return this.getAttribute("autocapitalize") || ""; }, function (v) { this.setAttribute("autocapitalize", v); });
accessor(HP, "enterKeyHint", function () { return this.getAttribute("enterkeyhint") || ""; }, function (v) { this.setAttribute("enterkeyhint", v); });
accessor(HP, "inputMode", function () { return this.getAttribute("inputmode") || ""; }, function (v) { this.setAttribute("inputmode", v); });
accessor(HP, "popover", function () { return this.getAttribute("popover"); }, function (v) { if (v === null) this.removeAttribute("popover"); else this.setAttribute("popover", v); });
def(HP, "attachInternals", function () { return { setFormValue() {}, setValidity() {}, checkValidity() { return true; }, reportValidity() { return true; }, states: new Set(), shadowRoot: this.shadowRoot, form: null, labels: [] }; });
accessor(SVGElement.prototype, "ownerSVGElement", function () { let n = this.parentElement; while (n && n.tagName !== "svg") n = n.parentElement; return n; });
str(SVGElement.prototype, "nonce");
accessor(SVGElement.prototype, "className", function () { return this.getAttribute("class") || ""; }, function (v) { this.setAttribute("class", v); });
def(SVGElement.prototype, "getBBox", function () { return this.getBoundingClientRect(); });
accessor(Element.prototype, "slot", function () { return this.getAttribute("slot") || ""; }, function (v) { this.setAttribute("slot", v); });

// Links, and the URL's parts as properties.
function splitUrl(s) {
  const m = /^([a-z][a-z0-9+.-]*:)(?:\/\/(?:[^/?#@]*@)?([^/?#:]*)(?::(\d*))?)?([^?#]*)(\?[^#]*)?(#.*)?$/i.exec(s);
  if (!m) return { protocol: "", hostname: "", port: "", pathname: "", search: "", hash: "" };
  return { protocol: m[1].toLowerCase(), hostname: m[2] || "", port: m[3] || "", pathname: m[4] || (m[2] ? "/" : ""), search: m[5] && m[5] !== "?" ? m[5] : "", hash: m[6] && m[6] !== "#" ? m[6] : "" };
}
$.splitUrl = splitUrl;
function originOf(u) { return u.hostname ? u.protocol + "//" + u.hostname + (u.port ? ":" + u.port : "") : "null"; }
$.originOf = originOf;
function joinUrl(u) { return u.protocol + (u.hostname ? "//" + u.hostname + (u.port ? ":" + u.port : "") : "") + u.pathname + u.search + u.hash; }
$.joinUrl = joinUrl;
function urlParts(proto, attr) {
  const part = (name, get, set) => accessor(proto, name, function () {
    const v = this.getAttribute(attr);
    return v === null ? "" : get(splitUrl($.resolveUrl(v) || v));
  }, function (x) {
    const v = this.getAttribute(attr);
    const u = splitUrl($.resolveUrl(v === null ? "" : v) || "");
    set(u, String(x));
    this.setAttribute(attr, joinUrl(u));
  });
  part("protocol", (u) => u.protocol, (u, x) => { u.protocol = x.endsWith(":") ? x : x + ":"; });
  part("host", (u) => u.hostname + (u.port ? ":" + u.port : ""), (u, x) => { const [h, p] = x.split(":"); u.hostname = h; u.port = p || ""; });
  part("hostname", (u) => u.hostname, (u, x) => { u.hostname = x; });
  part("port", (u) => u.port, (u, x) => { u.port = x; });
  part("pathname", (u) => u.pathname, (u, x) => { u.pathname = x.startsWith("/") ? x : "/" + x; });
  part("search", (u) => u.search, (u, x) => { u.search = !x || x === "?" ? "" : x.startsWith("?") ? x : "?" + x; });
  part("hash", (u) => u.hash, (u, x) => { u.hash = !x || x === "#" ? "" : x.startsWith("#") ? x : "#" + x; });
  accessor(proto, "origin", function () { const v = this.getAttribute(attr); return v === null ? "" : originOf(splitUrl($.resolveUrl(v) || v)); });
  accessor(proto, "username", function () { return ""; }, function () {});
  accessor(proto, "password", function () { return ""; }, function () {});
  def(proto, "toString", function () { return this.href; });
}
for (const P of [HTMLAnchorElement.prototype, HTMLAreaElement.prototype]) {
  url(P, "href");
  str(P, "target", "rel", "download", "referrerPolicy", "ping", "type", "hreflang");
  urlParts(P, "href");
}
accessor(HTMLAnchorElement.prototype, "text", function () { return this.textContent; }, function (v) { this.textContent = v; });
str(HTMLAreaElement.prototype, "alt", "coords", "shape");

// Pictures. The natives ask for it as `src` changes; `load` and `error` come from
// the loader.
const IP = HTMLImageElement.prototype;
str(IP, "alt", "srcset", "sizes", "crossOrigin", "useMap", "loading", "decoding", "referrerPolicy");
url(IP, "src");
bool(IP, "isMap");
accessor(IP, "width", function () { const a = parseInt(this.getAttribute("width"), 10); return a === a ? a : this.offsetWidth || this.naturalWidth; }, function (v) { this.setAttribute("width", String(v)); });
accessor(IP, "height", function () { const a = parseInt(this.getAttribute("height"), 10); return a === a ? a : this.offsetHeight || this.naturalHeight; }, function (v) { this.setAttribute("height", String(v)); });
def(IP, "decode", function () { return Promise.resolve(); });
$.hook("imageDone", () => {
  const list = $.takeImages();
  for (let i = 0; i + 1 < list.length; i += 2) {
    const e = new Event(list[i + 1] ? "load" : "error");
    e.isTrusted = true;
    $.dispatch(list[i], e);
  }
});
function Image(w, h) {
  const el = document.createElement("img");
  if (w !== undefined) el.setAttribute("width", String(w));
  if (h !== undefined) el.setAttribute("height", String(h));
  return el;
}
Image.prototype = IP;
def(g, "Image", Image);
const document = $.document;
function Option(text, value, dflt, selected) {
  const el = document.createElement("option");
  if (text !== undefined) el.textContent = String(text);
  if (value !== undefined) el.setAttribute("value", String(value));
  if (dflt) el.setAttribute("selected", "");
  if (selected) el.selected = true;
  return el;
}
Option.prototype = HTMLOptionElement.prototype;
def(g, "Option", Option);
function Audio(src) { const el = document.createElement("audio"); if (src !== undefined) el.setAttribute("src", String(src)); return el; }
Audio.prototype = HTMLAudioElement.prototype;
def(g, "Audio", Audio);

// Controls. What has a value of its own is native.
const validity = { valid: true, valueMissing: false, typeMismatch: false, patternMismatch: false, tooLong: false, tooShort: false, rangeUnderflow: false, rangeOverflow: false, stepMismatch: false, badInput: false, customError: false };
const control = {
  checkValidity() { return true; },
  reportValidity() { return true; },
  setCustomValidity() {},
};
function formProp(proto) {
  accessor(proto, "form", function () {
    const id = this.getAttribute("form");
    if (id) return this.ownerDocument.getElementById(id);
    return this.closest("form");
  });
  accessor(proto, "labels", function () {
    const out = [];
    if (this.id) for (const l of this.ownerDocument.querySelectorAll("label")) if (l.getAttribute("for") === this.id) out.push(l);
    const p = this.closest("label"); if (p && !out.includes(p)) out.push(p);
    return out;
  });
  accessor(proto, "validity", function () { return validity; });
  accessor(proto, "validationMessage", function () { return ""; });
  accessor(proto, "willValidate", function () { return true; });
  for (const k in control) def(proto, k, control[k]);
}
const textPlace = new WeakMap();
const selection = {
  select() { const n = this.value.length; textPlace.set(this, [0, n]); },
  setSelectionRange(a, b) { textPlace.set(this, [a, b]); },
  setRangeText(s, a, b) { const v = this.value; const r = textPlace.get(this) || [v.length, v.length]; if (a === undefined) { a = r[0]; b = r[1]; } this.value = v.slice(0, a) + s + v.slice(b); },
};
function selectable(proto) {
  for (const k in selection) def(proto, k, selection[k]);
  accessor(proto, "selectionStart", function () { const r = textPlace.get(this); return r ? r[0] : this.value.length; }, function (v) { const r = textPlace.get(this) || [v, v]; textPlace.set(this, [v, Math.max(v, r[1])]); });
  accessor(proto, "selectionEnd", function () { const r = textPlace.get(this); return r ? r[1] : this.value.length; }, function (v) { const r = textPlace.get(this) || [v, v]; textPlace.set(this, [Math.min(v, r[0]), v]); });
  accessor(proto, "selectionDirection", function () { return "none"; }, function () {});
}
const INP = HTMLInputElement.prototype;
formProp(INP); selectable(INP);
str(INP, "name", "placeholder", "accept", "alt", "autocomplete", "dirName", "formAction", "formEnctype", "formMethod", "formTarget", "list", "max", "min", "pattern", "step", "inputMode");
url(INP, "src");
bool(INP, "disabled", "readOnly", "required", "multiple", "formNoValidate");
num(INP, -1, "maxLength", "minLength");
num(INP, 20, "size");
accessor(INP, "indeterminate", function () { return !!this.__indeterminate; }, function (v) { this.__indeterminate = !!v; });
accessor(INP, "type", function () {
  const t = (this.getAttribute("type") || "text").toLowerCase();
  return /^(?:hidden|text|search|tel|url|email|password|date|month|week|time|datetime-local|number|range|color|checkbox|radio|file|submit|image|reset|button)$/.test(t) ? t : "text";
}, function (v) { this.setAttribute("type", v); });
accessor(INP, "files", function () { return this.type === "file" ? [] : null; }, function () {});
accessor(INP, "valueAsNumber", function () { return parseFloat(this.value); }, function (v) { this.value = String(v); });
accessor(INP, "valueAsDate", function () { return this.value ? new Date(this.value) : null; }, function (v) { this.value = v ? v.toISOString().slice(0, 10) : ""; });
def(INP, "stepUp", function (n = 1) { this.value = String(parseFloat(this.value || "0") + n); });
def(INP, "stepDown", function (n = 1) { this.value = String(parseFloat(this.value || "0") - n); });
def(INP, "showPicker", function () {});
const TA = HTMLTextAreaElement.prototype;
formProp(TA); selectable(TA);
str(TA, "name", "placeholder", "autocomplete", "wrap", "dirName");
bool(TA, "disabled", "readOnly", "required");
num(TA, 2, "rows"); num(TA, 20, "cols"); num(TA, -1, "maxLength", "minLength");
accessor(TA, "type", function () { return "textarea"; });
accessor(TA, "textLength", function () { return this.value.length; });
const BTN = HTMLButtonElement.prototype;
formProp(BTN);
str(BTN, "name", "formAction", "formEnctype", "formMethod", "formTarget", "value", "popoverTargetAction");
bool(BTN, "disabled", "formNoValidate");
accessor(BTN, "type", function () { const t = (this.getAttribute("type") || "submit").toLowerCase(); return t === "button" || t === "reset" ? t : "submit"; }, function (v) { this.setAttribute("type", v); });
const SEL = HTMLSelectElement.prototype;
formProp(SEL);
str(SEL, "name", "autocomplete");
bool(SEL, "disabled", "multiple", "required");
num(SEL, 0, "size");
accessor(SEL, "type", function () { return this.hasAttribute("multiple") ? "select-multiple" : "select-one"; });
accessor(SEL, "options", function () {
  const sel = this;
  const list = Array.from(this.querySelectorAll("option"));
  list.item = (i) => list[i] || null;
  list.namedItem = (n) => list.find((o) => o.id === n || o.getAttribute("name") === n) || null;
  list.add = (o, before) => sel.add(o, before);
  list.remove = (i) => sel.remove(i);
  Object.defineProperty(list, "selectedIndex", { get() { return sel.selectedIndex; }, set(v) { sel.selectedIndex = v; } });
  return list;
});
accessor(SEL, "selectedOptions", function () { return this.selectedIndex < 0 ? [] : Array.from(this.querySelectorAll("option")).filter((o) => o.selected); });
accessor(SEL, "length", function () { return this.querySelectorAll("option").length; }, function () {});
def(SEL, "item", function (i) { return this.querySelectorAll("option")[i] || null; });
def(SEL, "namedItem", function (n) { return this.options.namedItem(n); });
def(SEL, "add", function (o, before) { this.insertBefore(o, typeof before === "number" ? this.options[before] || null : before || null); });
const elementRemove = Element.prototype.remove;
def(SEL, "remove", function (i) { if (i === undefined) return elementRemove.call(this); const o = this.querySelectorAll("option")[i]; if (o) o.remove(); });
const OPT = HTMLOptionElement.prototype;
str(OPT, "label");
accessor(OPT, "label", function () { return this.getAttribute("label") || this.textContent; }, function (v) { this.setAttribute("label", v); });
bool(OPT, "disabled");
accessor(OPT, "defaultSelected", function () { return this.hasAttribute("selected"); }, function (v) { if (v) this.setAttribute("selected", ""); else this.removeAttribute("selected"); });
accessor(OPT, "text", function () { return this.textContent.trim(); }, function (v) { this.textContent = v; });
accessor(OPT, "form", function () { return this.closest("form"); });
accessor(OPT, "index", function () { const s = this.closest("select"); return s ? Array.from(s.querySelectorAll("option")).indexOf(this) : 0; });
bool(HTMLOptGroupElement.prototype, "disabled");
str(HTMLOptGroupElement.prototype, "label");
for (const P of [HTMLFieldSetElement.prototype, HTMLOutputElement.prototype, HTMLObjectElement.prototype, HTMLMeterElement.prototype, HTMLProgressElement.prototype]) formProp(P);
bool(HTMLFieldSetElement.prototype, "disabled");
str(HTMLFieldSetElement.prototype, "name");
accessor(HTMLFieldSetElement.prototype, "elements", function () { return Array.from(this.querySelectorAll("input,select,textarea,button,fieldset,output,object")); });
accessor(HTMLLabelElement.prototype, "htmlFor", function () { return this.getAttribute("for") || ""; }, function (v) { this.setAttribute("for", v); });
accessor(HTMLLabelElement.prototype, "form", function () { return this.closest("form"); });
accessor(HTMLLabelElement.prototype, "control", function () { const f = this.getAttribute("for"); return f ? this.ownerDocument.getElementById(f) : this.querySelector("input,select,textarea,button,meter,output,progress"); });
accessor(HTMLOutputElement.prototype, "value", function () { return this.textContent; }, function (v) { this.textContent = v; });
num(HTMLProgressElement.prototype, 0, "value", "max");
num(HTMLMeterElement.prototype, 0, "value", "min", "max", "low", "high", "optimum");
num(HTMLLIElement.prototype, 0, "value");
num(HTMLOListElement.prototype, 1, "start");
bool(HTMLOListElement.prototype, "reversed");
str(HTMLOListElement.prototype, "type");

const FP = HTMLFormElement.prototype;
str(FP, "name", "target", "method", "enctype", "acceptCharset", "autocomplete", "rel");
bool(FP, "noValidate");
accessor(FP, "action", function () { const v = this.getAttribute("action"); return $.resolveUrl(v === null ? "" : v) || ""; }, function (v) { this.setAttribute("action", v); });
accessor(FP, "encoding", function () { return this.enctype; }, function (v) { this.enctype = v; });
accessor(FP, "elements", function () {
  const list = Array.from(this.querySelectorAll("input,select,textarea,button,fieldset,output,object")).filter((e) => e.tagName !== "INPUT" || e.type !== "image");
  list.item = (i) => list[i] || null;
  list.namedItem = (n) => list.find((e) => e.id === n || e.getAttribute("name") === n) || null;
  for (const e of list) { const n = e.getAttribute("name") || e.id; if (n && !(n in list)) list[n] = e; }
  return list;
});
accessor(FP, "length", function () { return this.elements.length; });
for (const k in control) def(FP, k, control[k]);

// What else tags have.
const LP = HTMLLinkElement.prototype;
url(LP, "href");
str(LP, "rel", "media", "type", "as", "crossOrigin", "hreflang", "integrity", "imageSrcset", "imageSizes", "referrerPolicy", "fetchPriority");
bool(LP, "disabled");
const SCP = HTMLScriptElement.prototype;
url(SCP, "src");
str(SCP, "type", "charset", "crossOrigin", "integrity", "referrerPolicy", "fetchPriority");
bool(SCP, "defer", "noModule");
accessor(SCP, "async", function () { return this.hasAttribute("async") || !($.isOrdered(this) || $.wasStarted(this)); }, function (v) { if (v) { this.setAttribute("async", ""); $.setOrdered(this, false); } else { this.removeAttribute("async"); $.setOrdered(this, true); } });
accessor(SCP, "text", function () { return this.textContent; }, function (v) { this.textContent = v; });
def(HTMLScriptElement, "supports", (t) => t === "classic" || t === "module" || t === "importmap");
str(HTMLBaseElement.prototype, "target");
url(HTMLBaseElement.prototype, "href");
str(HTMLMetaElement.prototype, "name", "content", "httpEquiv", "media", "scheme");
accessor(HTMLMetaElement.prototype, "httpEquiv", function () { return this.getAttribute("http-equiv") || ""; }, function (v) { this.setAttribute("http-equiv", v); });
str(HTMLBodyElement.prototype, "text", "link", "vLink", "aLink", "bgColor", "background");
str(HTMLHtmlElement.prototype, "version");
accessor(HTMLTitleElement.prototype, "text", function () { return this.textContent; }, function (v) { this.textContent = v; });
str(HTMLTableElement.prototype, "align", "border", "frame", "rules", "summary", "width", "bgColor", "cellPadding", "cellSpacing");
str(HTMLTableCellElement.prototype, "abbr", "headers", "scope", "align", "axis", "height", "width", "ch", "chOff", "vAlign", "bgColor");
num(HTMLTableCellElement.prototype, 1, "colSpan", "rowSpan");
accessor(HTMLTableCellElement.prototype, "cellIndex", function () { const p = this.parentElement; return p ? Array.prototype.indexOf.call(p.children, this) : -1; });
accessor(HTMLTableRowElement.prototype, "cells", function () { return this.children; });
accessor(HTMLTableRowElement.prototype, "rowIndex", function () { const t = this.closest("table"); return t ? Array.prototype.indexOf.call(t.rows, this) : -1; });
def(HTMLTableRowElement.prototype, "insertCell", function (i = -1) { const c = this.ownerDocument.createElement("td"); this.insertBefore(c, i < 0 ? null : this.children[i] || null); return c; });
def(HTMLTableRowElement.prototype, "deleteCell", function (i) { const c = this.children[i]; if (c) c.remove(); });
accessor(HTMLTableSectionElement.prototype, "rows", function () { return this.children; });
def(HTMLTableSectionElement.prototype, "insertRow", function (i = -1) { const r = this.ownerDocument.createElement("tr"); this.insertBefore(r, i < 0 ? null : this.children[i] || null); return r; });
def(HTMLTableSectionElement.prototype, "deleteRow", function (i) { const c = this.children[i]; if (c) c.remove(); });
const TP = HTMLTableElement.prototype;
accessor(TP, "rows", function () { return this.querySelectorAll("tr"); });
accessor(TP, "tBodies", function () { return Array.from(this.children).filter((c) => c.tagName === "TBODY"); });
accessor(TP, "tHead", function () { return this.querySelector(":scope > thead"); });
accessor(TP, "tFoot", function () { return this.querySelector(":scope > tfoot"); });
accessor(TP, "caption", function () { return this.querySelector(":scope > caption"); });
def(TP, "insertRow", function (i = -1) { let b = this.tBodies[0]; if (!b) { b = this.ownerDocument.createElement("tbody"); this.appendChild(b); } return b.insertRow(i); });
def(TP, "deleteRow", function (i) { const r = this.rows[i]; if (r) r.remove(); });
bool(HTMLDetailsElement.prototype, "open");
bool(HTMLDialogElement.prototype, "open");
accessor(HTMLDialogElement.prototype, "returnValue", function () { return this.__return || ""; }, function (v) { this.__return = v; });
def(HTMLDialogElement.prototype, "show", function () { this.setAttribute("open", ""); });
// Above everything, with what's outside it taking no input.
def(HTMLDialogElement.prototype, "showModal", function () {
  if (this.hasAttribute("open")) {
    if (this.matches(":modal")) return;
    throw new DOMException("The element already has an 'open' attribute, and therefore cannot be opened modally.", "InvalidStateError");
  }
  if (!this.isConnected) throw new DOMException("The element is not in a Document.", "InvalidStateError");
  this.setAttribute("open", "");
  $.topLayer(this, true, true);
});
def(HTMLDialogElement.prototype, "close", function (v) {
  if (!this.hasAttribute("open")) return;
  this.removeAttribute("open");
  $.topLayer(this, false, false);
  if (v !== undefined) this.returnValue = v;
  g.setTimeout(() => $.dispatch(this, new Event("close")), 0);
});
def(HTMLDialogElement.prototype, "requestClose", function (v) {
  if (!this.hasAttribute("open")) return;
  if ($.dispatch(this, new Event("cancel", { cancelable: true }))) this.close(v);
});
// Popovers: in the top layer while showing.
const popoverEvent = (el, type, oldState, newState) => {
  const e = new Event(type, { cancelable: type === "beforetoggle" });
  e.oldState = oldState;
  e.newState = newState;
  return $.dispatch(el, e);
};
const showPopover = (el) => {
  if (!el.hasAttribute("popover")) throw new DOMException("Not supported on elements that do not have a valid value for the 'popover' attribute.", "NotSupportedError");
  if ($.popoverOpen(el)) return;
  if (!popoverEvent(el, "beforetoggle", "closed", "open")) return;
  if (el.getAttribute("popover") !== "manual") for (const other of [...document.querySelectorAll("[popover]:popover-open")]) if (other !== el && !other.contains(el) && other.getAttribute("popover") !== "manual") hidePopover(other);
  $.popoverOpen(el, true);
  g.setTimeout(() => popoverEvent(el, "toggle", "closed", "open"), 0);
};
const hidePopover = (el) => {
  if (!$.popoverOpen(el)) return;
  popoverEvent(el, "beforetoggle", "open", "closed");
  $.popoverOpen(el, false);
  g.setTimeout(() => popoverEvent(el, "toggle", "open", "closed"), 0);
};
def(HP, "showPopover", function () { showPopover(this); });
def(HP, "hidePopover", function () { hidePopover(this); });
def(HP, "togglePopover", function (force) {
  const open = $.popoverOpen(this);
  const want = force === undefined || typeof force === "object" ? !open : !!force;
  if (want) showPopover(this); else hidePopover(this);
  return want;
});
accessor(HP, "popover", function () {
  const v = this.getAttribute("popover");
  if (v === null) return null;
  return v.toLowerCase() === "manual" || v.toLowerCase() === "hint" ? v.toLowerCase() : "auto";
}, function (v) { if (v === null) this.removeAttribute("popover"); else this.setAttribute("popover", v); });
// A press outside closes `auto` popovers; Escape the top of what's showing.
$.hook("lightDismiss", (target) => {
  for (const el of [...document.querySelectorAll("[popover]:popover-open")]) if (el.getAttribute("popover") !== "manual" && !(target && el.contains(target))) hidePopover(el);
});
$.hook("closeWatcher", () => {
  const open = [...document.querySelectorAll("dialog:modal, [popover]:popover-open")];
  const top = open[open.length - 1];
  if (!top) return;
  if (top.localName === "dialog") top.requestClose(); else hidePopover(top);
});
// `popovertarget` and `commandfor` on a button.
$.hook("invoke", (button) => {
  const id = button.getAttribute("popovertarget") || button.getAttribute("commandfor");
  const target = id && document.getElementById(id);
  if (!target) return false;
  const action = (button.getAttribute("popovertargetaction") || button.getAttribute("command") || "toggle").toLowerCase();
  if (action === "show-modal") target.showModal();
  else if (action === "close") target.close();
  else if (action === "request-close") target.requestClose();
  else if (action === "show" || action === "show-popover") showPopover(target);
  else if (action === "hide" || action === "hide-popover") hidePopover(target);
  else target.togglePopover();
  return true;
});
// A `<details>` that opened: others of its name close, and it tells.
$.hook("detailsToggled", (el) => {
  const name = el.getAttribute("name");
  if (name && el.hasAttribute("open")) for (const other of el.getRootNode().querySelectorAll(`details[name="${CSS.escape(name)}"][open]`)) if (other !== el) other.removeAttribute("open");
  g.setTimeout(() => $.dispatch(el, new Event("toggle")), 0);
});
str(HTMLSlotElement.prototype, "name");
def(HTMLSlotElement.prototype, "assignedNodes", function () {
  const root = this.getRootNode();
  if (!(root instanceof ShadowRoot)) return [];
  const name = this.getAttribute("name") || "";
  return Array.from(root.host.childNodes).filter((n) => (n.nodeType === 1 ? n.getAttribute("slot") || "" : "") === name && (n.nodeType === 1 || n.nodeType === 3));
});
def(HTMLSlotElement.prototype, "assignedElements", function () { return this.assignedNodes().filter((n) => n.nodeType === 1); });
str(HTMLTimeElement.prototype, "dateTime");
accessor(HTMLTimeElement.prototype, "dateTime", function () { return this.getAttribute("datetime") || ""; }, function (v) { this.setAttribute("datetime", v); });
str(HTMLDataElement.prototype, "value");
str(HTMLQuoteElement.prototype, "cite");
str(HTMLMapElement.prototype, "name");
url(HTMLSourceElement.prototype, "src");
str(HTMLSourceElement.prototype, "srcset", "sizes", "media", "type");
str(HTMLParamElement.prototype, "name", "value");
str(HTMLEmbedElement.prototype, "type", "width", "height");
url(HTMLEmbedElement.prototype, "src");
str(HTMLObjectElement.prototype, "type", "name", "width", "height");
url(HTMLObjectElement.prototype, "data");
str(HTMLTrackElement.prototype, "kind", "srclang", "label");
url(HTMLTrackElement.prototype, "src");
accessor(HTMLTrackElement.prototype, "track", function () { return { kind: this.getAttribute("kind") || "subtitles", mode: "disabled", cues: [], activeCues: [], addEventListener() {}, removeEventListener() {} }; });
str(HTMLFontElement.prototype, "color", "face", "size");

// A canvas draws nothing. WebGL is null, which libraries handle; '2d' answers with
// a context that does nothing, so a page's drawing code runs and its picture is
// simply blank, instead of its script dying on a null.
const CV = HTMLCanvasElement.prototype;
num(CV, 300, "width"); num(CV, 150, "height");
const gradient = { addColorStop() {} };
const context2d = (canvas) => {
  const ctx = {
    canvas, globalAlpha: 1, globalCompositeOperation: "source-over", fillStyle: "#000000", strokeStyle: "#000000", lineWidth: 1, lineCap: "butt", lineJoin: "miter", miterLimit: 10, lineDashOffset: 0, font: "10px sans-serif", textAlign: "start", textBaseline: "alphabetic", direction: "ltr", shadowBlur: 0, shadowColor: "rgba(0, 0, 0, 0)", shadowOffsetX: 0, shadowOffsetY: 0, imageSmoothingEnabled: true, imageSmoothingQuality: "low",
    createLinearGradient() { return gradient; }, createRadialGradient() { return gradient; }, createConicGradient() { return gradient; }, createPattern() { return {}; },
    measureText(t) { const m = /([\d.]+)px/.exec(ctx.font); const size = m ? parseFloat(m[1]) : 10; return { width: String(t).length * size * 0.5, actualBoundingBoxAscent: size * 0.8, actualBoundingBoxDescent: size * 0.2, actualBoundingBoxLeft: 0, actualBoundingBoxRight: 0, fontBoundingBoxAscent: size * 0.8, fontBoundingBoxDescent: size * 0.2 }; },
    getImageData(x, y, w, h) { return { width: w, height: h, data: new Uint8ClampedArray(w * h * 4), colorSpace: "srgb" }; },
    createImageData(w, h) { return { width: w, height: h, data: new Uint8ClampedArray(w * h * 4), colorSpace: "srgb" }; },
    getLineDash() { return []; }, getTransform() { return new DOMPoint(); }, isPointInPath() { return false; }, isPointInStroke() { return false; }, getContextAttributes() { return { alpha: true }; },
  };
  for (const name of ["save", "restore", "scale", "rotate", "translate", "transform", "setTransform", "resetTransform", "clearRect", "fillRect", "strokeRect", "beginPath", "closePath", "moveTo", "lineTo", "bezierCurveTo", "quadraticCurveTo", "arc", "arcTo", "ellipse", "rect", "roundRect", "fill", "stroke", "clip", "fillText", "strokeText", "drawImage", "putImageData", "setLineDash", "reset", "drawFocusIfNeeded"]) ctx[name] = function () {};
  return ctx;
};
const contexts = new WeakMap();
def(CV, "getContext", function (kind) {
  if (kind !== "2d") return null;
  let c = contexts.get(this);
  if (!c) { c = context2d(this); contexts.set(this, c); }
  return c;
});
def(CV, "toDataURL", function () { return "data:,"; });
def(CV, "toBlob", function (f) { g.setTimeout(() => f(null), 0); });
def(CV, "captureStream", function () { return null; });

// An iframe's window is another world's (`api_frames.zig`).
const IF = HTMLIFrameElement.prototype;
url(IF, "src");
str(IF, "srcdoc", "name", "sandbox", "allow", "width", "height", "referrerPolicy", "loading");
bool(IF, "allowFullscreen");
accessor(IF, "contentWindow", function () { return this.isConnected ? $.frameWindow(this) : null; });
accessor(IF, "contentDocument", function () {
  if (!this.isConnected) return null;
  const win = $.frameWindow(this);
  return win && $.frameShared(this) ? win.document : null;
});
def(IF, "getSVGDocument", function () { return null; });

// Media elements don't play.
// Bundles name these constants though no media ever plays here.
class MediaError { constructor(code, message) { this.code = code; this.message = message || ""; } }
Object.assign(MediaError, { MEDIA_ERR_ABORTED: 1, MEDIA_ERR_NETWORK: 2, MEDIA_ERR_DECODE: 3, MEDIA_ERR_SRC_NOT_SUPPORTED: 4 });
Object.assign(MediaError.prototype, { MEDIA_ERR_ABORTED: 1, MEDIA_ERR_NETWORK: 2, MEDIA_ERR_DECODE: 3, MEDIA_ERR_SRC_NOT_SUPPORTED: 4 });
def(g, "MediaError", MediaError);
const MP = HTMLMediaElement.prototype;
url(MP, "src");
str(MP, "crossOrigin", "preload");
bool(MP, "autoplay", "controls", "loop", "defaultMuted");
for (const [k, v] of [["paused", true], ["ended", false], ["seeking", false], ["readyState", 0], ["networkState", 0], ["duration", NaN], ["error", null], ["currentSrc", ""], ["videoWidth", 0], ["videoHeight", 0], ["buffered", { length: 0 }], ["played", { length: 0 }], ["seekable", { length: 0 }]]) accessor(MP, k, function () { return v; });
for (const [k, v] of [["currentTime", 0], ["volume", 1], ["muted", false], ["playbackRate", 1], ["defaultPlaybackRate", 1]]) {
  accessor(MP, k, function () { const s = this.__media; return s && k in s ? s[k] : v; }, function (x) { (this.__media || (this.__media = {}))[k] = x; });
}
accessor(MP, "textTracks", function () {
  const list = Array.from(this.querySelectorAll("track")).map((t) => ({ kind: t.getAttribute("kind") || "subtitles", label: t.getAttribute("label") || "", language: t.getAttribute("srclang") || "", mode: "disabled", cues: [], activeCues: [], addEventListener() {}, removeEventListener() {}, addCue() {}, removeCue() {} }));
  list.addEventListener = list.removeEventListener = () => {};
  list.getTrackById = () => null;
  return list;
});
def(MP, "play", function () { return Promise.reject(new DOMException("Media playback is not available.", "NotSupportedError")); });
def(MP, "pause", function () {});
def(MP, "load", function () {});
def(MP, "canPlayType", function () { return ""; });
num(HTMLVideoElement.prototype, 0, "width", "height");
url(HTMLVideoElement.prototype, "poster");

// Style sheets. A sheet's rules are text: inserting one rewrites its element's
// text and the page restyles. The CSSOM stops there (rules have `cssText`).
class CSSRule { constructor(text, sheet) { this.cssText = text; this.parentStyleSheet = sheet; const m = /^\s*([^{]*)\{/.exec(text); this.selectorText = m ? m[1].trim() : ""; this.type = text.trimStart().startsWith("@") ? 0 : 1; } }
class CSSStyleSheet {
  #el; #rules;
  constructor(el) {
    this.#el = el || null;
    this.#rules = null;
    this.disabled = false;
    this.ownerNode = el || null;
    this.type = "text/css";
    this.href = null;
    this.media = { mediaText: "" };
    this.parentStyleSheet = null;
    this.ownerRule = null;
    this.title = null;
  }
  #load() {
    if (this.#rules) return this.#rules;
    const text = this.#el && this.#el.tagName === "STYLE" ? this.#el.textContent : "";
    this.#rules = splitRules(text).map((t) => new CSSRule(t, this));
    return this.#rules;
  }
  #write() {
    if (this.#el && this.#el.tagName === "STYLE") $.setStyleText(this.#el, this.#rules.map((r) => r.cssText).join("\n"));
  }
  get cssRules() { return this.#load(); }
  get rules() { return this.#load(); }
  insertRule(text, i = 0) {
    const rules = this.#load();
    if (i < 0 || i > rules.length) throw new DOMException("The index provided is outside the range.", "IndexSizeError");
    rules.splice(i, 0, new CSSRule(String(text), this));
    this.#write();
    return i;
  }
  addRule(selector, style, i) { return this.insertRule(`${selector} { ${style} }`, i === undefined ? this.#load().length : i); }
  deleteRule(i) {
    const rules = this.#load();
    if (i < 0 || i >= rules.length) throw new DOMException("The index provided is outside the range.", "IndexSizeError");
    rules.splice(i, 1);
    this.#write();
  }
  removeRule(i) { this.deleteRule(i); }
  replace(text) { this.#rules = splitRules(String(text)).map((t) => new CSSRule(t, this)); this.#write(); return Promise.resolve(this); }
  replaceSync(text) { this.#rules = splitRules(String(text)).map((t) => new CSSRule(t, this)); this.#write(); }
}
function splitRules(text) {
  const out = []; let depth = 0, start = 0, quote = "";
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote) { if (c === "\\") i++; else if (c === quote) quote = ""; continue; }
    if (c === '"' || c === "'") quote = c;
    else if (c === "/" && text[i + 1] === "*") { const e = text.indexOf("*/", i + 2); i = e < 0 ? text.length : e + 1; }
    else if (c === "{") depth++;
    else if (c === "}") { if (--depth <= 0) { depth = 0; const r = text.slice(start, i + 1).trim(); if (r) out.push(r); start = i + 1; } }
    else if (c === ";" && depth === 0) { const r = text.slice(start, i + 1).trim(); if (r) out.push(r); start = i + 1; }
  }
  return out;
}
def(g, "CSSStyleSheet", CSSStyleSheet);
def(g, "CSSRule", CSSRule);
def(g, "StyleSheet", CSSStyleSheet);
def(g, "CSSStyleRule", CSSRule);
def(g, "CSSMediaRule", CSSRule);
def(g, "CSSSupportsRule", CSSRule);
const sheets = new WeakMap();
const sheetOf = (el) => { let s = sheets.get(el); if (!s) { s = new CSSStyleSheet(el); sheets.set(el, s); } return s; };
accessor(HTMLStyleElement.prototype, "sheet", function () { return this.isConnected ? sheetOf(this) : null; });
str(HTMLStyleElement.prototype, "media", "type", "nonce");
bool(HTMLStyleElement.prototype, "disabled");
accessor(LP, "sheet", function () { return this.isConnected && (this.getAttribute("rel") || "").toLowerCase().includes("stylesheet") ? sheetOf(this) : null; });
$.styleSheets = (doc) => {
  const list = Array.from(doc.querySelectorAll('style,link[rel~="stylesheet"]')).map(sheetOf);
  list.item = (i) => list[i] || null;
  return list;
};
})
