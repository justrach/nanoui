// Five minutes of real-adapter gallery rendering; never opens a window.
import { chromium } from 'playwright';
import { serve } from './serve.mjs';
import { chromiumOptions } from './browser_options.mjs';
import { writeFile } from 'node:fs/promises';
const seconds=Number(process.env.NANOUI_SOAK_SECONDS??300);
if(!Number.isFinite(seconds)||seconds<1)throw Error('Invalid NANOUI_SOAK_SECONDS');
const host=await serve();
const browser=await chromium.launch(chromiumOptions({hardware:true}));
try{
  const page=await browser.newPage({viewport:{width:1000,height:700},deviceScaleFactor:2});
  const errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  page.on('console',m=>{if(m.type()==='error')errors.push(m.text());else console.log(m.text());});
  await page.goto(host.url+'/index.html?app=gallery');
  await page.waitForFunction(()=>window.nanoui?.exports.nanoui_web_frames()>1);
  const result=await page.evaluate(async seconds=>{
    const r=window.nanoui,e=r.exports;
    const adapter=await navigator.gpu.requestAdapter({powerPreference:'high-performance'});
    const info=adapter.info;
    if(info.isFallbackAdapter)throw Error('Soak requires a real GPU');
    if(e.nanoui_web_record_frames())throw Error('Cannot enable frame log');
    const started=performance.now(),until=started+seconds*1000;
    const pages=[['Controls',0],['List',3],['Glass',4],['Motion',5],['Kit',6]];
    const records=pages.map(([name])=>({name,encode:[],instances:0,peak_handles:0}));
    let current=-1,lastRead=e.nanoui_web_log_count(),report=started+10000;
    while(performance.now()<until){
      const index=Math.min(4,Math.floor((performance.now()-started)/(seconds*200)));
      if(index!==current){current=index;e.gallery_page(pages[index][1]);}
      r.requestFrame();await new Promise(resolve=>requestAnimationFrame(resolve));
      const end=e.nanoui_web_log_count(),row=records[current];
      for(let n=lastRead;n<end;n++){
        row.encode.push(e.nanoui_web_log_value(n,3));
        row.instances=Math.max(row.instances,e.nanoui_web_log_value(n,5));
      }
      lastRead=end;row.peak_handles=Math.max(row.peak_handles,r.gpu.objects.size);
      if(performance.now()>=report){
        await r.gpu.check();
        console.log(`Soak ${Math.round((performance.now()-started)/1000)}s: ${row.name}, ${e.nanoui_web_frames()} frames, ${r.gpu.objects.size} handles`);
        report+=10000;
      }
    }
    await r.gpu.check();
    // GPU timestamps arrive asynchronously: harvest the complete frame log at the end.
    const count=e.nanoui_web_log_count();
    const gpu=[];for(let n=0;n<count;n++)gpu.push(e.nanoui_web_log_value(n,4));
    const pct=(a,p)=>{const b=a.toSorted((x,y)=>x-y);return b[Math.min(b.length-1,Math.floor(b.length*p))]??0;};
    const summary={seconds:(performance.now()-started)/1000,adapter:{vendor:info.vendor,architecture:info.architecture,device:info.device,isFallbackAdapter:info.isFallbackAdapter},frames:count,gpu_p50_ms:pct(gpu.filter(x=>x>0),.5),pages:records.map(x=>({name:x.name,frames:x.encode.length,instances:x.instances,peak_handles:x.peak_handles,encode_p50_ms:pct(x.encode,.5),encode_p99_ms:pct(x.encode,.99),encode_max_ms:Math.max(...x.encode)})),validation_errors:r.gpu.diagnostics};
    r.destroy();
    if(r.gpu.objects.size!==1)throw Error(`Leaked ${r.gpu.objects.size-1} handles`);
    return summary;
  },seconds);
  if(errors.length)throw Error(errors.join('\n'));
  console.log(JSON.stringify(result,null,2));
  if(process.env.NANOUI_SOAK_OUTPUT)await writeFile(process.env.NANOUI_SOAK_OUTPUT,JSON.stringify(result,null,2));
}finally{await browser.close();await host.close();}
