import { readFileSync, writeFileSync, mkdirSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { DatabaseSync } from 'node:sqlite';
import { Ledger } from '../../src/core/db/ledger.js';
import { openLedger } from '../../src/core/db/open.js';
import { payloadHash } from '../../src/core/db/write.js';
import { identity } from './identity.mjs';

export function generateLedger(output, now) {
  const fixture = JSON.parse(readFileSync('test/fixtures/parity/ledger.json', 'utf8'));
  const rows = [{ type: 'context', now, tz: process.env.TZ }];
  const ledger = new Ledger(':memory:');
  const priceOf = r => ({ cost_micros: r.input_tokens * (r.ended_at ? 2 : 7), price_version: 'test-v1', price_source: 'test:time' });
  let id = ledger.write.beginRun();
  for (const [index, batch] of fixture.batches.entries()) {
    const records = batch.records.map(overrides => ({ ...fixture.base, ...overrides }));
    rows.push({ type: 'batch', index, expected: ledger.write.ingestBatch(records, { sourceFile: batch.file, parserRev: batch.rev, elsewhere: new Set(batch.elsewhere || []), priceOf }) });
    for (const record of records) rows.push({ type: 'identity', index, record, ...identity(record) });
  }
  ledger.write.recordRun('ok', { attempted: 1, inserted: 1, updated: 0, unchanged: 0, rejected: 0, counts: { vanished: 1 }, anomalies: ['synthetic'] }, id);
  id = ledger.write.beginRun();
  ledger.write.failRun(id, 'synthetic');
  ledger.write.beginRun();
  ledger.write.beginRun();
  rows.push({ type: 'run', expected: ledger.read.lastRun() });
  rows.push({ type: 'query', fn: 'reprice', expected: ledger.write.reprice(r => ({ cost_micros: r.input_tokens * 11, price_version: 'test-v2', price_source: 'test:v2' }), 'test-v2') });
  rows.push({ type: 'query', fn: 'reprice_again', expected: ledger.write.reprice(() => { throw Error('must not reprice twice'); }, 'test-v2') });
  // Ledger deliberately owns its connection. Export through another connection only for disk DBs.
  // Replay the identical fixture into a disk ledger to export every stored column.
  ledger.close();
  const root = mkdtempSync(join(tmpdir(), 'token-lens-d31-golden-'));
  const file = join(root, 'ledger.db');
  const disk = new Ledger(file);
  for (const batch of fixture.batches) disk.write.ingestBatch(batch.records.map(overrides => ({ ...fixture.base, ...overrides })), { sourceFile: batch.file, parserRev: batch.rev, elsewhere: new Set(batch.elsewhere || []), priceOf });
  disk.close();
  const db = new DatabaseSync(file, { readOnly: true });
  for (const row of db.prepare('SELECT u.*, s.record_key AS superseded_key FROM usage_records u LEFT JOIN usage_records s ON s.id=u.superseded_by ORDER BY u.record_key').all()) {
    delete row.id;
    row.ingested_at = '<volatile>';
    row.superseded_by = row.superseded_key;
    delete row.superseded_key;
    rows.push({ type: 'ledger_row', expected: row });
  }
  db.close();
  const repriced=new Ledger(file);
  repriced.write.reprice(r=>({cost_micros:r.input_tokens*11,price_version:'test-v2',price_source:'test:v2'}),'test-v2');
  repriced.close();
  const priced=new DatabaseSync(file,{readOnly:true});
  rows.push({type:'query',fn:'reprice_rows',expected:priced.prepare('SELECT record_key,price_version,cost_micros,price_source FROM usage_records ORDER BY record_key').all()});
  rows.push({type:'query',fn:'pricing_snapshot',expected:priced.prepare('SELECT * FROM pricing_snapshot ORDER BY version').all().map(row=>({...row,created_at:'<volatile>'}))});
  priced.close();
  writeFileSync(join(output, 'ledger.jsonl'), rows.map(row => JSON.stringify(row)).join('\n') + '\n');

  const migrations = [];
  for (let version = 1; version <= 4; version += 1) {
    const input = readFileSync(`test/fixtures/parity/v${version}.sql`, 'utf8');
    const path = join(root, `v${version}.db`);
    const initial = new DatabaseSync(path);
    initial.exec(input);
    initial.close();
    const migrated = openLedger(path);
    const schema = migrated.prepare("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name").all();
    const tables = {};
    for (const name of ['usage_records', 'ingest_runs', 'legacy_records', 'pricing_snapshot']) tables[name] = migrated.prepare(`SELECT * FROM ${name} ORDER BY 1`).all().map(row => {
      for (const field of ['ingested_at', 'imported_at', 'created_at']) if (field in row) row[field] = '<volatile>';
      return row;
    });
    migrations.push({ type: 'query', fn: 'migration', version, schema, tables });
    migrated.close();
  }
  writeFileSync(join(output, 'migrations.jsonl'), migrations.map(row => JSON.stringify(row)).join('\n') + '\n');
  console.log(`ledger: ${rows.length} rows; migrations: ${migrations.length}`);
}
