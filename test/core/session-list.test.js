import { test } from 'node:test';
import assert from 'node:assert/strict';

import { Ledger } from '../../src/core/db/ledger.js';
import { costOf } from '../../src/core/pricing/engine.js';

/**
 * @param {Object[]} records
 * @returns {Ledger}
 */
function seed(records) {
  const ledger = new Ledger(':memory:');
  ledger.write.ingestBatch(records, { priceOf: costOf });
  return ledger;
}

/** @param {string} key @param {string} session @param {string|null} project */
function row(key, session, project, observedAt = '2026-10-19T10:00:00.000Z') {
  return {
    source: 'claude',
    record_key: key,
    session_id: session,
    project_key: project,
    model: 'claude-opus-5-5',
    observed_at: observedAt,
    kind: 'event',
    input_tokens: 10,
    output_tokens: 10,
    cache_read_tokens: 0,
    cache_write_tokens: 0
  };
}

test('会话列表返回项目路径', () => {
  const ledger = seed([
    row('a1', 's1', 'D:\\work\\alpha'),
    row('a2', 's1', 'D:\\work\\alpha', '2026-10-19T11:00:00.000Z')
  ]);

  const { items } = ledger.read.sessions();
  assert.equal(items.length, 1);
  assert.equal(items[0].project_key, 'D:\\work\\alpha');
  ledger.close();
});

test('同一会话跨两个项目时返回 null', () => {
  const ledger = seed([
    row('a1', 's1', 'D:\\work\\alpha'),
    row('a2', 's1', 'D:\\work\\beta', '2026-10-19T11:00:00.000Z')
  ]);

  const { items } = ledger.read.sessions();
  assert.equal(items[0].project_key, null, '不替用户挑一个');
  ledger.close();
});

test('日志没有项目信息时仍返回 null', () => {
  const ledger = seed([row('a1', 's1', null)]);
  const { items } = ledger.read.sessions();
  assert.equal(items[0].project_key, null);
  ledger.close();
});

test('多个会话各自带自己的项目，互不串味', () => {
  const ledger = seed([
    row('a1', 's1', 'D:\\work\\alpha'),
    row('b1', 's2', 'D:\\work\\beta', '2026-10-19T12:00:00.000Z'),
    row('c1', 's3', null, '2026-10-19T13:00:00.000Z')
  ]);

  const byId = new Map(ledger.read.sessions().items.map((item) => [item.session_id, item]));
  assert.equal(byId.get('s1').project_key, 'D:\\work\\alpha');
  assert.equal(byId.get('s2').project_key, 'D:\\work\\beta');
  assert.equal(byId.get('s3').project_key, null);
  ledger.close();
});
