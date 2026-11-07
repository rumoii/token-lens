import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { priceRecord, costOf, formatMicros, allocateDisplay, PRICE_VERSION } from '../../src/core/pricing/engine.js';
import { findPrice } from '../../src/core/pricing/catalog.js';

export function generatePricing(output, now) {
  const fixture = JSON.parse(readFileSync('test/fixtures/parity/pricing.json','utf8'));
  const rows = [{ type:'context', now, tz:process.env.TZ, price_version:PRICE_VERSION }];
  for (const record of fixture.records) rows.push({ type:'price', record, expected:priceRecord(record), cost:costOf(record) });
  for (const model of fixture.models) rows.push({ type:'query', fn:'findPrice', model, expected:findPrice(model) });
  for (const [micros,scale] of fixture.format) rows.push({ type:'query', fn:'format', micros, scale, expected:formatMicros(micros,scale) });
  for (const [values,total,scale] of fixture.allocate) rows.push({ type:'query', fn:'allocate', values, total, scale, expected:allocateDisplay(values,total,scale) });
  writeFileSync(join(output,'pricing.jsonl'), rows.map(r=>JSON.stringify(r)).join('\n')+'\n');
  console.log(`pricing: ${rows.length-1} vectors`);
}
