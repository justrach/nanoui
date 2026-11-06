// Messages between VMs (a worker, another frame's window, a port that went to
// either) cross as text, which makes them copies, as a structured clone is. Ports
// in `transfer` go with them; `prelude_observers.js` keeps them entangled.
(function ($, g) {
"use strict";

const typedArrays = ["Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array", "Int32Array", "Uint32Array", "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array"];

function cloneError(what) {
  return new g.DOMException(what + " could not be cloned.", "DataCloneError");
}

function pack(v, seen, ports) {
  switch (typeof v) {
    case "undefined": return { $nb: "undefined" };
    case "number": return Number.isFinite(v) && !Object.is(v, -0) ? v : { $nb: "number", d: String(v) };
    case "bigint": return { $nb: "bigint", d: String(v) };
    case "function": case "symbol": throw cloneError(String(v));
    case "string": case "boolean": return v;
  }
  if (v === null) return null;
  if (seen.includes(v)) throw cloneError("A circular value");
  seen.push(v);
  try {
    if (Array.isArray(v)) return v.map((x) => pack(x, seen, ports));
    if (ports.includes(v)) return { $nb: "port", i: ports.indexOf(v) };
    if (g.MessagePort && (v instanceof g.MessagePort || $.remotePort(v))) throw cloneError("A MessagePort not in the transfer list");
    if (v instanceof Date) return { $nb: "date", d: v.getTime() };
    if (v instanceof RegExp) return { $nb: "regexp", d: v.source, f: v.flags };
    if (v instanceof Map) return { $nb: "map", d: [...v].map(([a, b]) => [pack(a, seen, ports), pack(b, seen, ports)]) };
    if (v instanceof Set) return { $nb: "set", d: [...v].map((a) => pack(a, seen, ports)) };
    if (v instanceof ArrayBuffer) return { $nb: "ArrayBuffer", d: Array.from(new Uint8Array(v)) };
    if (ArrayBuffer.isView(v)) {
      const kind = v.constructor.name;
      if (!typedArrays.includes(kind)) return { $nb: "DataView", d: Array.from(new Uint8Array(v.buffer, v.byteOffset, v.byteLength)) };
      return { $nb: kind, d: Array.from(v, (x) => (typeof x === "bigint" ? String(x) : pack(x, seen, ports))) };
    }
    if (v instanceof Error) return { $nb: "error", n: v.name, d: v.message };
    const out = {};
    for (const k of Object.keys(v)) out[k] = pack(v[k], seen, ports);
    return out;
  } finally {
    seen.pop();
  }
}

function unpack(v, ports) {
  if (v === null || typeof v !== "object") return v;
  if (Array.isArray(v)) return v.map((x) => unpack(x, ports));
  switch (v.$nb) {
    case undefined: break;
    case "undefined": return undefined;
    case "port": return ports[v.i];
    case "number": return Number(v.d);
    case "bigint": return BigInt(v.d);
    case "date": return new Date(v.d);
    case "regexp": return new RegExp(v.d, v.f);
    case "map": return new Map(v.d.map(([a, b]) => [unpack(a, ports), unpack(b, ports)]));
    case "set": return new Set(v.d.map((x) => unpack(x, ports)));
    case "ArrayBuffer": return new Uint8Array(v.d).buffer;
    case "DataView": return new DataView(new Uint8Array(v.d).buffer);
    case "error": { const e = new (g[v.n] || Error)(v.d); return e; }
    case "BigInt64Array": case "BigUint64Array": return new g[v.$nb](v.d.map(BigInt));
    default: if (typedArrays.includes(v.$nb)) return new g[v.$nb](v.d.map((x) => unpack(x, ports)));
  }
  const out = {};
  for (const k of Object.keys(v)) out[k] = unpack(v[k], ports);
  return out;
}

function transferred(transfer) {
  const list = Array.isArray(transfer) ? transfer : transfer && transfer.transfer ? Array.from(transfer.transfer) : [];
  return list.filter((x) => g.MessagePort && (x instanceof g.MessagePort || $.remotePort(x)));
}

$.transferred = transferred;
// `postMessage(data, origin, transfer)` or `postMessage(data, options)`. An array as
// the second is an options dictionary with nothing in it, not a transfer list, however
// it looks: reCAPTCHA posts one to itself, and takes what comes for its peer's port.
$.windowTransfer = (target, transfer) => (transfer !== undefined ? transfer : target && typeof target === "object" ? target.transfer : undefined);
$.wire = (data, transfer) => {
  const ports = transferred(transfer);
  // Read first: a message that can't be sent mustn't take its ports away.
  const v = pack(data, [], ports);
  return JSON.stringify({ v, ports: ports.map($.portOut) });
};
$.unwire = (text) => {
  const m = JSON.parse(text);
  // Whoever gets a port may not have touched channels yet.
  const ports = m.ports && m.ports.length ? (void g.MessagePort, m.ports.map($.portIn)) : [];
  return { data: unpack(m.v, ports), ports };
};
})
