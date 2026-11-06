//! Real offscreen pixels through the page's JS API; no windows or network.
const std = @import("std");
const builtin = @import("builtin");
const Run = @import("web/tests_util.zig").Run;
const testing = std.testing;

test {
    _ = @import("gl/state.zig");
    _ = @import("gl/formats.zig");
    _ = @import("gl/translate.zig");
}

const setup =
    \\var canvas=document.createElement('canvas'); canvas.width=8; canvas.height=8;
    \\document.body.appendChild(canvas);
    \\var gl=canvas.getContext(KIND,{preserveDrawingBuffer:true,premultipliedAlpha:false});
    \\if(!gl) throw new Error('CGL context unavailable');
    \\function pixel(x,y){var p=new Uint8Array(4);gl.readPixels(x,y,1,1,gl.RGBA,gl.UNSIGNED_BYTE,p);return Array.from(p).join(',');}
;
const shaders =
    \\function shader(kind,source){var s=gl.createShader(kind);gl.shaderSource(s,source);gl.compileShader(s);
    \\if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw new Error(gl.getShaderInfoLog(s));return s;}
    \\function program(fragment){var p=gl.createProgram();
    \\gl.attachShader(p,shader(gl.VERTEX_SHADER,'attribute vec2 pos;void main(){gl_Position=vec4(pos,0.0,1.0);}'));
    \\gl.attachShader(p,shader(gl.FRAGMENT_SHADER,fragment));gl.linkProgram(p);
    \\if(!gl.getProgramParameter(p,gl.LINK_STATUS))throw new Error(gl.getProgramInfoLog(p));gl.useProgram(p);return p;}
    \\var p=program('precision mediump float;uniform vec4 color;void main(){gl_FragColor=color;}');
    \\var buf=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,buf);
    \\gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1, 1,-1, 0,1]),gl.STATIC_DRAW);
    \\var pos=gl.getAttribLocation(p,'pos');gl.enableVertexAttribArray(pos);gl.vertexAttribPointer(pos,2,gl.FLOAT,false,0,0);
    \\var color=gl.getUniformLocation(p,'color');
;

fn start(r: *Run, kind: []const u8) !void {
    try r.start();
    errdefer r.stop();
    try r.html("<!doctype html><body></body>");
    const source = try std.mem.replaceOwned(u8, testing.allocator, setup, "KIND", kind);
    defer testing.allocator.free(source);
    _ = try r.eval(source);
}

test "webgl real clear, alpha paint, orientation, resize and exclusivity" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var r: Run = undefined;
    try start(&r, "'webgl'");
    defer r.stop();
    const c = r.page().webgl.items.items[0];
    const initial = r.page().canvases.pixelsOf(c.node).?;
    for (initial.bgra) |byte| try testing.expectEqual(@as(u8, 0), byte);
    try r.expectJs("gl.clearColor(1,0.5,0,0.5);gl.clear(gl.COLOR_BUFFER_BIT);pixel(0,0)", "255,128,0,128");
    const texture = r.page().canvases.pixelsOf(c.node).?;
    try testing.expectEqualSlices(u8, &.{ 0, 64, 128, 128 }, texture.bgra[0..4]);
    _ = try r.eval("gl.enable(gl.SCISSOR_TEST);gl.scissor(0,0,8,1);gl.clearColor(0,1,0,1);gl.clear(gl.COLOR_BUFFER_BIT);gl.disable(gl.SCISSOR_TEST)");
    const oriented = r.page().canvases.pixelsOf(c.node).?;
    try testing.expectEqualSlices(u8, &.{ 0, 64, 128, 128 }, oriented.bgra[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, oriented.bgra[7 * 8 * 4 ..][0..4]);
    try r.expectJs("[canvas.getContext('experimental-webgl')===gl,canvas.getContext('webgl2'),canvas.getContext('2d'),canvas.getContext('bogus')].join('|')", "true|||");
    try r.expectJs("var other=document.createElement('canvas');other.getContext('2d');other.getContext('webgl')", "null");
    try r.expectJs("canvas.width=8;pixel(0,0)", "0,0,0,0");
    try r.expectJs("gl.clear(gl.COLOR_BUFFER_BIT);canvas.width=4;[gl.drawingBufferWidth,pixel(0,0),gl.getError()].join('|')", "4|0,0,0,0|0");
    try r.expectNoErrors();
}

test "webgl real triangle uniform indexed draw and rejected buffer overrun" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var r: Run = undefined;
    try start(&r, "'webgl'");
    defer r.stop();
    _ = try r.eval(shaders);
    try r.expectJs("gl.uniform4f(color,0,1,0,1);gl.drawArrays(gl.TRIANGLES,0,3);pixel(4,3)", "0,255,0,255");
    try r.expectJs("pixel(0,7)", "0,0,0,0");
    try r.expectJs("gl.uniform4f(color,0,0,1,1);gl.drawArrays(gl.TRIANGLES,0,3);pixel(4,3)", "0,0,255,255");
    try r.expectJs("gl.drawArrays(gl.TRIANGLES,0,4);gl.getError()===gl.INVALID_OPERATION", "true");
    try r.expectJs("gl.drawArrays(gl.TRIANGLES,-1,3);gl.getError()===gl.INVALID_VALUE", "true");
    try r.expectJs("var ix=gl.createBuffer();gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER,ix);gl.bufferData(gl.ELEMENT_ARRAY_BUFFER,new Uint16Array([0,1,2]),gl.STATIC_DRAW);gl.uniform4f(color,1,0,0,1);gl.drawElements(gl.TRIANGLES,3,gl.UNSIGNED_SHORT,0);pixel(4,3)", "255,0,0,255");
    try r.expectJs("gl.bufferSubData(gl.ELEMENT_ARRAY_BUFFER,4,new Uint16Array([9]));gl.drawElements(gl.TRIANGLES,3,gl.UNSIGNED_SHORT,0);gl.getError()===gl.INVALID_OPERATION", "true");
    try r.expectJs("gl.readPixels(0,0,2,2,gl.RGBA,gl.UNSIGNED_BYTE,new Uint8Array(4));gl.getError()===gl.INVALID_OPERATION", "true");
    try r.expectJs("var bad=gl.createShader(gl.FRAGMENT_SHADER);gl.shaderSource(bad,'not valid GLSL');gl.compileShader(bad);[gl.getShaderParameter(bad,gl.COMPILE_STATUS),gl.getShaderInfoLog(bad).length>0].join('|')", "false|true");
    try r.expectJs("var stale=shader(gl.FRAGMENT_SHADER,'void main(){gl_FragColor=vec4(1.0);}');gl.shaderSource(stale,'#version 450\\nvoid main(){}');gl.compileShader(stale);gl.getShaderParameter(stale,gl.COMPILE_STATUS)", "false");
    try r.expectNoErrors();
}

test "webgl2 real byte texture and GLSL ES 300" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var r: Run = undefined;
    try start(&r, "'webgl2'");
    defer r.stop();
    _ = try r.eval(shaders);
    _ = try r.eval(
        \\gl.disableVertexAttribArray(pos);
        \\var texProgram=gl.createProgram();
        \\gl.attachShader(texProgram,shader(gl.VERTEX_SHADER,'#version 300 es\nin vec2 pos;void main(){gl_Position=vec4(pos,0.0,1.0);}'));
        \\gl.attachShader(texProgram,shader(gl.FRAGMENT_SHADER,'#version 300 es\nprecision mediump float;uniform sampler2D tex;out vec4 result;void main(){result=texture(tex,vec2(0.5));}'));
        \\gl.linkProgram(texProgram);if(!gl.getProgramParameter(texProgram,gl.LINK_STATUS))throw new Error(gl.getProgramInfoLog(texProgram));gl.useProgram(texProgram);
        \\pos=gl.getAttribLocation(texProgram,'pos');gl.enableVertexAttribArray(pos);gl.vertexAttribPointer(pos,2,gl.FLOAT,false,0,0);
        \\var tex=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,tex);
        \\gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);
        \\gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,1,1,0,gl.RGBA,gl.UNSIGNED_BYTE,new Uint8Array([17,61,223,255]));
        \\gl.uniform1i(gl.getUniformLocation(texProgram,'tex'),0);gl.drawArrays(gl.TRIANGLES,0,3);
    );
    try r.expectJs("pixel(4,3)", "17,61,223,255");
    try r.expectJs("gl.getError()", "0");
    try r.expectJs("gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,2,2,0,gl.RGBA,gl.UNSIGNED_BYTE,new Uint8Array(4));gl.getError()===gl.INVALID_OPERATION", "true");
    try r.expectNoErrors();
}
