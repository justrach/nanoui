// Real-adapter measurement by default; --software exercises CI's adapter.
import { chromium } from 'playwright';
import { serve } from './serve.mjs';
import { chromiumOptions } from './browser_options.mjs';
import { writeFile } from 'node:fs/promises';
const software=process.argv.includes('--software');
const frames=Number(process.env.NANOUI_PERF_FRAMES ?? 120);
const host=await serve();
const browser=await chromium.launch(chromiumOptions({hardware:!software}));
try{
  const page=await browser.newPage({viewport:{width:1000,height:700},deviceScaleFactor:2});
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(host.url+'/index.html?app=gallery');
  await page.waitForFunction(()=>window.nanoui?.exports.nanoui_web_frames()>1);
  const result=await page.evaluate(async frames=>{
    const r=window.nanoui,e=r.exports;
    const adapter=await navigator.gpu.requestAdapter({powerPreference:'high-performance'});
    const adapterInfo=adapter.info.toJSON?.()??{vendor:adapter.info.vendor,architecture:adapter.info.architecture,device:adapter.info.device,description:adapter.info.description,isFallbackAdapter:adapter.info.isFallbackAdapter};
    if(e.nanoui_web_record_frames())throw Error('Frame logging failed');
    const pages=[];
    const waitFrame=()=>new Promise(resolve=>requestAnimationFrame(resolve));
    for(const [name,index]of[['Controls',0],['List',3],['Glass',4],['Motion',5],['Kit',6]]){
      e.gallery_page(index);
      for(let n=0;n<10;n++){r.requestFrame();await waitFrame();}
      const start=e.nanoui_web_log_count();
      for(let n=0;n<frames;n++){r.requestFrame();await waitFrame();}
      await r.gpu.check();await new Promise(resolve=>setTimeout(resolve,100));
      const stop=e.nanoui_web_log_count(), records=[];
      for(let n=start;n<stop;n++)records.push({build_ms:e.nanoui_web_log_value(n,0),layout_ms:e.nanoui_web_log_value(n,1),paint_ms:e.nanoui_web_log_value(n,2),encode_ms:e.nanoui_web_log_value(n,3),gpu_ms:e.nanoui_web_log_value(n,4),instances:e.nanoui_web_log_value(n,5)});
      pages.push({name,records});
    }
    const summary={adapter:adapterInfo,features:[...r.device.features],pages};
    r.destroy();return summary;
  },frames);
  if(errors.length)throw Error(errors.join('\n'));
  const pct=(values,p)=>{const sorted=values.toSorted((a,b)=>a-b);return sorted[Math.min(sorted.length-1,Math.floor(p*sorted.length))]??0;};
  const summary={software,adapter:result.adapter,features:result.features,pages:result.pages.map(p=>({name:p.name,frames:p.records.length,instances:Math.max(...p.records.map(r=>r.instances)),encode_p50_ms:pct(p.records.map(r=>r.encode_ms),.5),encode_p99_ms:pct(p.records.map(r=>r.encode_ms),.99),gpu_p50_ms:pct(p.records.map(r=>r.gpu_ms),.5)}))};
  console.log(JSON.stringify(summary,null,2));
  if(process.env.NANOUI_PERF_OUTPUT)await writeFile(process.env.NANOUI_PERF_OUTPUT,JSON.stringify({summary,...result},null,2));
}finally{await browser.close();await host.close();}
