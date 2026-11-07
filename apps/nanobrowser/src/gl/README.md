# Offscreen WebGL subset

macOS only: each canvas owns a CGL legacy (WebGL 1) or 4.1 core (WebGL 2)
context and framebuffer. No native windows are created. Other platforms return
`null`; unknown context kinds return `null`. `experimental-webgl` aliases
`webgl`. A canvas cannot switch between 2D, WebGL 1 and WebGL 2 contexts.

This is a bounded rendering subset, **not a conformant or hardened WebGL
implementation**. GLSL ES is token-translated to desktop GLSL, not validated by
ANGLE. Shader compilation and linking use real driver status and logs.

## Implemented JavaScript API

- Context: `canvas`, `drawingBufferWidth`, `drawingBufferHeight`,
  `getContextAttributes`, `getError`, `getParameter`, `isContextLost`,
  `getSupportedExtensions`, `getExtension`. Extensions are an empty list/null;
  context-loss events and recovery are not implemented.
- State/drawing: `clearColor`, `clear`, `clearDepth`, `colorMask`, `depthMask`,
  `depthFunc`, `viewport`, `scissor`, `enable`, `disable`, `blendFunc`,
  `blendEquation`, `flush`, `finish`, `drawArrays`, `drawElements`.
- Buffers/attributes: `createBuffer`, `deleteBuffer`, `bindBuffer`, `bufferData`,
  `bufferSubData`, `vertexAttribPointer`, `enableVertexAttribArray`,
  `disableVertexAttribArray`. Array and element buffers only; float and
  byte/short vertex attributes, including normalized integer attributes.
- Shaders/programs: `createShader`, `deleteShader`, `shaderSource`,
  `compileShader`, `getShaderParameter`, `getShaderInfoLog`, `createProgram`,
  `deleteProgram`, `attachShader`, `detachShader`, `linkProgram`, `useProgram`,
  `getProgramParameter`, `getProgramInfoLog`, `bindAttribLocation`,
  `getAttribLocation`, `getUniformLocation`.
- Uniforms: `uniform1f` through `uniform4f`, `uniform1i` through `uniform4i`,
  `uniformMatrix2fv`, `uniformMatrix3fv`, `uniformMatrix4fv`.
- Pixels/textures: `createTexture`, `deleteTexture`, `activeTexture`,
  `bindTexture`, `texParameteri`, `texParameterf`, `texImage2D`, `texSubImage2D`,
  `generateMipmap`, `pixelStorei`, `readPixels`.

Texture uploads use the nine-argument, byte-array `TEXTURE_2D` overload with
RGBA/UNSIGNED_BYTE (RGBA8 internal format also accepted in WebGL 2). Null
allocation is zero-initialized. Unpack alignment, vertical flipping and alpha
premultiplication are supported. Readback accepts RGBA/UNSIGNED_BYTE and a
sufficiently large buffer; rectangles outside the drawing buffer are rejected.

`getParameter` supports VERSION, VENDOR, RENDERER, SHADING_LANGUAGE_VERSION,
MAX_TEXTURE_SIZE, MAX_CUBE_MAP_TEXTURE_SIZE, MAX_VERTEX_ATTRIBS,
MAX_TEXTURE_IMAGE_UNITS, MAX_VERTEX_TEXTURE_IMAGE_UNITS,
MAX_COMBINED_TEXTURE_IMAGE_UNITS and MAX_SAMPLES. Other queries raise
INVALID_ENUM rather than inventing results.

## Bounds and limitations

- At most 16 contexts per page; physical canvas sides clamp to 1–8192 pixels.
  Zero-size canvases consequently have a 1-pixel physical side.
- Buffer allocations and individual texture uploads are capped at 64 MiB;
  shader sources at 1 MiB. Integer argument conversion is simplified; numeric
  objects are rejected rather than invoking callbacks with native state live.
- Every enabled vertex attribute is checked against its buffer, conservatively
  including inactive attributes. Indexed draws inspect CPU-shadowed indices.
  Deleted buffers, misaligned offsets and out-of-range fetches are rejected.
  Uniform blocks without storage are rejected at draw time.
- Painting reads only dirty canvases, yielding top-row-first premultiplied BGRA.
  Resize clears the drawing buffer. Assigning the width/height property clears
  even when unchanged; same-value attribute mutation through other DOM APIs
  does not yet trigger that reset. Page teardown destroys contexts/resources.
- No antialiasing; returned context attributes report `antialias: false`.
- No public framebuffer/renderbuffer/VAO APIs, instancing, extensions, uniform
  vector-array setters, uniform-buffer APIs, DOM-image uploads, cube/3D/array
  textures, general texture formats, query/sync/transform-feedback APIs,
  shader reflection, context-loss lifecycle or full WebIDL/WebGL validation.
- WebGL 2 provides this same basic surface plus ES 3.00 shader translation,
  unsigned-int indices and RGBA8 uploads, not the complete WebGL 2 API.

`../tests_webgl.zig` covers offscreen clear/alpha/orientation, resize/context
exclusivity, triangle/uniform/index drawing, rejected buffer bounds, real
shader errors and an ES 3.00 byte-texture draw. State, format and translation
unit tests live alongside their implementations.
