import assert from 'node:assert/strict';

export async function checkGalleryKeyboard(page, url) {
  await page.goto(url + '/gallery.html');
  await page.waitForFunction(() => window.nanoui?.exports.nanoui_web_frames() > 0);
  const canvas = page.getByLabel('gallery', {exact: true});
  await canvas.focus();
  await page.keyboard.press('Control+k');
  await page.waitForFunction(() => window.nanoui.exports.gallery_palette_query_bytes() === 0);
  await page.keyboard.type('motion');
  await page.waitForFunction(() => window.nanoui.exports.gallery_palette_query_bytes() === 6);
  // Option on macOS and AltGr elsewhere type characters such as @ and €.
  await canvas.evaluate(el => {
    for (const init of [
      { key: '@', code: 'Digit2', altKey: true },
      { key: '€', code: 'KeyE', ctrlKey: true, altKey: true, modifierAltGraph: true },
    ]) {
      el.dispatchEvent(new KeyboardEvent('keydown', { ...init, bubbles: true, cancelable: true }));
      el.dispatchEvent(new KeyboardEvent('keyup', { ...init, bubbles: true, cancelable: true }));
    }
  });
  await page.waitForFunction(() => window.nanoui.exports.gallery_palette_query_bytes() === 10);
  await page.keyboard.press('Backspace');
  await page.keyboard.press('Backspace');
  await page.waitForFunction(() => window.nanoui.exports.gallery_palette_query_bytes() === 6);
  await page.keyboard.press('Backspace');
  await page.waitForFunction(() => window.nanoui.exports.gallery_palette_query_bytes() === 5);
  await page.keyboard.press('Escape');
  await page.waitForFunction(() => window.nanoui.exports.gallery_palette_query_bytes() === -1);
  assert.equal(await canvas.evaluate(el => document.activeElement === el), true);
  await page.keyboard.press('Control+k');
  await page.waitForFunction(() => window.nanoui.exports.gallery_palette_query_bytes() === 0);
  await page.keyboard.type('typography');
  await page.waitForFunction(() => window.nanoui.exports.gallery_palette_query_bytes() === 10);
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('Enter');
  await page.waitForFunction(() => window.nanoui.exports.gallery_palette_query_bytes() === -1);
  await page.evaluate(() => window.nanoui.destroy());
}
