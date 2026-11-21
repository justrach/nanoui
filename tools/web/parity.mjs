// Headless only: no native windows or developer-screen automation.
import { chromium, webkit, firefox } from "playwright";
import { serve } from "./serve.mjs";
import { chromiumOptions } from "./browser_options.mjs";
const host = await serve();
const hardware=process.env.NANOUI_GPU==='hardware';
const engine=process.env.NANOUI_ENGINE??"chromium";
const browser = await ({chromium,webkit,firefox}[engine]).launch(engine === "chromium" ? chromiumOptions({hardware}) : {headless:true});
try {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  page.on("console", message => { if (message.type() === "error") errors.push(message.text()); else console.log(message.text()); });
  if(process.env.NANOUI_FORCE_EXTERNAL_COPY)await page.addInitScript(()=>globalThis.__forceExternalCopy=true);
  await page.goto(host.url);
  const sceneIds=process.env.NANOUI_SCENES?.split(",").map(Number)??(hardware?Array.from({length:19},(_,i)=>i):[...Array.from({length:14},(_,i)=>i),16,17,18]);
  const results = await page.evaluate(async (scenes) => {
    const { load } = await import("./nanoui.js");
    const { createFixtures } = await import("./fixtures.js");
    let runtime;
    const fixtures=createFixtures(()=>runtime);
    runtime = await load({ url: "./nanoui-web-parity.wasm", imports:{nanoui_test:fixtures.imports} });
    const e = runtime.exports;
    const results = [];
    for (const scene of scenes) for (const scale of [1, 2]) for (const format of [0, 1]) {
      const name = `${["widgets","canvas","glass light","glass dark","effects","BGRA texture","affine texture","LUTs","half-float texture","I420 external","compute hook","external LUT","external copy","motion","H.264 VideoFrame","HEVC VideoFrame","image sink","display encoded texture","surface linear texture"][scene]} scale=${scale} ${format ? "rgba" : "bgra"}`;
      const release=await fixtures.setup(scene);
      if(!release){results.push({name,status:0,skipped:true,mean:0,worst:0,off:0,instances:0});continue;}
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`${name}: readback timed out`)), 30000);
        runtime.onReadback = status => { clearTimeout(timer); status ? reject(new Error(`${name}: readback failed`)) : resolve(); };
        const status = e.parity_draw(scene, scale, format);
        if(scene===0 && scale===1 && format===0)e.memory.grow(1);
        if (status) { clearTimeout(timer); reject(new Error(`${name}: draw failed (${status})`)); }
      });
      const status = e.parity_compare();
      if ([9,12,14,15].includes(scene) && e.parity_worst()>6) throw Error(`${name}: external conversion exceeded six levels`);
      if(scene===16 && runtime.gpu.stats.upload_bytes>=1048576)throw Error('Image sink uploaded an entire atlas');
      if (status) {
        const cpuPtr = e.parity_cpu_pixels(), gpuPtr = e.parity_pixels();
        const memory = new Uint8Array(e.memory.buffer); const diffs=[];
        for(let i=0; i<360*300*scale*scale*4; i++) if(Math.abs(memory[cpuPtr+i]-memory[gpuPtr+i])>8 && diffs.length<15) diffs.push({x:Math.floor(i/4)%(360*scale),y:Math.floor(i/4/(360*scale)),channel:i%4,cpu:memory[cpuPtr+i],gpu:memory[gpuPtr+i]});
        console.log(name,JSON.stringify(diffs));
        if(scene===4)console.log("last instance",JSON.stringify([...new Float32Array(e.memory.buffer,e.parity_instances_ptr()+(e.parity_instances()-1)*192,48)]));
      }
      release();
      results.push({ name, status, mean: e.parity_mean(), worst: e.parity_worst(), off: e.parity_off(), instances: e.parity_instances() });
    }
    if (fixtures.fills !== (scenes.includes(10)?4:0)) throw Error(`Compute hook ran ${fixtures.fills} times, expected 4`);
    // A GPUTexture from a previous device is skipped before validation.
    const oldDevice=runtime.device;
    const oldTexture=oldDevice.createTexture({size:[32,24],format:'rgba16float',usage:GPUTextureUsage.TEXTURE_BINDING});
    const oldHandle=runtime.gpu.objects.put(oldTexture);
    const adapter=await navigator.gpu.requestAdapter();const newDevice=await adapter.requestDevice();
    e.parity_reset_renderer();runtime.gpu.setDevice(newDevice);
    e.parity_source(oldHandle,0,0,0,0);
    await new Promise((resolve,reject)=>{
      runtime.onReadback=status=>status?reject(Error('stale-device read failed')):resolve();
      if(e.parity_draw(8,1,0))reject(Error('stale-device draw failed'));
    });
    const stalePixel=new Uint8Array(e.memory.buffer,e.parity_pixels()+(100*360+100)*4,4);
    if(stalePixel[0]!==0xea || stalePixel[1]!==0xe1 || stalePixel[2]!==0xdd || stalePixel[3]!==255)throw Error('A stale texture was drawn');
    runtime.gpu.objects.drop(oldHandle);oldTexture.destroy();oldDevice.destroy();
    await runtime.gpu.check();
    e.parity_deinit();
    if (runtime.gpu.objects.size !== 1) throw new Error(`Leaked ${runtime.gpu.objects.size - 1} GPU handles`);
    runtime.gpu.dispose();newDevice.destroy();
    return results;
  },sceneIds);
  for (const r of results) console.log(`${r.skipped ? "UNSUPPORTED" : r.status ? "FAIL" : "PASS"} ${r.name}: mean=${r.mean.toFixed(5)}, worst=${r.worst}, off=${r.off}, instances=${r.instances}`);
  if (errors.length) throw new Error(errors.join("\n"));
  if (results.some(r => r.status)) throw new Error("WebGPU/CPU parity failed");
} finally {
  await browser.close();
  await host.close();
}
