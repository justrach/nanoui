// Worker-hosted canvases started with worker_page.js: real DOM input, idle,
// Canvas 2D recovery with resize and focus, a declined replacement,
// teardown while recovery waits, and keyboard input.
import assert from 'node:assert/strict';

// Lets a test lose the Worker's device and fail the WebGPU retry.
const loseDevice = `
self.addEventListener("message", ({ data }) => {
  if (!data.loseDevice) return;
  navigator.gpu.requestAdapter = async () => null;
  runtime.host.debugLoseDevice();
});
`;

async function open(context, base, app, errors) {
  const page = await context.newPage();
  page.on('pageerror', e => errors.push(e.message));
  await page.route('**/worker.js', async route => {
    const response = await route.fetch();
    await route.fulfill({ response, body: (await response.text()) + loseDevice });
  });
  await page.goto(base + '/index.html');
  await page.waitForFunction(() => window.nanoui?.exports.nanoui_web_frames() > 0);
  await page.evaluate(async app => {
    window.nanoui.destroy();
    document.querySelector('canvas').remove();
    const { startWorker } = await import('./worker_page.js');
    const canvas = document.createElement('canvas');
    canvas.style.cssText = 'display:block;width:420px;height:300px';
    canvas.setAttribute('aria-label', 'Worker canvas');
    document.body.append(canvas);
    const worker = new Worker('./worker.js', { type: 'module' });
    const pending = new Map();
    let seq = 0, release;
    const probe = { worker, errors: [], replacements: 0, destroyed: false };
    worker.addEventListener('message', ({ data }) => {
      if (data.destroyed) probe.destroyed = true;
      const resolve = pending.get(data.id);
      if (resolve) { pending.delete(data.id); resolve(data); }
    });
    probe.handle = startWorker({
      canvas, worker, url: `./${app}.wasm`, cpuFallback: true,
      keyboard: e => e.key !== 'Tab' && (!(e.ctrlKey || e.metaKey) || e.key.toLowerCase() === 'k'),
      canReplaceCanvas: () => new Promise(resolve => { probe.replacements++; release = resolve; }),
      onError: error => probe.errors.push(error.message),
    });
    probe.release = ok => release(ok);
    probe.info = () => new Promise(resolve => {
      const id = ++seq;
      pending.set(id, resolve);
      worker.postMessage({ info: id, read: ['counter_value', 'gallery_palette_query_bytes'] });
    });
    await probe.handle.ready;
    window.probe = probe;
  }, app);
  return page;
}

// Waits for an export to reach a value and then for a second without frames.
function settled(page, name, value) {
  return page.waitForFunction(async ([name, value]) => {
    const before = await window.probe.info();
    if (before.exports[name] !== value) return false;
    await new Promise(resolve => setTimeout(resolve, 1000));
    const after = await window.probe.info();
    return after.exports[name] === value && after.callbacks === before.callbacks;
  }, [name, value], { timeout: 10000 });
}

async function lose(page) {
  const info = await page.evaluate(() => {
    window.probe.worker.postMessage({ loseDevice: true });
    return window.probe.info();
  });
  await page.waitForFunction(() => window.probe.replacements === 1);
  return info;
}

async function closeWorker(page) {
  await page.evaluate(() => window.probe.handle.destroy());
  await page.waitForFunction(() => window.probe.destroyed);
  await page.close();
}

export async function checkWorker(context, base, errors) {
  {
    const page = await open(context, base, 'counter', errors);
    const canvas = page.getByLabel('Worker canvas');
    await canvas.click({ position: { x: 207, y: 185 } });
    await settled(page, 'counter_value', 1);
    await page.evaluate(() => window.probe.handle.canvas.focus());
    const before = await lose(page);
    assert.equal(before.renderer, 'WebGPU');
    // Resize while recovery waits for the page to supply a canvas.
    await page.evaluate(() => { window.probe.handle.canvas.style.width = '400px'; });
    await page.waitForTimeout(100);
    await page.evaluate(() => window.probe.release(true));
    await page.waitForFunction(async before => {
      const info = await window.probe.info();
      return info.renderer === 'Canvas 2D' && info.exports.counter_value === 1 && info.frames > before.frames;
    }, before);
    await page.waitForFunction(() => {
      const canvas = window.probe.handle.canvas;
      return document.activeElement === canvas && canvas.width === 800 && canvas.height === 600 &&
        document.querySelectorAll('canvas').length === 1;
    });
    const png = await canvas.screenshot({ scale: 'device' });
    assert.equal(await page.evaluate(async data => {
      const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0));
      const bitmap = await createImageBitmap(new Blob([bytes], { type: 'image/png' }));
      const scratch = new OffscreenCanvas(bitmap.width, bitmap.height).getContext('2d');
      scratch.drawImage(bitmap, 0, 0);
      bitmap.close();
      const pixels = scratch.getImageData(25, 25, 750, 550).data;
      return pixels.some((value, index) => index % 4 === 0 && value !== pixels[0]);
    }, png.toString('base64')), true, 'Worker Canvas 2D presents visible content');
    // DOM input reaches the Worker through the replacement element.
    await canvas.click({ position: { x: 197, y: 185 } });
    await settled(page, 'counter_value', 2);
    assert.deepEqual(await page.evaluate(() => window.probe.errors), []);
    await closeWorker(page);
  }
  {
    // A page that declines keeps its element; the Worker reports the failure.
    const page = await open(context, base, 'counter', errors);
    await lose(page);
    await page.evaluate(() => {
      window.original = window.probe.handle.canvas;
      window.probe.release(false);
    });
    await page.waitForFunction(() => window.probe.errors.length === 1);
    const stopped = await page.evaluate(() => window.probe.info());
    await page.waitForTimeout(300);
    const later = await page.evaluate(() => window.probe.info());
    assert.equal(later.frames, stopped.frames);
    assert.equal(await page.evaluate(() => window.probe.handle.canvas === window.original &&
      document.querySelectorAll('canvas').length === 1), true);
    await closeWorker(page);
  }
  {
    // Destroying while recovery waits resolves it without a replacement.
    const page = await open(context, base, 'counter', errors);
    await lose(page);
    await page.evaluate(() => {
      window.original = window.probe.handle.canvas;
      window.probe.handle.destroy();
    });
    await page.waitForFunction(() => window.probe.destroyed);
    await page.evaluate(() => window.probe.release(true));
    await page.waitForTimeout(200);
    assert.equal(await page.evaluate(() => window.probe.handle.canvas === window.original &&
      window.original.isConnected && window.probe.errors.length === 0), true);
    await page.close();
  }
  {
    // ready settles on failure, and diagnostics cannot call internal exports.
    const page = await open(context, base, 'counter', errors);
    const read = await page.evaluate(() => new Promise(resolve => {
      const { worker } = window.probe;
      const listener = ({ data }) => {
        if (data.id !== 'read') return;
        worker.removeEventListener('message', listener);
        resolve(data);
      };
      worker.addEventListener('message', listener);
      worker.postMessage({ info: 'read', read: ['_start', 'nanoui_web_destroy', 'counter_value'] });
    }));
    assert.deepEqual(read.exports, { counter_value: 0 });
    assert.equal((await page.evaluate(() => window.probe.info())).exports.counter_value, 0);
    await closeWorker(page);
    const failures = await context.newPage();
    failures.on('pageerror', e => errors.push(e.message));
    await failures.goto(base + '/index.html');
    await failures.waitForFunction(() => window.nanoui?.exports.nanoui_web_frames() > 0);
    const outcomes = await failures.evaluate(async () => {
      window.nanoui.destroy();
      const { startWorker } = await import('./worker_page.js');
      const outcome = async (url, destroyEarly) => {
        const canvas = document.createElement('canvas');
        canvas.style.cssText = 'width:100px;height:100px';
        document.body.append(canvas);
        const view = startWorker({ canvas, worker: new Worker('./worker.js', { type: 'module' }), url, onError: () => {} });
        if (destroyEarly) view.destroy();
        try { await view.ready; return 'ready'; } catch (error) { return error.message; } finally { view.destroy(); }
      };
      return [await outcome('./missing.wasm', false), await outcome('./counter.wasm', true)];
    });
    assert.match(outcomes[0], /404|HTTP/);
    assert.equal(outcomes[1], 'The Worker view was destroyed');
    await failures.close();
  }
  {
    const page = await open(context, base, 'gallery', errors);
    await page.getByLabel('Worker canvas').focus();
    await page.keyboard.press('Control+k');
    await page.waitForFunction(async () => (await window.probe.info()).exports.gallery_palette_query_bytes === 0);
    await page.keyboard.type('ab');
    await page.waitForFunction(async () => (await window.probe.info()).exports.gallery_palette_query_bytes === 2);
    await page.keyboard.press('Escape');
    await settled(page, 'gallery_palette_query_bytes', -1);
    assert.equal(await page.evaluate(() => document.activeElement === window.probe.handle.canvas), true);
    await closeWorker(page);
  }
}
