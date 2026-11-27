import assert from "node:assert/strict";

import { chromiumOptions } from "./browser_options.mjs";
import { serve } from "./serve.mjs";

const { chromium, firefox, webkit } = await import(process.env.NANOUI_PLAYWRIGHT_MODULE ?? "playwright");
const engine = process.env.NANOUI_PICKER_ENGINE ?? "chromium";
const type = { chromium, firefox, webkit }[engine];
if (!type) throw new Error(`Unknown browser engine: ${engine}`);
const browser = await type.launch(engine === "chromium" ? chromiumOptions() : { headless: true });
let server;
try {
  server = await serve();
  for (const cpu of engine === "chromium" ? [false, true] : [true]) {
    const page = await browser.newPage({ viewport: { width: 360, height: 440 } });
    if (cpu) await page.addInitScript(() => Object.defineProperty(navigator, "gpu", { value: undefined }));
    await page.goto(server.url + "/collection-picker.html");
    await page.waitForFunction(() => window.nanoui?.exports.nanoui_web_frames() > 0);
    assert.equal(await page.evaluate(() => !window.nanoui.gpu), cpu);

    const trigger = page.getByRole("button", { name: "Choose collection" });
    await trigger.focus();
    await page.keyboard.press("Enter");
    const input = page.getByRole("textbox", { name: "Search collections" });
    await input.waitFor();
    await page.waitForFunction(() => document.activeElement?.tagName === "TEXTAREA");

    if (engine === "chromium") {
      const ime = await page.context().newCDPSession(page);
      await ime.send("Input.imeSetComposition", { text: "に", selectionStart: 1, selectionEnd: 1 });
      await input.evaluate(el => {
        if (el.style.opacity !== "1") throw new Error("Composition is not visible");
      });
      await ime.send("Input.insertText", { text: "日本" });
    } else {
      await input.evaluate(el => {
        el.dispatchEvent(new CompositionEvent("compositionstart"));
        if (el.style.opacity !== "1") throw new Error("Composition is not visible");
        el.dispatchEvent(new CompositionEvent("compositionend", { data: "日本" }));
      });
    }
    const result = page.getByRole("button", { name: "日本語の資料" });
    await result.waitFor();
    await page.getByRole("button", { name: "Art history" }).waitFor({ state: "detached" });

    await page.keyboard.press("Control+a");
    await page.waitForFunction(() => !document.activeElement?.value);
    // These browser clipboard events are scoped to this test. No system clipboard.
    await page.waitForFunction(() => {
      const data = new DataTransfer();
      const event = new ClipboardEvent("copy", { clipboardData: data, bubbles: true, cancelable: true });
      document.activeElement.dispatchEvent(event);
      return event.clipboardData.getData("text/plain") === "日本";
    });
    const cut = await input.evaluate(el => {
      const event = new ClipboardEvent("cut", { clipboardData: new DataTransfer(), bubbles: true, cancelable: true });
      el.dispatchEvent(event);
      return event.clipboardData.getData("text/plain");
    });
    assert.equal(cut, "日本");
    await page.getByRole("button", { name: "Art history" }).waitFor();
    await input.evaluate(el => {
      const data = new DataTransfer();
      data.setData("text/plain", "Café");
      el.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    });
    const cafe = page.getByRole("button", { name: "Café notebooks" });
    await cafe.waitFor();
    // DOM action on the projected button goes through Zig's a11y action path.
    await cafe.focus();
    await page.keyboard.press("Enter");
    await input.waitFor({ state: "detached" });
    await page.waitForFunction(() => document.activeElement.getAttribute("aria-label") === "Choose collection");

    await page.keyboard.press("Enter");
    await input.waitFor();
    await page.waitForFunction(() => document.activeElement?.tagName === "TEXTAREA");
    await page.keyboard.press("Escape");
    await input.waitFor({ state: "detached" });
    await page.waitForFunction(() => document.activeElement.getAttribute("aria-label") === "Choose collection");

    if (cpu) {
      const pixels = await page.locator("canvas").evaluate(el => el.getContext("2d").getImageData(0, 0, 150, 100).data.some((value, i, bytes) => i % 4 === 0 && value !== bytes[0]));
      assert.equal(pixels, true, "Canvas 2D presented nonuniform content");
    }
    await page.waitForTimeout(300);
    const frames = await page.evaluate(() => window.nanoui.host.stats.callbacks);
    await page.waitForTimeout(300);
    assert.equal(await page.evaluate(() => window.nanoui.host.stats.callbacks), frames);

    console.log(`PASS collection picker, composition, semantics, focus and clipboard on ${cpu ? "Canvas 2D" : "WebGPU"}`);
    await page.evaluate(() => window.nanoui.destroy());
    await page.close();
  }
} finally {
  await browser.close();
  await server?.close();
}
