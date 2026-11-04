import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Ledger } from '../../src/core/db/ledger.js';

const row = (key) => ({
  source: 'claude', record_key: key, session_id: key, model: 'test-model',
  kind: 'event', observed_at: '2026-10-20T00:00:00.000Z',
  input_tokens: 10, output_tokens: 5, cache_read_tokens: null, cache_write_tokens: 0
});
const price = () => ({ cost_micros: 25, price_version: 'old', price_source: 'test' });

test('账本：批次中途计价失败回滚已插入的行，并允许下一次写入', (t) => {
  const ledger = new Ledger(':memory:');
  t.after(() => ledger.close());
  ledger.write.ingestBatch([row('existing')], { priceOf: price });
  const before = ledger.read.totals();
  assert.throws(() => ledger.write.ingestBatch([row('first'), row('second')], {
    priceOf: (record) => {
      if (record.record_key === 'second') throw new Error('pricing failed');
      return price();
    }
  }), /pricing failed/);
  assert.deepEqual(ledger.read.totals(), before);
  assert.equal(ledger.write.ingestBatch([row('retry')], { priceOf: price }).inserted, 1);
  assert.equal(ledger.read.totals().record_count, 2);
});

test('账本：重定价中途失败回滚金额和价格版本，查询继续可用', (t) => {
  const ledger = new Ledger(':memory:');
  t.after(() => ledger.close());
  ledger.write.ingestBatch([row('first'), row('second')], { priceOf: price });
  const before = ledger.read.totals();
  assert.throws(() => ledger.write.reprice((record) => {
    if (record.record_key === 'second') throw new Error('repricing failed');
    return { ...price(), cost_micros: 100, price_version: 'new' };
  }, 'new'), /repricing failed/);
  assert.deepEqual(ledger.read.totals(), before);
  assert.deepEqual(ledger.read.priceVersions(), []);
  assert.equal(ledger.write.reprice(() => ({ ...price(), cost_micros: 100, price_version: 'new' }), 'new'), 2);
  assert.equal(ledger.read.totals().cost_micros, 200);
});

test('账本：替换旧账失败时恢复原有旧账，且不影响当前统计', (t) => {
  const ledger = new Ledger(':memory:');
  t.after(() => ledger.close());
  ledger.write.importLegacyRows([{ id: 1, source: 'original' }]);
  assert.throws(() => ledger.write.importLegacyRows([{ id: 2 }, { id: Symbol('invalid') }], { replace: true }));
  assert.equal(ledger.read.legacyCount(), 1);
  assert.equal(ledger.read.totals().record_count, 0);
  assert.equal(ledger.write.importLegacyRows([{ id: 3 }]), 1);
  assert.equal(ledger.read.legacyCount(), 2);
});

test('账本：所有者关闭连接后，已持有的查询与写入都失败', () => {
  const ledger = new Ledger(':memory:');
  ledger.write.ingestBatch([row('first')]);
  const reader = ledger.read;
  const writer = ledger.write;
  assert.equal(reader.close, undefined);
  assert.equal(reader.ingestBatch, undefined);
  assert.equal(writer.close, undefined);
  assert.equal(writer.totals, undefined);
  const read = () => reader.totals();
  const write = () => writer.ingestBatch([row('second')]);
  ledger.close();
  assert.throws(read, /database is not open/);
  assert.throws(write, /database is not open/);
});

test('账本：开库或读写模块初始化失败时释放连接，文件可重新取得独占访问', (t) => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-db-startup-'));
  t.after(() => rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));
  // A failed startup runs in a child so even the failing implementation releases its handles on exit.
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import { DatabaseSync } from 'node:sqlite';
    import { join } from 'node:path';
    import { Ledger } from ${JSON.stringify(new URL('../../src/core/db/ledger.js', import.meta.url).href)};
    for (const version of [5, 6]) {
      const file = join(process.argv[1], version + '.db');
      const raw = new DatabaseSync(file);
      raw.exec('CREATE TABLE usage_records (id INTEGER); PRAGMA user_version = ' + version);
      raw.close();
      assert.throws(() => new Ledger(file), version === 5 ? /no such column/ : /高于/);
      const probe = new DatabaseSync(file);
      try {
        probe.exec('PRAGMA busy_timeout = 0');
        probe.exec('PRAGMA journal_mode = DELETE');
      } finally { probe.close(); }
    }
  `, dir], { encoding: 'utf8', timeout: 10_000, windowsHide: true });
  assert.equal(result.status, 0, result.stderr + result.stdout);
});
