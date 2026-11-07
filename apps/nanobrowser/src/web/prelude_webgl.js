// Real offscreen WebGL subset. Missing methods stay missing; no fake extensions.
(function ($, g) {
"use strict";
function WebGLRenderingContext() { throw new TypeError("Illegal constructor"); }
function WebGL2RenderingContext() { throw new TypeError("Illegal constructor"); }
g.WebGLRenderingContext = WebGLRenderingContext;
g.WebGL2RenderingContext = WebGL2RenderingContext;
Object.setPrototypeOf(WebGL2RenderingContext.prototype, WebGLRenderingContext.prototype);
const constants = {
 DEPTH_BUFFER_BIT:256, STENCIL_BUFFER_BIT:1024, COLOR_BUFFER_BIT:16384,
 POINTS:0, LINES:1, LINE_LOOP:2, LINE_STRIP:3, TRIANGLES:4, TRIANGLE_STRIP:5, TRIANGLE_FAN:6,
 ZERO:0, ONE:1, SRC_COLOR:768, ONE_MINUS_SRC_COLOR:769, SRC_ALPHA:770, ONE_MINUS_SRC_ALPHA:771,
 DST_ALPHA:772, ONE_MINUS_DST_ALPHA:773, DST_COLOR:774, ONE_MINUS_DST_COLOR:775,
 FUNC_ADD:32774, FUNC_SUBTRACT:32778, FUNC_REVERSE_SUBTRACT:32779,
 ARRAY_BUFFER:34962, ELEMENT_ARRAY_BUFFER:34963, STATIC_DRAW:35044, DYNAMIC_DRAW:35048, STREAM_DRAW:35040,
 BYTE:5120, UNSIGNED_BYTE:5121, SHORT:5122, UNSIGNED_SHORT:5123, INT:5124, UNSIGNED_INT:5125, FLOAT:5126,
 VERTEX_SHADER:35633, FRAGMENT_SHADER:35632, COMPILE_STATUS:35713, LINK_STATUS:35714, VALIDATE_STATUS:35715,
 DELETE_STATUS:35712, SHADER_TYPE:35663, ATTACHED_SHADERS:35717, ACTIVE_UNIFORMS:35718, ACTIVE_ATTRIBUTES:35721,
 NO_ERROR:0, INVALID_ENUM:1280, INVALID_VALUE:1281, INVALID_OPERATION:1282, OUT_OF_MEMORY:1285,
 TEXTURE_2D:3553, TEXTURE0:33984, TEXTURE1:33985, TEXTURE2:33986, TEXTURE3:33987,
 TEXTURE_MAG_FILTER:10240, TEXTURE_MIN_FILTER:10241, TEXTURE_WRAP_S:10242, TEXTURE_WRAP_T:10243,
 NEAREST:9728, LINEAR:9729, NEAREST_MIPMAP_NEAREST:9984, LINEAR_MIPMAP_NEAREST:9985,
 NEAREST_MIPMAP_LINEAR:9986, LINEAR_MIPMAP_LINEAR:9987, CLAMP_TO_EDGE:33071, REPEAT:10497, MIRRORED_REPEAT:33648,
 RGB:6407, RGBA:6408, RGBA8:32856, ALPHA:6406,
 BLEND:3042, CULL_FACE:2884, DEPTH_TEST:2929, DITHER:3024, POLYGON_OFFSET_FILL:32823,
 SAMPLE_ALPHA_TO_COVERAGE:32926, SAMPLE_COVERAGE:32928, SCISSOR_TEST:3089, STENCIL_TEST:2960,
 NEVER:512, LESS:513, EQUAL:514, LEQUAL:515, GREATER:516, NOTEQUAL:517, GEQUAL:518, ALWAYS:519,
 PACK_ALIGNMENT:3333, UNPACK_ALIGNMENT:3317, UNPACK_FLIP_Y_WEBGL:37440, UNPACK_PREMULTIPLY_ALPHA_WEBGL:37441,
 UNPACK_COLORSPACE_CONVERSION_WEBGL:37443, BROWSER_DEFAULT_WEBGL:37444,
 VENDOR:7936, RENDERER:7937, VERSION:7938, SHADING_LANGUAGE_VERSION:35724,
 MAX_TEXTURE_SIZE:3379, MAX_CUBE_MAP_TEXTURE_SIZE:34076, MAX_VERTEX_ATTRIBS:34921,
 MAX_TEXTURE_IMAGE_UNITS:34930, MAX_VERTEX_TEXTURE_IMAGE_UNITS:35660, MAX_COMBINED_TEXTURE_IMAGE_UNITS:35661,
 MAX_SAMPLES:36183
};
for (const key of Object.keys(constants)) {
 Object.defineProperty(WebGLRenderingContext.prototype,key,{value:constants[key],enumerable:true});
 Object.defineProperty(WebGLRenderingContext,key,{value:constants[key],enumerable:true});
 Object.defineProperty(WebGL2RenderingContext,key,{value:constants[key],enumerable:true});
}
const contexts = new WeakMap();
const previous = g.HTMLCanvasElement.prototype.getContext;
for (const dimension of ["width","height"]) {
 const d=Object.getOwnPropertyDescriptor(g.HTMLCanvasElement.prototype,dimension);
 if(d && d.set) Object.defineProperty(g.HTMLCanvasElement.prototype,dimension,{
  configurable:true,enumerable:d.enumerable,get:d.get,set:function(value){
   d.set.call(this,value);
   const c=contexts.get(this);
   if(c && (c.kind==="webgl" || c.kind==="webgl2")) $.webglCall(this,"reset");
  }
 });
}
function make(canvas, kind, options) {
 const two = kind === "webgl2";
 const attrs = {alpha:options.alpha !== false,depth:options.depth !== false,stencil:!!options.stencil,
  antialias:false,premultipliedAlpha:options.premultipliedAlpha !== false,preserveDrawingBuffer:!!options.preserveDrawingBuffer,
  failIfMajorPerformanceCaveat:false,powerPreference:"default",desynchronized:false};
 if (!$.webglCreate(canvas,kind,attrs.alpha,attrs.depth,attrs.stencil,attrs.premultipliedAlpha,attrs.preserveDrawingBuffer)) return null;
 const gl = Object.create(two ? WebGL2RenderingContext.prototype : WebGLRenderingContext.prototype);
 const call = (name,...args) => $.webglCall(canvas,name,...args);
 const objects = new WeakMap();
 const generations = new WeakMap();
 let currentProgram = null;
 const object = (id,kind) => {
  if (!id) return null;
  const o = {}; objects.set(o,{id,kind}); return o;
 };
 const id = (o,kind) => {
  if (o === null || o === undefined) return 0;
  const v = objects.get(o);
  if (!v || v.kind !== kind) { call("invalid"); return -1; }
  return v.id;
 };
 Object.defineProperties(gl, {
  canvas:{value:canvas,enumerable:true},
  drawingBufferWidth:{get:()=>call("width"),enumerable:true},
  drawingBufferHeight:{get:()=>call("height"),enumerable:true}
 });
 gl.getContextAttributes = () => Object.assign({},attrs);
 gl.isContextLost = () => false;
 gl.getSupportedExtensions = () => [];
 gl.getExtension = () => null;
 for (const name of ["clearColor","clear","viewport","scissor","enable","disable","blendFunc","blendEquation",
  "depthFunc","depthMask","clearDepth","colorMask","flush","finish","getError","getParameter","pixelStorei",
  "activeTexture","texParameteri","texParameterf","generateMipmap","vertexAttribPointer","enableVertexAttribArray",
  "disableVertexAttribArray","drawArrays","drawElements","readPixels"])
  gl[name] = (...args) => call(name,...args);
 for (const kind of ["Buffer","Shader","Program","Texture"]) {
  gl["create"+kind] = (...args) => object(call("create"+kind,...args),kind);
  gl["delete"+kind] = o => { const n=id(o,kind); if(n>=0) {call("delete"+kind,n); if(o) objects.delete(o);} };
 }
 for (const kind of ["Buffer","Texture"]) gl["bind"+kind] = (target,o) => {const n=id(o,kind); if(n>=0) call("bind"+kind,target,n);};
 gl.bufferData = (target,data,usage) => call("bufferData",target,data,usage);
 gl.bufferSubData = (target,offset,data) => call("bufferSubData",target,offset,data);
 gl.texImage2D = (...args) => call("texImage2D",...args);
 gl.texSubImage2D = (...args) => call("texSubImage2D",...args);
 for (const name of ["shaderSource","compileShader","getShaderParameter","getShaderInfoLog"]) {
  gl[name]=(s,...args)=>{const n=id(s,"Shader"); return n>=0 ? call(name,n,...args) : null;};
 }
 for (const name of ["getProgramParameter","getProgramInfoLog","bindAttribLocation","getAttribLocation"]) {
  gl[name]=(p,...args)=>{const n=id(p,"Program"); return n>=0 ? call(name,n,...args) : null;};
 }
 gl.linkProgram = p => { const n=id(p,"Program"); if(n>=0) {generations.set(p,(generations.get(p)||0)+1); call("linkProgram",n);} };
 gl.useProgram = p => { const n=id(p,"Program"); if(n>=0) {call("useProgram",n); if(!p || call("getProgramParameter",n,constants.LINK_STATUS)) currentProgram=p;} };
 for(const name of ["attachShader","detachShader"]) gl[name]=(p,s)=>{
  const pn=id(p,"Program"),sn=id(s,"Shader"); if(pn>=0 && sn>=0) call(name,pn,sn);
 };
 gl.getUniformLocation = (p,name) => {
  const n=id(p,"Program"); if(n<0) return null;
  const loc=call("getUniformLocation",n,String(name)); if(typeof loc!=="number" || loc<0) return null;
  const o={}; objects.set(o,{id:loc,kind:"Uniform",program:p,generation:generations.get(p)}); return o;
 };
 for (const name of ["uniform1f","uniform2f","uniform3f","uniform4f","uniform1i","uniform2i","uniform3i","uniform4i",
  "uniformMatrix2fv","uniformMatrix3fv","uniformMatrix4fv"]) {
  gl[name] = (loc,...args) => {
   if(loc===null) return;
   const v=objects.get(loc);
   if(!v || v.kind!=="Uniform" || v.program!==currentProgram || v.generation!==generations.get(v.program)) {call("invalid");return;}
   if(name.indexOf("Matrix")>=0) args[1]=args[1] instanceof Float32Array ? args[1] : new Float32Array(args[1]);
   call(name,v.id,...args);
  };
 }
 return gl;
}
Object.defineProperty(g.HTMLCanvasElement.prototype,"getContext",{configurable:true,writable:true,value:function(kind,options){
 kind=String(kind); const normalized=kind==="experimental-webgl" ? "webgl" : kind;
 const existing=contexts.get(this);
 if(existing) return existing.kind===normalized ? existing.value : null;
 // Shared with other canvas backends; native source registration also refuses takeover.
 if(this.__nbContextKind && this.__nbContextKind!==normalized) return null;
 if(normalized!=="webgl" && normalized!=="webgl2") {
  const c=previous.call(this,kind,options);
  if(c) {contexts.set(this,{kind:normalized,value:c});this.__nbContextKind=normalized;}
  return c;
 }
 const value=make(this,normalized,options || {});
 if(value) {contexts.set(this,{kind:normalized,value});this.__nbContextKind=normalized;}
 return value;
}});
})
