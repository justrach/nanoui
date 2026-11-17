// Keep the Chromium revision-dependent launch flags together. All launchers
// are headless, and CI fails if these flags stop exposing a WebGPU adapter.
export function chromiumOptions({hardware=false}={}) {
  return {headless:true,executablePath:process.env.NANOUI_BROWSER_BIN,args:hardware?[
    '--enable-unsafe-webgpu','--use-angle=metal','--ignore-gpu-blocklist',
  ]:[
    '--enable-unsafe-webgpu','--use-gl=angle','--use-angle=swiftshader',
    '--enable-unsafe-swiftshader','--ignore-gpu-blocklist',
    '--enable-features=Vulkan','--use-vulkan=swiftshader',
  ]};
}
