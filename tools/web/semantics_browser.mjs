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
    await page.locator(`${root} [aria-label="Password"]`).focus();
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
