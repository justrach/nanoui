// Optional asynchronous GPU timestamps. A bounded pool skips a measurement
// rather than stalling if previous readbacks are still in flight.
export function createTiming(device, onSample = () => {}) {
  const supported = device.features.has('timestamp-query');
  const query = supported ? device.createQuerySet({type:'timestamp',count:256}) : null;
  const slots = supported ? Array.from({length:3},()=>({
    resolve:device.createBuffer({size:2048,usage:GPUBufferUsage.QUERY_RESOLVE|GPUBufferUsage.COPY_SRC}),
    read:device.createBuffer({size:2048,usage:GPUBufferUsage.COPY_DST|GPUBufferUsage.MAP_READ}),busy:false,
  })) : [];
  let count=0, pending=null, dead=false;
  const stats={frames:0,encode_ms:0,gpu_ms:null,draws:0,upload_bytes:0,samples:[]};
  let started=0,draws=0,uploaded=0;
  return {
    stats,
    upload(bytes){uploaded+=bytes;},
    begin(){count=0;pending=slots.find(s=>!s.busy)??null;started=performance.now();draws=0;},
    draw(){draws++;},
    writes(){
      if(!pending || count>=256)return undefined;
      const start=count;count+=2;
      return {querySet:query,beginningOfPassWriteIndex:start,endOfPassWriteIndex:start+1};
    },
    resolve(encoder){
      if(!pending || count===0)return;
      encoder.resolveQuerySet(query,0,count,pending.resolve,0);
      encoder.copyBufferToBuffer(pending.resolve,0,pending.read,0,count*8);
    },
    submit(){
      stats.frames++;stats.encode_ms=performance.now()-started;stats.draws=draws;stats.upload_bytes=uploaded;uploaded=0;
      const sample={encode_ms:stats.encode_ms,gpu_ms:null,draws,upload_bytes:stats.upload_bytes};
      stats.samples.push(sample);if(stats.samples.length>512)stats.samples.shift();
      const slot=pending,n=count;
      if(!slot || !n)return;
      slot.busy=true;
      slot.read.mapAsync(GPUMapMode.READ,0,n*8).then(()=>{
        const values=new BigUint64Array(slot.read.getMappedRange(0,n*8));
        const ms=Number(values[n-1]-values[0])/1e6;
        if(!dead){stats.gpu_ms=ms;sample.gpu_ms=ms;onSample(sample);}
        slot.read.unmap();
      }).catch(()=>{}).finally(()=>{slot.busy=false;});
    },
    destroy(){dead=true;query?.destroy();for(const s of slots){s.resolve.destroy();s.read.destroy();}},
  };
}
