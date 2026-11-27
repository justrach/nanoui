// The semantic DOM layer: password editors, ARIA states, focus inside a
// touch gesture, and placement after the page scrolls.
import assert from 'node:assert/strict';

export async function checkSemantics(browser, url, errors) {
  {
    const context = await browser.newContext({ viewport: { width: 960, height: 960 } });
    const page = await context.newPage();
    page.on('pageerror', e => errors.push(e.message));
    await page.goto(url + '/gallery.html');
    await page.waitForFunction(() => window.nanoui?.exports.nanoui_web_frames() > 0);
    const root = '[data-nanoui-semantics]';
    const password = page.locator(`${root} input[type=password][aria-label="Password"]`);
    assert.equal(await password.count(), 1, 'an unfocused password field has native password semantics');
    await password.focus();
    await page.waitForFunction(() => document.activeElement?.type === 'password');
    await page.keyboard.type('s3cr3t');
    const copied = await page.evaluate(() => {
      document.activeElement.select();
      const event = new ClipboardEvent('copy', { clipboardData: new DataTransfer(), bubbles: true, cancelable: true });
      document.activeElement.dispatchEvent(event);
      return event.clipboardData.getData('text/plain');
    });
    assert.equal(copied, '', 'a password selection is not copied');
    const states = await page.evaluate(root => ({
      disabledButtons: document.querySelectorAll(`${root} button:disabled`).length,
      checkboxes: [...document.querySelectorAll(`${root} [role=checkbox]`)].map(n => [n.getAttribute('aria-checked'), n.hasAttribute('aria-current')]),
    }), root);
    assert.equal(states.disabledButtons, 0, 'disabled controls stay in screen-reader navigation');
    assert.ok(states.checkboxes.length > 0, 'checkboxes have the checkbox role');
    for (const [checked, current] of states.checkboxes) {
      assert.ok(checked === 'true' || checked === 'false');
      assert.equal(current, false);
    }
    await context.close();
  }
  {
    const context = await browser.newContext({ viewport: { width: 960, height: 960 } });
    const page = await context.newPage();
    page.on('pageerror', e => errors.push(e.message));
    // Load the same app through an embedder that forwards every key.
    await page.route('**/gallery.html', async route => {
      const response = await route.fetch();
      const html = (await response.text()).replace('keyboard(e) {', 'keyboard(e) { return true;');
      await route.fulfill({ response, body: html });
    });
    await page.goto(url + '/gallery.html');
    await page.waitForFunction(() => window.nanoui?.exports.nanoui_web_frames() > 0);
    await page.getByLabel('gallery', { exact: true }).focus();
    await page.keyboard.press('Control+k');
    await page.waitForFunction(() => document.activeElement?.tagName === 'TEXTAREA');
    await page.keyboard.type('motion');
    await page.waitForFunction(() => window.nanoui.exports.gallery_palette_query_bytes() === 6);
    await page.keyboard.press('ControlOrMeta+a');
    await page.waitForFunction(() => {
      const event = new ClipboardEvent('copy', { clipboardData: new DataTransfer(), bubbles: true, cancelable: true });
      document.activeElement.dispatchEvent(event);
      return event.clipboardData.getData('text/plain') === 'motion';
    });
    const clipboard = await page.evaluate(() => {
      const editor = document.activeElement;
      for (const ctrl of [true, false]) for (const key of ['c', 'x', 'v']) {
        const event = new KeyboardEvent('keydown', {
          key, code: 'Key' + key.toUpperCase(), ctrlKey: ctrl, metaKey: !ctrl, bubbles: true, cancelable: true,
        });
        if (!editor.dispatchEvent(event)) return { prevented: key };
      }
      // Keep the clipboard data within this browser fixture.
      const data = new DataTransfer();
      editor.dispatchEvent(new ClipboardEvent('cut', { clipboardData: data, bubbles: true, cancelable: true }));
      return { cut: data.getData('text/plain') };
    });
    assert.deepEqual(clipboard, { cut: 'motion' });
    await page.waitForFunction(() => window.nanoui.exports.gallery_palette_query_bytes() === 0);
    await page.evaluate(() => {
      const data = new DataTransfer();
      data.setData('text/plain', 'motion');
      document.activeElement.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
    });
    await page.waitForFunction(() => window.nanoui.exports.gallery_palette_query_bytes() === 6);
    await context.close();
  }
  {
    const context = await browser.newContext({ viewport: { width: 360, height: 640 }, hasTouch: true, isMobile: true });
    const page = await context.newPage();
    page.on('pageerror', e => errors.push(e.message));
    await page.goto(url + '/collection-picker.html');
    await page.waitForFunction(() => window.nanoui?.exports.nanoui_web_frames() > 0);
    const canvas = await page.locator('canvas').boundingBox();
    const center = label => page.evaluate(label => {
      const node = document.querySelector(`[data-nanoui-semantics] [aria-label="${label}"]`);
      return node && { x: node.box.x + node.box.w / 2, y: node.box.y + node.box.h / 2 };
    }, label);
    const trigger = await center('Choose collection');
    await page.touchscreen.tap(canvas.x + trigger.x, canvas.y + trigger.y);
    await page.waitForFunction(() => document.activeElement?.getAttribute('aria-label') === 'Search collections');
    // Record focus inside the release itself, as iOS requires.
    await page.evaluate(() => {
      document.activeElement.blur();
      window.focusInGesture = null;
      window.nanoui.canvas.addEventListener('pointerup', () => {
        window.focusInGesture = document.activeElement?.getAttribute('aria-label');
      }, { once: true });
    });
    const field = await center('Search collections');
    await page.touchscreen.tap(canvas.x + field.x, canvas.y + field.y);
    assert.equal(await page.evaluate(() => window.focusInGesture), 'Search collections');
    // Overlays follow the canvas when the page scrolls.
    await page.evaluate(() => {
      const spacer = document.createElement('div');
      spacer.style.height = '400px';
      document.body.prepend(spacer);
      document.documentElement.style.height = 'auto';
      document.body.style.height = 'auto';
      document.body.style.minHeight = '2000px';
      window.scrollTo(0, 150);
    });
    await page.waitForFunction(() => {
      const node = document.querySelector('[data-nanoui-semantics] [aria-label="Search collections"]');
      const top = window.nanoui.canvas.getBoundingClientRect().top + node.anchor.y;
      return Math.abs(parseFloat(node.style.top) - top) < 1;
    });
    await context.close();
  }
}
