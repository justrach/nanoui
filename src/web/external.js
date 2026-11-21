// Some decoded frames have padded coded dimensions. Chromium's external
// sampling/copy paths can filter into that padding despite the visible rect.
// Normalize only those sources through a cropped canvas-backed VideoFrame.
// Ordinary frames keep their zero-copy import path.
export function createExternalSources() {
  let canvas;
  const frames=new Map();
  return {
    get(source, force = false) {
      const rect=source.visibleRect;
      if(!force && (!rect || (rect.x===0 && rect.y===0 && rect.width===source.codedWidth && rect.height===source.codedHeight)))return source;
      const width=rect?.width??source.videoWidth??source.width;
      const height=rect?.height??source.videoHeight??source.height;
      if(!width || !height)return source;
      if(frames.has(source))return frames.get(source);
      if(!canvas)canvas=new OffscreenCanvas(width,height);
      if(canvas.width!==width)canvas.width=width;
      if(canvas.height!==height)canvas.height=height;
      const context=canvas.getContext('2d');
      context.clearRect(0,0,canvas.width,canvas.height);
      // drawImage uses the VideoFrame's visible rectangle, not coded padding.
      context.drawImage(source,0,0,canvas.width,canvas.height);
      const normalized=new VideoFrame(canvas,{timestamp:source.timestamp??0});
      frames.set(source,normalized);return normalized;
    },
    submitted(){for(const frame of frames.values())frame.close();frames.clear();},
    destroy(){this.submitted();canvas=null;},
  };
}
