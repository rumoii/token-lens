import { mock } from 'node:test';
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { normalizeTimestamp } from '../../src/core/adapters/_lines.js';

export const NOW = '2026-01-15T12:00:00.000Z';
mock.timers.enable({ apis: ['Date'], now: Date.parse(NOW) });
const output = resolve('app/rust/tests/golden');
mkdirSync(output, { recursive: true });
const rows = [];
const emit = value => rows.push(JSON.stringify(value));
emit({ type: 'context', now: NOW, tz: 'Asia/Shanghai', alternate_tz: 'UTC' });
for (const value of [0, -0, 1, -1, 1.5, 0.000001, 0.0000001, 1e20, 1e21,
  1000000000000000100, 9007199254740991, 999999999999, 1e12, 0.1 + 0.2,
  Number.MIN_VALUE, Number.MAX_VALUE, 2.2250738585072014e-308]) {
  emit({ type: 'query', fn: 'number', value, expected: String(value) });
}
const dates = [null, false, true, '', 0, 1, -1, 999999999999, 1000000000000,
  '0', '1700000000', '2026-02-30', '2026-10-26', '2026-10-26T12:00:00.123456',
  '2026-01-15T12:00:00Z', '2026-01-15T12:00:00.123+08:00',
  '2026-01-15 12:00:00', '2026-01-15T24:00:00Z', 'invalid', '2026-13-01'];
for (const tz of ['Asia/Shanghai', 'UTC', 'America/New_York']) {
  process.env.TZ = tz;
  for (const value of dates) emit({ type: 'query', fn: 'date', tz, value, expected: normalizeTimestamp(value) });
}
process.env.TZ = 'Asia/Shanghai';
const chars = [...'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/\\:.-_ '];
for (const a of chars) for (const b of chars) {
  emit({ type: 'query', fn: 'locale', a, b, expected: Math.sign(a.localeCompare(b)) });
}
const paths = ['aB', 'Ab', 'ab', 'AB', 'a-b', 'a_b', 'a b', 'a/b', 'a\\b',
  'D:/Logs/rollout-10.jsonl', 'D:/logs/rollout-2.jsonl', 'd:/logs/rollout-02.jsonl',
  'D:\\Logs\\A.jsonl', 'D:\\Logs\\a.jsonl', 'file', 'file ', 'file.', 'FILE_', '1', '10', '2'];
for (const a of paths) for (const b of paths) {
  emit({ type: 'query', fn: 'locale', a, b, expected: Math.sign(a.localeCompare(b)) });
}
writeFileSync(resolve(output, 'jscompat.jsonl'), `${rows.join('\n')}\n`);
console.log(`jscompat: ${rows.length - 1} vectors`);
const { generateLedger } = await import('./ledger.mjs');
generateLedger(output, NOW);
const { generatePricing } = await import('./pricing.mjs');
generatePricing(output, NOW);
const { generateAdapters } = await import('./adapters.mjs');
await generateAdapters(output, NOW);
const { generateIngest } = await import('./ingest.mjs');
await generateIngest(output, NOW);
const {generateQueryBoundaries}=await import('./query-boundaries.mjs');
generateQueryBoundaries(output,NOW);
mock.timers.reset();
