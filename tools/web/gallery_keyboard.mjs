import assert from 'node:assert/strict';

export async function checkGalleryKeyboard(page, url) {
  await page.goto(url + '/index.html?app=gallery');
  await page.waitForFunction(() => window.nanoui?.exports.nanoui_web_frames() > 0);
  const canvas = page.getByLabel('nanoui Gallery');
  await canvas.focus();
  await page.keyboard.press('Control+k');
  await page.waitForFunction(() => window.nanoui.exports.gallery_palette_query_bytes() === 0);
  await page.keyboard.type('motion');
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
