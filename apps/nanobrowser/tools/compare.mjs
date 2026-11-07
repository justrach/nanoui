#!/usr/bin/env node
// Renders pages in nanobrowser and in headless Chromium at the same viewport and
// with the same user agent, and says where they part: side-by-side pictures, and
// the elements whose box differs while their parent's doesn't, which is usually
// the cause rather than a symptom. Nothing is shown on screen.
//
//   node tools/compare.mjs [--out DIR] [--wait S] URL...
//
// Writes DIR/NAME.side.png and DIR/NAME.report.txt; prints one line a page.
import { createRequire } from 'node:module';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = execFileSync('npm', ['root', '-g']).toString().trim();
const { chromium } = createRequire(join(root, 'x.js'))('playwright');

const args = process.argv.slice(2);
let out = '.graff/compare', wait = 6, tolerance = 3;
const urls = [];
while (args.length) {
  const a = args.shift();
  if (a === '--out') out = args.shift();
  else if (a === '--wait') wait = Number(args.shift());
  else if (a === '--tolerance') tolerance = Number(args.shift());
  else urls.push(a);
}
mkdirSync(out, { recursive: true });

// The Mac's user agent: both browsers get the same page.
const pageZig = readFileSync(join(here, '../src/page.zig'), 'utf8');
const major = /chrome_major = "(\d+)"/.exec(pageZig)[1];
const ua = /user_agent = "(.+?)" \+\+ platform_ua \+\+ "(.+?)" \+\+ chrome_major \+\+ "(.+?)";/.exec(pageZig).slice(1).reduce((all, part, i) => all + ['', 'Macintosh; Intel Mac OS X 10_15_7', major][i] + part, '');
const bin = resolve(here, '../zig-out/rel/bin/nanobrowser');
const width = 1280, height = 808, strip = 52;

const nameOf = (u) => u.replace(/^[a-z]+:\/\//, '').replace(/[^a-zA-Z0-9.]+/g, '_').slice(0, 60);

function runNano(url, png, dump) {
  const r = spawnSync(bin, [`--nanoui-snapshot=${png}`, `--nanoui-wait=${wait}`, url], {
    // A home of its own: no cookies or cache from other runs decide what a site sends.
    env: { ...process.env, NANOBROWSER_DUMP: dump, NANOBROWSER_LOG: '1', CFFIXED_USER_HOME: mkdtempSync(join(tmpdir(), 'nbhome')) },
    encoding: 'utf8', timeout: (wait + 60) * 1000,
  });
  const log = (r.stdout || '') + (r.stderr || '');
  return { ok: r.status === 0 && existsSync(dump), log, status: r.status, signal: r.signal };
}

const dumpInPage = () => {
  const parseColor = (c) => {
    const m = c.match(/rgba?\(([^)]+)\)/);
    if (!m) return [0, 0, 0, 0];
    const p = m[1].split(/[ ,/]+/).filter(Boolean).map(Number);
    return [p[0], p[1], p[2], Math.round((p.length > 3 ? p[3] : 1) * 255)];
  };
  const pathOf = (e) => {
    const parts = [];
    for (let n = e; n; n = n.parentElement) {
      let i = 1;
      for (let s = n.previousElementSibling; s; s = s.previousElementSibling) if (s.localName === n.localName) i++;
      parts.unshift(`${n.localName}[${i}]`);
    }
    return parts.join('/');
  };
  const out = [];
  for (const e of document.querySelectorAll('*')) {
    const r = e.getBoundingClientRect();
    const s = getComputedStyle(e);
    const hidden = s.display === 'none' || (r.width === 0 && r.height === 0 && !e.firstChild);
    const row = { path: pathOf(e), id: e.id || '', cls: e.getAttribute('class') || '', display: s.display.replace('-', '_').replace('inline', 'inline'), position: s.position,
      fontSize: parseFloat(s.fontSize), fontWeight: Number(s.fontWeight) || 400, color: parseColor(s.color), bg: parseColor(s.backgroundColor), family: s.fontFamily.slice(0, 40) };
    if (s.display !== 'none') Object.assign(row, { x: r.x + scrollX, y: r.y + scrollY, w: r.width, h: r.height });
    void hidden;
    out.push(row);
  }
  return out;
};

const near = (a, b) => Math.abs(a - b) <= tolerance;
const sameColor = (a, b) => (a[3] === 0 && b[3] === 0) || a.every((v, i) => Math.abs(v - b[i]) <= 3);

function diff(nano, chrome) {
  const byPath = new Map(chrome.map((r) => [r.path, r]));
  const nanoBy = new Map(nano.map((r) => [r.path, r]));
  // Inside an <svg>: it's drawn as one picture here, with no boxes for its parts.
  const inSvg = (p) => /\/svg\[\d+\]\//.test(p);
  const isHead = (p) => /^html\[1\]\/head/.test(p) || /\/(script|style|link|meta|title|noscript|template)\[/.test(p) || /\/br\[\d+\]$/.test(p);
  const lines = { missing: [], extra: [], box: [], color: [], font: [], hidden: [], shown: [] };
  let matched = 0, boxOk = 0, sizeOk = 0;
  const offBy = (r) => {
    const c = byPath.get(r.path);
    return c && r.x !== undefined && c.x !== undefined && !(near(r.x, c.x) && near(r.y, c.y) && near(r.w, c.w) && near(r.h, c.h));
  };
  for (const r of nano) {
    if (isHead(r.path) || inSvg(r.path)) continue;
    const c = byPath.get(r.path);
    if (!c) { lines.extra.push(r); continue; }
    matched++;
    const nanoShown = r.x !== undefined && r.display !== 'none';
    const chromeShown = c.x !== undefined;
    if (nanoShown && !chromeShown) { lines.shown.push({ r, c }); continue; }
    if (!nanoShown && chromeShown && (c.w > 0 || c.h > 0)) { lines.hidden.push({ r, c }); continue; }
    if (!nanoShown) continue;
    if (near(r.w, c.w) && near(r.h, c.h)) sizeOk++;
    if (!offBy(r)) boxOk++;
    else {
      // The cause, not what follows from it: its parent lines up, or differs differently.
      const parent = nanoBy.get(r.path.replace(/\/[^/]+$/, ''));
      if (!parent || !offBy(parent)) lines.box.push({ r, c });
    }
    if (r.color && !sameColor(r.color, c.color)) lines.color.push({ r, c });
    if (r.bg && !sameColor(r.bg, c.bg)) lines.color.push({ r, c, bg: true });
    if (r.fontSize !== undefined && Math.abs(r.fontSize - c.fontSize) > 0.5) lines.font.push({ r, c });
  }
  for (const c of chrome) if (!isHead(c.path) && !inSvg(c.path) && !nanoBy.has(c.path)) lines.missing.push(c);
  return { lines, matched, boxOk, sizeOk };
}

const fmt = (r) => `${r.x?.toFixed(0)},${r.y?.toFixed(0)} ${r.w?.toFixed(0)}x${r.h?.toFixed(0)}`;
const name = (r) => r.path.split('/').slice(-3).join('/') + (r.id ? `#${r.id}` : '') + (r.cls ? `.${r.cls.split(/\s+/).slice(0, 2).join('.')}` : '');

function report(url, res, log) {
  const { lines: l, matched, boxOk, sizeOk } = res;
  const t = [`${url}\nmatched ${matched}, boxes within ${tolerance}px ${boxOk}, same size ${sizeOk}, causes ${l.box.length}, chrome-only ${l.missing.length}, nano-only ${l.extra.length}\n`];
  const section = (title, list, f) => { if (list.length) t.push(`-- ${title} (${list.length})`, ...list.slice(0, 40).map(f), ''); };
  section('box differs, parent fine (nano vs chrome)', l.box, ({ r, c }) => `${name(r)} [${r.display}/${c.display}] nano ${fmt(r)}  chrome ${fmt(c)}`);
  section('shown here, hidden there', l.shown, ({ r }) => name(r));
  section('hidden here, shown there', l.hidden, ({ r, c }) => `${name(r)} nano display=${r.display} chrome ${fmt(c)} ${c.display}`);
  section('color', l.color, ({ r, c, bg }) => `${name(r)} ${bg ? 'bg' : 'fg'} nano ${bg ? r.bg : r.color} chrome ${bg ? c.bg : c.color}`);
  section('font size', l.font, ({ r, c }) => `${name(r)} nano ${r.fontSize} chrome ${c.fontSize}`);
  section('only in chrome (scripts made them, or the parser differs)', l.missing, (c) => `${name(c)} ${fmt(c)}`);
  section('only here', l.extra, (r) => `${name(r)} ${fmt(r)}`);
  const errs = log.split('\n').filter((x) => /\[(error|warn)\]|panic|Uncaught/i.test(x)).slice(0, 30);
  if (errs.length) t.push('-- console', ...errs.map((x) => x.slice(0, 200)));
  return t.join('\n');
}

// Whichever headless shell is installed, rather than the one this Playwright pins.
const cache = join(homedir(), 'Library/Caches/ms-playwright');
const shell = readdirSync(cache).filter((d) => d.startsWith('chromium_headless_shell-')).sort().pop();
const browser = await chromium.launch({ executablePath: join(cache, shell, 'chrome-headless-shell-mac-arm64/chrome-headless-shell') });
const ctx = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 2, userAgent: ua, locale: 'en-US' });
for (const url of urls) {
  const n = nameOf(url);
  const nanoPng = join(out, `${n}.nano.png`), chromePng = join(out, `${n}.chrome.png`), dump = join(out, `${n}.nano.jsonl`);
  const nano = runNano(url, nanoPng, dump);
  const page = await ctx.newPage();
  let chrome = [];
  try {
    await page.goto(url, { waitUntil: 'load', timeout: 30000 }).catch(() => {});
    await page.waitForTimeout(wait * 1000);
    await page.screenshot({ path: chromePng });
    chrome = await page.evaluate(dumpInPage);
  } catch (e) { console.log(`${n}: chromium failed: ${e.message.slice(0, 120)}`); }
  if (!nano.ok) {
    console.log(`${n}: NANOBROWSER FAILED status=${nano.status} signal=${nano.signal}`);
    writeFileSync(join(out, `${n}.report.txt`), `${url}\nnanobrowser failed status=${nano.status} signal=${nano.signal}\n${nano.log.slice(-4000)}`);
    await page.close();
    continue;
  }
  const rows = readFileSync(dump, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const res = diff(rows, chrome);
  writeFileSync(join(out, `${n}.report.txt`), report(url, res, nano.log));
  // Side by side, each cut to the page and to one screenful.
  const b64 = (f) => 'data:image/png;base64,' + readFileSync(f).toString('base64');
  await page.goto('about:blank');
  await page.setViewportSize({ width: width * 2 + 8, height });
  await page.setContent(`<body style="margin:0;background:#f0f;display:flex;gap:8px"><div style="width:${width}px;height:${height}px;overflow:hidden"><img style="width:${width}px;margin-top:-${strip}px" src="${b64(nanoPng)}"></div><img style="width:${width}px" src="${b64(chromePng)}">`);
  await page.waitForTimeout(100);
  await page.screenshot({ path: join(out, `${n}.side.png`) });
  await page.close();
  console.log(`${n}: elements ${res.matched}, placed ${Math.round(100 * res.boxOk / Math.max(1, res.matched))}%, sized ${Math.round(100 * res.sizeOk / Math.max(1, res.matched))}%, causes ${res.lines.box.length}, chrome-only ${res.lines.missing.length}, nano-only ${res.lines.extra.length}`);
}
await browser.close();
