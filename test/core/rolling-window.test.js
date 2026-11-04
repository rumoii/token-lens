import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Ledger } from '../../src/core/db/ledger.js';
import { costOf } from '../../src/core/pricing/engine.js';
import { buildSummary } from '../../src/core/api/v1/usage.js';

const priceOf = (r) => costOf(r);

test('滚动窗口按本地日期算，last_7d 含今天在内共 7 个本地日', async (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: new Date('2026-10-23T12:00:00Z') });
  const ledger = new Ledger(':memory:');
  t.after(() => ledger.close());

  const day = (back) => new Date(Date.now() - back * 86400000).toISOString().slice(0, 10);
  const row = (key, back, input) => ({
    source: 'claude', record_key: key, session_id: 's1', model: 'claude-opus-4-1',
    observed_at: `${day(back)}T12:00:00.000Z`, kind: 'event',
    input_tokens: input, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0
  });
  ledger.write.ingestBatch([
    row('w6', 6, 10),
    row('w7', 7, 100),
    row('w0', 0, 1000)
  ], { priceOf });

  const { rolling } = buildSummary(ledger.read, { tz: 'UTC' });
  // 7 个本地日 = 今天减 6 天到今天；今天减 7 天那条在窗外
  assert.equal(rolling.last_7d.gross_tokens, 1010);
});
