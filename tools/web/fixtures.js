import { codecs } from "./codecs.js";
// Browser-only sources used to verify the app/device boundary.
export function createFixtures(runtime) {
  let compute, computeGeneration, fills = 0;
  return {
    get fills() { return fills; },
    imports: {
      fill(encoder, texture) {
        const r = runtime(), device = r.device;
        if (!compute || computeGeneration !== r.gpu.generation) {
          const module = device.createShaderModule({code:`
            @group(0) @binding(0) var dst: texture_storage_2d<rgba16float,write>;
            @compute @workgroup_size(8,8) fn main(@builtin(global_invocation_id) p: vec3u) {
              if(p.x>=32u || p.y>=24u){return;}
              textureStore(dst,p.xy,vec4f(f32(p.x)/32.0,f32(p.y)/24.0,0.5,1.0));
            }`});
          compute = device.createComputePipeline({layout:'auto',compute:{module,entryPoint:'main'}});
          computeGeneration = r.gpu.generation;
        }
        const group = device.createBindGroup({layout:compute.getBindGroupLayout(0),entries:[{binding:0,resource:r.gpu.objects.get(texture).createView()}]});
        const pass = r.gpu.objects.get(encoder).beginComputePass();
        pass.setPipeline(compute);pass.setBindGroup(0,group);pass.dispatchWorkgroups(4,3);pass.end();fills++;
      },
    },
    async setup(scene) {
      const r = runtime(), held = []; let texture = 0, external = 0, rgb = [128,128,128];
      if(scene===8 || scene===10 || scene===17 || scene===18){
        const tex=r.device.createTexture({size:[32,24],format:'rgba16float',usage:GPUTextureUsage.TEXTURE_BINDING|GPUTextureUsage.COPY_DST|GPUTextureUsage.STORAGE_BINDING});
        texture=r.gpu.objects.put(tex);held.push(()=>{r.gpu.objects.drop(texture);tex.destroy();});
        if(scene===8 || scene===17 || scene===18){
          // Each component is exactly representable as a half float.
          const half=v=>{if(v===0)return 0;const exp=Math.floor(Math.log2(v));return ((exp+15)<<10)|Math.round((v/2**exp-1)*1024);};
          const data=new Uint16Array(32*24*4);
          for(let y=0;y<24;y++)for(let x=0;x<32;x++)data.set([half(x/32),half(y/24),half(0.5),half(1)],(y*32+x)*4);
          r.device.queue.writeTexture({texture:tex},data,{bytesPerRow:32*8},[32,24]);
        }
      }
      if(scene===9 || scene===11 || scene===12 || scene===14 || scene===15){
        const data=new Uint8Array(32*24*3/2);data.fill(81,0,32*24);data.fill(90,32*24,32*24*5/4);data.fill(240,32*24*5/4);
        let frame;
        if(scene===14 || scene===15){
          const config={codec:codecs[scene===14?'h264':'hevc'].codec,hardwareAcceleration:'no-preference',codedWidth:128,codedHeight:128};
          if(!(await VideoDecoder.isConfigSupported(config)).supported)return null;
          let receive,reject;
          const ready=new Promise((yes,no)=>{receive=yes;reject=no;});
          const decoder=new VideoDecoder({output:receive,error:reject});decoder.configure(config);
          const encoded=Uint8Array.from(atob(codecs[scene===14?'h264':'hevc'].data),c=>c.charCodeAt(0));
          decoder.decode(new EncodedVideoChunk({type:'key',timestamp:0,data:encoded}));
          try { await decoder.flush();frame=await ready; } catch(error) { ready.catch(()=>{}); if(decoder.state!=='closed')decoder.close(); throw Error(`${config.codec}: ${error.message}`); } decoder.close();
        }else frame=new VideoFrame(data,{format:'I420',codedWidth:32,codedHeight:24,timestamp:0,colorSpace:{matrix:'bt709',primaries:'bt709',transfer:'bt709',fullRange:false}});
        external=r.gpu.objects.put(frame);held.push(()=>{r.gpu.objects.drop(external);frame.close();});
        const side=scene>=14?128:32;
        const canvas=new OffscreenCanvas(side,side), ctx=canvas.getContext('2d',{willReadFrequently:true});ctx.drawImage(frame,0,0);
        rgb=[...ctx.getImageData(16,12,1,1).data].slice(0,3);
        if(scene>=14){const pixels=ctx.getImageData(0,0,128,128).data;const ref=new Uint8Array(r.exports.memory.buffer,r.exports.parity_reference(),pixels.length);for(let i=0;i<pixels.length;i+=4)ref.set([pixels[i+2],pixels[i+1],pixels[i],pixels[i+3]],i);}
      }
      r.exports.parity_source(texture,external,...rgb);
      r.gpu.forceExternalCopy(scene===12 || globalThis.__forceExternalCopy===true);
      return ()=>{r.gpu.forceExternalCopy(false);for(const free of held)free();};
    },
  };
}
