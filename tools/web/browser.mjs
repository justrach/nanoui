import { chromium } from 'playwright';
import assert from 'node:assert/strict';
import { checkGalleryKeyboard } from './gallery_keyboard.mjs';
import { serve } from './serve.mjs';
import { chromiumOptions } from './browser_options.mjs';
const host = await serve();
const browser = await chromium.launch(chromiumOptions());
try {
  const context = await browser.newContext({ viewport:{width:420,height:300}, deviceScaleFactor:2 });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', e=>errors.push(e.message));
  await page.addInitScript(() => {
    const scissor = GPURenderPassEncoder.prototype.setScissorRect;
    window.damageScissors = 0;
    GPURenderPassEncoder.prototype.setScissorRect = function (...args) {
      window.damageScissors++;
      return scissor.apply(this, args);
    };
  });
  await page.goto(host.url+'/index.html');
  await page.waitForFunction(()=>window.nanoui?.exports.nanoui_web_frames()>1);
  const compare = async () => {
    const png = await page.screenshot({scale:"device"});
    return page.evaluate(async(data)=>{
    const r=window.nanoui, e=r.exports, canvas=document.querySelector('canvas');
    await r.gpu.check();
    const scratch=document.createElement('canvas');scratch.width=canvas.width;scratch.height=canvas.height;
    const bitmap=await createImageBitmap(new Blob([Uint8Array.from(atob(data),c=>c.charCodeAt(0))],{type:'image/png'}));
    const ctx=scratch.getContext('2d');ctx.drawImage(bitmap,0,0);bitmap.close();
    const rgba=ctx.getImageData(0,0,canvas.width,canvas.height).data;
    const ptr=e.nanoui_web_snapshot();
    if(!ptr)throw Error('CPU snapshot failed');
    const bgra=new Uint8Array(e.memory.buffer,ptr,rgba.length);
    let sum=0,worst=0,off=0;
    for(let i=0;i<rgba.length;i++){const c=i%4;const j=c===0?i+2:c===2?i-2:i;const d=Math.abs(rgba[i]-bgra[j]);sum+=d;worst=Math.max(worst,d);off+=Number(d>8);}
    return {mean:sum/rgba.length,worst,off,width:canvas.width,height:canvas.height};
  },png.toString("base64")); };
  { const result=await compare(); console.log(result); assert.ok(result.mean<0.05); }
  assert.equal(await page.evaluate(()=>Number(window.nanoui.exports.counter_value())),0);
  const scissors = await page.evaluate(()=>window.damageScissors);
  const unhovered = await page.screenshot({scale:"device"});
  await page.mouse.move(207,185);
  await page.waitForFunction(before=>window.damageScissors>before,scissors);
  await page.waitForTimeout(300);
  assert.ok((await compare()).mean<0.05, 'damaged hover matches pixels from a full repaint');
  assert.ok(!unhovered.equals(await page.screenshot({scale:"device"})), 'hover changes pixels');
  // Leaving the canvas with no button held clears the hover.
  await page.evaluate(()=>document.querySelector('canvas').dispatchEvent(new PointerEvent('pointerleave',{pointerType:'mouse',buttons:0})));
  await page.waitForTimeout(300);
  assert.ok(unhovered.equals(await page.screenshot({scale:"device"})), 'pointer leave clears hover');
  await page.mouse.click(207,185);
  await page.waitForTimeout(500);
  { const result=await compare(); console.log(result); assert.ok(result.mean<0.05); }
  assert.equal(await page.evaluate(()=>Number(window.nanoui.exports.counter_value())),1);
  const unchanged = await page.evaluate(()=>{
    const r=window.nanoui;
    const before={ui:r.exports.nanoui_web_frames(),gpu:r.gpu.stats.frames};
    r.requestFrame();
    return before;
  });
  await page.waitForFunction(before=>window.nanoui.exports.nanoui_web_frames()>before,unchanged.ui);
  assert.equal(await page.evaluate(()=>window.nanoui.gpu.stats.frames),unchanged.gpu,'unchanged frame skipped GPU submission');
  const before=await page.evaluate(()=>window.nanoui.host.stats.callbacks);
  await page.waitForTimeout(1000);
  assert.equal(await page.evaluate(()=>window.nanoui.host.stats.callbacks),before,'idle callbacks');
  await page.setViewportSize({width:600,height:400});
  await page.waitForTimeout(500);
  const resized=await compare();assert.equal(resized.width,1200);assert.equal(resized.height,800);assert.ok(resized.mean<0.05);
  const generation=await page.evaluate(()=>window.nanoui.gpu.generation);
  await page.evaluate(()=>window.nanoui.host.debugLoseDevice());
  await page.waitForFunction(g=>window.nanoui.gpu.generation>g,generation);
  await page.waitForTimeout(500);
  { const result=await compare(); console.log(result); assert.ok(result.mean<0.05); }
  await page.evaluate(async()=>{await window.nanoui.gpu.check();window.nanoui.destroy();if(window.nanoui.gpu.objects.size!==1)throw Error('GPU handle leak');});
  await page.evaluate(async()=>{
    const {start}=await import('./nanoui.js');const adapter=await navigator.gpu.requestAdapter();
    const device=await adapter.requestDevice();
    const runtime=await start({canvas:document.querySelector('canvas'),url:'./counter.wasm',device});
    if(runtime.device!==device)throw Error('Injected device was replaced');
    window.nanoui=runtime;
  });
  await page.waitForTimeout(200);
  await page.evaluate(async()=>{
    const r=window.nanoui;const old=r.device;
    const adapter=await navigator.gpu.requestAdapter();const next=await adapter.requestDevice();
    // A frame queued before the replacement must not draw while its
    // pipelines compile.
    r.requestFrame();
    await r.setDevice(next);if(r.device!==next||r.gpu.generation!==2)throw Error('Injected replacement failed');
    old.destroy();
  });
  await page.waitForTimeout(300);
  {const result=await compare();assert.ok(result.mean<0.05);}
  await page.evaluate(()=>{const r=window.nanoui;r.destroy();r.device.destroy();});
  await page.evaluate(async () => {
    const old=document.querySelector('canvas');old.remove();
    const canvas=document.createElement('canvas');canvas.style.width='420px';canvas.style.height='300px';document.body.append(canvas);
    const worker=new Worker('./worker.js',{type:'module'});
    let seq=0; const pending=new Map();
    worker.onmessage=({data})=>{ if(data.error)throw Error(data.error); const f=pending.get(data.id??'ready');if(f){pending.delete(data.id??'ready');f(data);} };
    const ready=new Promise(resolve=>pending.set('ready',resolve));
    const offscreen=canvas.transferControlToOffscreen();
    worker.postMessage({canvas:offscreen,width:840,height:600,scale:2},[offscreen]);await ready;
    window.workerProbe={worker,info:()=>new Promise(resolve=>{const id=++seq;pending.set(id,resolve);worker.postMessage({info:id});})};
  });
  await page.waitForTimeout(400);
  const workerBefore=await page.evaluate(()=>window.workerProbe.info());
  assert.equal(workerBefore.value,0);
  await page.evaluate(()=>{
    window.workerProbe.worker.postMessage({pointer:[0,207,185]});
    window.workerProbe.worker.postMessage({pointer:[1,207,185]});
    window.workerProbe.worker.postMessage({pointer:[2,207,185]});
  });
  // Worker frames can still be settling after the click on a loaded host:
  // retry until the click has landed and no frame runs for a second.
  {
    const info = () => page.evaluate(() => window.workerProbe.info());
    const deadline = Date.now() + 8000;
    let before, after;
    for (;;) {
      before = await info();
      if (before.value === 1) {
        await page.waitForTimeout(1000);
        after = await info();
        if (after.value === 1 && after.callbacks === before.callbacks) break;
      } else await page.waitForTimeout(200);
      if (Date.now() > deadline) throw new Error(`Worker did not settle idle after the click within 8 s: before ${JSON.stringify(before)}, after ${JSON.stringify(after)}`);
    }
  }
  await page.evaluate(()=>window.workerProbe.worker.postMessage({destroy:true}));
  const scaleOne=await browser.newContext({viewport:{width:420,height:300},deviceScaleFactor:1});
  const low=await scaleOne.newPage();low.on('pageerror',e=>errors.push(e.message));
  await low.goto(host.url+'/index.html');
  await low.waitForFunction(()=>window.nanoui?.exports.nanoui_web_frames()>1);
  const dimensions=await low.evaluate(async()=>{
    await window.nanoui.gpu.check();
    const c=document.querySelector('canvas');return [c.width,c.height];
  });
  assert.deepEqual(dimensions,[420,300]);
  await low.evaluate(()=>window.nanoui.destroy());await scaleOne.close();
  const gallery = await context.newPage();
  gallery.on('pageerror', e => errors.push(e.message));
  await checkGalleryKeyboard(gallery, host.url);
  await gallery.close();
  const unavailable = await context.newPage();
  await unavailable.addInitScript(() => Object.defineProperty(navigator, 'gpu', { value: undefined }));
  await unavailable.goto(host.url + '/counter.html');
  await unavailable.waitForFunction(() => window.nanoui?.exports.nanoui_web_frames() > 0);
  assert.equal(await unavailable.evaluate(() => window.nanoui.gpu === null), true);
  await unavailable.close();
  // Canvas 2D renders at most at scale 2, even on a DPR 3 phone.
  const dense = await browser.newContext({ viewport: { width: 420, height: 300 }, deviceScaleFactor: 3 });
  const densePage = await dense.newPage();
  await densePage.addInitScript(() => Object.defineProperty(navigator, 'gpu', { value: undefined }));
  await densePage.goto(host.url + '/counter.html');
  await densePage.waitForFunction(() => window.nanoui?.exports.nanoui_web_frames() > 0);
  assert.deepEqual(await densePage.evaluate(() => [window.nanoui.canvas.width, window.nanoui.canvas.height]), [840, 600]);
  await densePage.mouse.click(207, 185);
  await densePage.waitForFunction(() => window.nanoui.exports.counter_value() === 1n);
  await dense.close();
  const failover = await context.newPage();
  failover.on('pageerror', e => errors.push(e.message));
  await failover.goto(host.url + '/counter.html');
  await failover.waitForFunction(() => window.nanoui?.gpu?.stats.frames > 0);
  await failover.mouse.click(207,185);
  await failover.waitForFunction(() => window.nanoui.exports.counter_value() === 1n);
  await failover.evaluate(() => {
    const runtime = window.nanoui;
    const { canvas, gpu } = runtime;
    canvas.focus();
    window.beforeFailover = { runtime, canvas, gpu, frames: runtime.exports.nanoui_web_frames() };
    navigator.gpu.requestAdapter = async () => null;
    runtime.host.debugLoseDevice();
  });
  await failover.waitForFunction(() => !window.nanoui.gpu &&
    window.nanoui.exports.nanoui_web_frames() > window.beforeFailover.frames);
  await failover.evaluate(() => {
    const { runtime, canvas, gpu } = window.beforeFailover;
    if (window.nanoui !== runtime || runtime.device !== undefined || gpu.objects.size !== 0 ||
        gpu.imports.device_generation() !== 0 || canvas.isConnected || document.activeElement !== runtime.canvas)
      throw new Error('Failover did not retain the runtime and focus or retire the lost device');
    if (runtime.exports.counter_value() !== 1n) throw new Error('Counter state was lost');
    const pixels = runtime.canvas.getContext('2d').getImageData(0, 0, 840, 600).data;
    if (!pixels.some((value, i) => i % 4 === 0 && value !== pixels[0]))
      throw new Error('No visible Canvas 2D content');
  });
  await failover.mouse.click(207,185);
  await failover.waitForFunction(() => window.nanoui.exports.counter_value() === 2n);
  await failover.setViewportSize({ width: 360, height: 240 });
  await failover.waitForFunction(() => window.nanoui.canvas.width === 720 && window.nanoui.canvas.height === 480);
  await failover.waitForFunction(async () => {
    const before = window.nanoui.host.stats.callbacks;
    await new Promise(resolve => setTimeout(resolve, 300));
    return window.nanoui.host.stats.callbacks === before;
  });
  await failover.evaluate(() => window.nanoui.destroy());
  await failover.close();

  const closing = await context.newPage();
  closing.on('pageerror', e => errors.push(e.message));
  await closing.goto(host.url + '/counter.html');
  await closing.waitForFunction(() => window.nanoui?.gpu?.stats.frames > 0);
  await closing.evaluate(async () => {
    const runtime = window.nanoui;
    const adapter = await navigator.gpu.requestAdapter();
    const device = await adapter.requestDevice();
    navigator.gpu.requestAdapter = () => new Promise(resolve => {
      window.completeRecovery = async () => {
        resolve({ features: adapter.features, requestDevice: async () => device });
        return device.lost;
      };
    });
    runtime.host.debugLoseDevice();
  });
  await closing.waitForFunction(() => !!window.completeRecovery);
  await closing.evaluate(() => {
    const runtime = window.nanoui;
    window.closingCanvas = runtime.canvas;
    runtime.destroy();
    window.completeRecovery().then(info => { window.lateDeviceReason = info.reason; });
  });
  await closing.waitForFunction(() => window.lateDeviceReason === 'destroyed', undefined, { timeout: 5000 });
  assert.equal(await closing.evaluate(() => window.nanoui.canvas === window.closingCanvas &&
    window.nanoui.exports.nanoui_web_frames() === 0), true);
  await closing.close();
  assert.deepEqual(errors,[]);
  console.log('PASS canvas, click, idle, resize/DPR, device loss, disposal, Worker input and idle, Gallery keyboard, Canvas 2D startup, Canvas 2D scale cap, live Canvas 2D failover, teardown during recovery');
} finally { await browser.close(); await host.close(); }
