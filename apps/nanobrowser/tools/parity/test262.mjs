#!/usr/bin/env node
// Runs tc39/test262 with the engine alone, each file once, as Ladybird's published
// numbers count them (strict only when a test says `onlyStrict`).
//
//   node tools/parity/test262.mjs --suite DIR --host BIN --out results.json [--jobs N] [FILTER]
//
// `results.json` maps each test's path to PASSED or to what went wrong, in the shape
// of Ladybird's per-file data, so `report.py` can put the two side by side.
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { cpus } from 'node:os';

const argv = process.argv.slice(2);
const opt = { jobs: Math.max(1, cpus().length - 4), timeout: 60 };
const filters = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i].startsWith('--')) opt[argv[i].slice(2)] = argv[++i];
  else filters.push(argv[i]);
}
const suite = resolve(opt.suite);
const host = resolve(opt.host);

function walk(dir, out) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (name.endsWith('.js') && !name.includes('_FIXTURE')) out.push(p);
  }
  return out;
}

function listField(text, key) {
  const inline = text.match(new RegExp(`^${key}:\\s*\\[([^\\]]*)\\]`, 'm'));
  if (inline) return inline[1].split(',').map((s) => s.trim()).filter(Boolean);
  const block = text.match(new RegExp(`^${key}:\\s*\\n((?:\\s+-\\s*.+\\n)+)`, 'm'));
  if (block) return block[1].split('\n').map((s) => s.replace(/^\s+-\s*/, '').trim()).filter(Boolean);
  return [];
}

function metadata(src) {
  const m = src.match(/\/\*---([\s\S]*?)---\*\//);
  const text = m ? m[1] : '';
  const negative = text.match(/^negative:\s*\n\s+phase:\s*(\w+)\s*\n\s+type:\s*(\w+)/m)
    ?? text.match(/^negative:\s*\n\s+type:\s*(\w+)\s*\n\s+phase:\s*(\w+)/m);
  let neg = null;
  if (negative) {
    const phases = ['parse', 'resolution', 'runtime'];
    neg = phases.includes(negative[1]) ? { phase: negative[1], type: negative[2] } : { phase: negative[2], type: negative[1] };
  }
  return { flags: listField(text, 'flags'), includes: listField(text, 'includes'), neg };
}

function judge(meta, out, code, signal, timedOut) {
  if (timedOut) return 'TIMEOUT_ERROR';
  if (signal || code !== 0) return `PROCESS_ERROR ${signal ?? code}`;
  const lines = out.trimEnd().split('\n');
  const last = lines.findLast((l) => l.startsWith('RESULT ')) ?? '';
  if (!last) return 'PROCESS_ERROR no result';
  const [, phase, detail = ''] = last.match(/^RESULT (\w+)(?: (.*))?$/) ?? [];
  if (phase === 'harness') return `HARNESS_ERROR ${detail}`;
  if (detail.startsWith('Timeout:')) return 'TIMEOUT_ERROR';
  if (meta.neg) {
    if (phase === 'ok') return `FAILED expected ${meta.neg.phase} ${meta.neg.type}`;
    const name = detail.split(':')[0];
    if (phase === meta.neg.phase && name === meta.neg.type) return 'PASSED';
    return `FAILED expected ${meta.neg.phase} ${meta.neg.type}, got ${phase} ${detail}`;
  }
  if (phase !== 'ok') return `FAILED ${phase} ${detail}`;
  if (meta.flags.includes('async')) {
    if (lines.some((l) => l.startsWith('Test262:AsyncTestComplete'))) return 'PASSED';
    const failure = lines.find((l) => l.startsWith('Test262:AsyncTestFailure'));
    return `FAILED ${failure ?? 'async test never finished'}`;
  }
  return 'PASSED';
}

function runOne(path) {
  const src = readFileSync(path, 'utf8');
  const meta = metadata(src);
  const args = [];
  const raw = meta.flags.includes('raw');
  const harness = (f) => args.push('--include', join(suite, 'harness', f));
  if (!raw) { harness('assert.js'); harness('sta.js'); }
  if (meta.flags.includes('async')) harness('doneprintHandle.js');
  for (const f of meta.includes) harness(f);
  if (meta.flags.includes('module')) args.push('--module');
  if (meta.flags.includes('onlyStrict')) args.push('--strict');
  args.push(path);
  return new Promise((done) => {
    const p = spawn(host, args, { stdio: ['ignore', 'ignore', 'pipe'] });
    let out = '';
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; p.kill('SIGKILL'); }, opt.timeout * 1000);
    p.stderr.on('data', (d) => { if (out.length < 1 << 20) out += d; });
    p.on('close', (code, signal) => { clearTimeout(timer); done(judge(meta, out, code, signal, timedOut)); });
  });
}

let tests = walk(join(suite, 'test'), []);
if (filters.length) tests = tests.filter((t) => filters.some((f) => t.includes(f)));
const results = {};
let next = 0;
let finished = 0;
const started = Date.now();
await Promise.all(Array.from({ length: Number(opt.jobs) }, async () => {
  while (next < tests.length) {
    const path = tests[next++];
    results[relative(suite, path)] = await runOne(path);
    if (++finished % 5000 === 0) console.error(`${finished}/${tests.length} ${((Date.now() - started) / 1000).toFixed(0)}s`);
  }
}));
const kinds = {};
for (const v of Object.values(results)) { const k = v.split(' ')[0]; kinds[k] = (kinds[k] ?? 0) + 1; }
writeFileSync(opt.out, JSON.stringify({ duration: (Date.now() - started) / 1000, results }));
console.log(`total ${tests.length} ${JSON.stringify(kinds)} in ${((Date.now() - started) / 1000).toFixed(0)}s`);
