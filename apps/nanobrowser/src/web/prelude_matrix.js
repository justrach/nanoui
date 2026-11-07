// DOMMatrix: what scripts ask of a `transform`. Animation libraries read a computed
// transform this way to take its parts apart, and stop altogether if they can't.
(function ($, g) {
"use strict";

const identity = () => [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
const names = ["m11", "m12", "m13", "m14", "m21", "m22", "m23", "m24", "m31", "m32", "m33", "m34", "m41", "m42", "m43", "m44"];
const short = { a: 0, b: 1, c: 4, d: 5, e: 12, f: 13 };
const syntax = (text) => new g.DOMException(`Failed to parse '${text}' as a transform list.`, "SyntaxError");
const radians = (deg) => (deg * Math.PI) / 180;

// `a` then `b`: column vectors, so b applies first to a point.
function times(a, b) {
  const out = new Array(16);
  for (let c = 0; c < 4; c++) {
    for (let r = 0; r < 4; r++) {
      let sum = 0;
      for (let k = 0; k < 4; k++) sum += a[k * 4 + r] * b[c * 4 + k];
      out[c * 4 + r] = sum;
    }
  }
  return out;
}

const translation = (x, y, z) => { const m = identity(); m[12] = x; m[13] = y; m[14] = z; return m; };
const scaling = (x, y, z) => { const m = identity(); m[0] = x; m[5] = y; m[10] = z; return m; };
const skewing = (x, y) => { const m = identity(); m[4] = Math.tan(radians(x)); m[1] = Math.tan(radians(y)); return m; };

function rotation(x, y, z, deg) {
  const len = Math.hypot(x, y, z);
  if (len === 0) return identity();
  const [u, v, w] = [x / len, y / len, z / len];
  const c = Math.cos(radians(deg)), s = Math.sin(radians(deg)), t = 1 - c;
  return [
    t * u * u + c, t * u * v + s * w, t * u * w - s * v, 0,
    t * u * v - s * w, t * v * v + c, t * v * w + s * u, 0,
    t * u * w + s * v, t * v * w - s * u, t * w * w + c, 0,
    0, 0, 0, 1,
  ];
}

function angle(word, text) {
  const m = /^([-+.\de]+)(deg|rad|grad|turn)?$/.exec(word);
  if (!m) throw syntax(text);
  const v = Number(m[1]);
  return { deg: v, rad: (v * 180) / Math.PI, grad: v * 0.9, turn: v * 360, undefined: v }[m[2]];
}

function length(word, text) {
  const m = /^([-+.\de]+)(px)?$/.exec(word);
  if (!m) throw syntax(text);
  return Number(m[1]);
}

function parse(text) {
  const s = String(text).trim();
  let out = identity();
  let flat = true;
  if (s === "" || s === "none") return { m: out, flat };
  const step = /([a-zA-Z0-9]+)\(([^)]*)\)\s*/y;
  while (step.lastIndex < s.length) {
    const hit = step.exec(s);
    if (!hit) throw syntax(text);
    const name = hit[1].toLowerCase();
    const args = hit[2].split(/[\s,]+/).filter(Boolean);
    const num = (i, d) => (args[i] === undefined ? d : Number(args[i]));
    const len = (i) => (args[i] === undefined ? 0 : length(args[i], text));
    const ang = (i) => (args[i] === undefined ? 0 : angle(args[i], text));
    let one;
    switch (name) {
      case "matrix": one = [num(0), num(1), 0, 0, num(2), num(3), 0, 0, 0, 0, 1, 0, num(4), num(5), 0, 1]; break;
      case "matrix3d": one = args.map(Number); flat = false; break;
      case "translate": one = translation(len(0), len(1), 0); break;
      case "translatex": one = translation(len(0), 0, 0); break;
      case "translatey": one = translation(0, len(0), 0); break;
      case "translatez": one = translation(0, 0, len(0)); flat = false; break;
      case "translate3d": one = translation(len(0), len(1), len(2)); flat = false; break;
      case "scale": one = scaling(num(0), num(1, num(0)), 1); break;
      case "scalex": one = scaling(num(0), 1, 1); break;
      case "scaley": one = scaling(1, num(0), 1); break;
      case "scalez": one = scaling(1, 1, num(0)); flat = false; break;
      case "scale3d": one = scaling(num(0), num(1), num(2)); flat = false; break;
      case "rotate": case "rotatez": one = rotation(0, 0, 1, ang(0)); break;
      case "rotatex": one = rotation(1, 0, 0, ang(0)); flat = false; break;
      case "rotatey": one = rotation(0, 1, 0, ang(0)); flat = false; break;
      case "rotate3d": one = rotation(num(0), num(1), num(2), ang(3)); flat = false; break;
      case "skew": one = skewing(ang(0), ang(1)); break;
      case "skewx": one = skewing(ang(0), 0); break;
      case "skewy": one = skewing(0, ang(0)); break;
      default: throw syntax(text);
    }
    if (one.length !== 16 || one.some(Number.isNaN)) throw syntax(text);
    out = times(out, one);
  }
  return { m: out, flat };
}

function invert(m) {
  // Gauss-Jordan, with the row of the largest pivot each time.
  const a = m.slice(), b = identity();
  for (let c = 0; c < 4; c++) {
    let top = c;
    for (let r = c + 1; r < 4; r++) if (Math.abs(a[c * 4 + r]) > Math.abs(a[c * 4 + top])) top = r;
    if (a[c * 4 + top] === 0) return null;
    for (let k = 0; k < 4; k++) {
      [a[k * 4 + c], a[k * 4 + top]] = [a[k * 4 + top], a[k * 4 + c]];
      [b[k * 4 + c], b[k * 4 + top]] = [b[k * 4 + top], b[k * 4 + c]];
    }
    const d = a[c * 4 + c];
    for (let k = 0; k < 4; k++) { a[k * 4 + c] /= d; b[k * 4 + c] /= d; }
    for (let r = 0; r < 4; r++) {
      if (r === c) continue;
      const f = a[c * 4 + r];
      for (let k = 0; k < 4; k++) { a[k * 4 + r] -= f * a[k * 4 + c]; b[k * 4 + r] -= f * b[k * 4 + c]; }
    }
  }
  return b;
}

class DOMMatrixReadOnly {
  _m; _flat = true;
  constructor(init) {
    if (init === undefined) this._m = identity();
    else if (typeof init === "string") { const p = parse(init); this._m = p.m; this._flat = p.flat; }
    else if (init && init.length === 6) this._m = [init[0], init[1], 0, 0, init[2], init[3], 0, 0, 0, 0, 1, 0, init[4], init[5], 0, 1];
    else if (init && init.length === 16) { this._m = Array.from(init, Number); this._flat = false; }
    else throw new TypeError("Failed to construct 'DOMMatrix': The sequence must contain 6 elements for a 2D matrix or 16 elements for a 3D matrix.");
  }
  get is2D() { return this._flat; }
  get isIdentity() { const i = identity(); return this._m.every((v, k) => v === i[k]); }
  _made(m, flat) { const out = new g.DOMMatrix(m); out._flat = flat; return out; }
  multiply(o) { return this._made(times(this._m, new g.DOMMatrix(toInit(o))._m), this._flat && toFlat(o)); }
  translate(x = 0, y = 0, z = 0) { return this._made(times(this._m, translation(x, y, z)), this._flat && z === 0); }
  scale(x = 1, y = x, z = 1) { return this._made(times(this._m, scaling(x, y, z)), this._flat && z === 1); }
  scale3d(s = 1) { return this._made(times(this._m, scaling(s, s, s)), false); }
  rotate(x = 0, y, z) { const flat = y === undefined; return this._made(times(flat ? this._m : times(times(this._m, rotation(0, 0, 1, z ?? 0)), rotation(0, 1, 0, y)), rotation(flat ? 0 : 1, 0, flat ? 1 : 0, x)), this._flat && flat); }
  rotateAxisAngle(x = 0, y = 0, z = 0, a = 0) { return this._made(times(this._m, rotation(x, y, z, a)), this._flat && x === 0 && y === 0); }
  skewX(a = 0) { return this._made(times(this._m, skewing(a, 0)), this._flat); }
  skewY(a = 0) { return this._made(times(this._m, skewing(0, a)), this._flat); }
  flipX() { return this.scale(-1, 1); }
  flipY() { return this.scale(1, -1); }
  inverse() { const m = invert(this._m); return m ? this._made(m, this._flat) : this._made(new Array(16).fill(NaN), false); }
  transformPoint(p = {}) {
    const m = this._m, x = p.x ?? 0, y = p.y ?? 0, z = p.z ?? 0, w = p.w ?? 1;
    return new g.DOMPoint(m[0] * x + m[4] * y + m[8] * z + m[12] * w, m[1] * x + m[5] * y + m[9] * z + m[13] * w, m[2] * x + m[6] * y + m[10] * z + m[14] * w, m[3] * x + m[7] * y + m[11] * z + m[15] * w);
  }
  toFloat32Array() { return new Float32Array(this._m); }
  toFloat64Array() { return new Float64Array(this._m); }
  toJSON() { const o = { is2D: this.is2D, isIdentity: this.isIdentity }; for (const k in short) o[k] = this[k]; names.forEach((n, i) => { o[n] = this._m[i]; }); return o; }
  toString() {
    const m = this._m;
    return this._flat ? `matrix(${m[0]}, ${m[1]}, ${m[4]}, ${m[5]}, ${m[12]}, ${m[13]})` : `matrix3d(${m.join(", ")})`;
  }
  static fromMatrix(o) { return new this(toInit(o)); }
  static fromFloat32Array(a) { return new this(a); }
  static fromFloat64Array(a) { return new this(a); }
}
const toInit = (o) => (o instanceof DOMMatrixReadOnly ? o._m : o && typeof o.a === "number" ? [o.a, o.b, o.c, o.d, o.e, o.f] : undefined);
const toFlat = (o) => !(o instanceof DOMMatrixReadOnly) || o._flat;
names.forEach((n, i) => Object.defineProperty(DOMMatrixReadOnly.prototype, n, { get() { return this._m[i]; }, enumerable: true, configurable: true }));
for (const k in short) Object.defineProperty(DOMMatrixReadOnly.prototype, k, { get() { return this._m[short[k]]; }, enumerable: true, configurable: true });

class DOMMatrix extends DOMMatrixReadOnly {
  _take(o) { this._m = o._m; this._flat = o._flat; return this; }
  multiplySelf(o) { return this._take(this.multiply(o)); }
  preMultiplySelf(o) { return this._take(new DOMMatrix(toInit(o)).multiply(this)); }
  translateSelf(x, y, z) { return this._take(this.translate(x, y, z)); }
  scaleSelf(x, y, z) { return this._take(this.scale(x, y, z)); }
  scale3dSelf(s) { return this._take(this.scale3d(s)); }
  rotateSelf(x, y, z) { return this._take(this.rotate(x, y, z)); }
  rotateAxisAngleSelf(x, y, z, a) { return this._take(this.rotateAxisAngle(x, y, z, a)); }
  skewXSelf(a) { return this._take(this.skewX(a)); }
  skewYSelf(a) { return this._take(this.skewY(a)); }
  invertSelf() { return this._take(this.inverse()); }
  setMatrixValue(text) { const p = parse(text); this._m = p.m; this._flat = p.flat; return this; }
}
names.forEach((n, i) => Object.defineProperty(DOMMatrix.prototype, n, { get() { return this._m[i]; }, set(v) { this._m[i] = Number(v); if (i !== 0 && i !== 1 && i !== 4 && i !== 5 && i !== 12 && i !== 13) this._flat = false; }, enumerable: true, configurable: true }));
for (const k in short) Object.defineProperty(DOMMatrix.prototype, k, { get() { return this._m[short[k]]; }, set(v) { this._m[short[k]] = Number(v); }, enumerable: true, configurable: true });

const define = (name, value) => Object.defineProperty(g, name, { value, writable: true, configurable: true, enumerable: false });
define("DOMMatrixReadOnly", DOMMatrixReadOnly);
define("DOMMatrix", DOMMatrix);
define("WebKitCSSMatrix", DOMMatrix);
})
