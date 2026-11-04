import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { adapters } from '../../src/core/adapters/index.js';
import { newNotes } from '../../src/core/adapters/_num.js';

async function collect(parser, file, notes) {
  const records = [];
  for await (const record of parser(file, notes)) records.push(record);
  return records;
}

for (const source of ['codebuddy', 'kimi', 'openclaw']) {
  test(`${source}：缺失缓存为 null，空 usage 计数，坏行可见`, async () => {
    const dir = mkdtempSync(join(tmpdir(), `tl-${source}-notes-`));
    try {
      const file = join(dir, 'session.jsonl');
      writeFileSync(file, [
        JSON.stringify({ id: 'one', timestamp: '2026-10-20T01:00:00Z', usage: source === 'codebuddy'
          ? { input_tokens: 3, output_tokens: 2 } : { input: 3, output: 2 } }),
        '{bad',
        JSON.stringify({ id: 'zero', timestamp: '2026-10-20T01:01:00Z', usage: {} })
      ].join('\n') + '\n');
      const notes = newNotes();
      const records = await collect(adapters[source], file, notes);
      assert.equal(records.length, 1);
      assert.equal(records[0].cache_read_tokens, null);
      assert.equal(records[0].cache_write_tokens, null);
      assert.equal(notes.bad_lines, 1);
      assert.equal(notes.zero_usage, 1);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
}

test('continue：缺字段保持 null，合法 0 不回退到嵌套值', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-continue-notes-'));
  try {
    const file = join(dir, 'session.json');
    writeFileSync(file, JSON.stringify({
      sessionId: 'c', dateCreated: '2026-10-20T01:00:00Z',
      history: [{ id: 'r1', role: 'assistant', promptTokens: 0, usage: { prompt_tokens: 8, completion_tokens: 2 } }]
    }));
    const [record] = await collect(adapters.continue, file, newNotes());
    assert.equal(record.input_tokens, 0);
    assert.equal(record.output_tokens, 2);
    assert.equal(record.cache_read_tokens, null);
    assert.equal(record.cache_write_tokens, null);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('opencode：行内坏 JSON 与零用量计数，缺失缓存保持 null', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'tl-opencode-notes-'));
  try {
    const file = join(dir, 'opencode.db');
    const db = new DatabaseSync(file);
    db.exec('CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)');
    const insert = db.prepare('INSERT INTO message VALUES (?, ?, ?, ?, ?)');
    insert.run('bad', 's', 1792811311000, 1792811311000, '{bad');
    insert.run('zero', 's', 1792811311000, 1792811311000, JSON.stringify({ tokens: {} }));
    insert.run('ok', 's', 1792811311000, 1792811311000, JSON.stringify({ tokens: { input: 3, output: 2 } }));
    db.close();
    const notes = newNotes();
    const records = await collect(adapters.opencode, file, notes);
    assert.equal(records.length, 1);
    assert.equal(records[0].cache_read_tokens, null);
    assert.equal(records[0].cache_write_tokens, null);
    assert.equal(notes.bad_lines, 1);
    assert.equal(notes.zero_usage, 1);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

for (const source of ['copilot', 'cursor', 'goose', 'hermes', 'mimo', 'minimax', 'opencode', 'zed']) {
  test(`${source}：损坏数据库抛出读取错误，不静默当成空数据`, async () => {
    const dir = mkdtempSync(join(tmpdir(), `tl-${source}-bad-db-`));
    try {
      const file = join(dir, 'bad.db');
      writeFileSync(file, 'not a sqlite database');
      await assert.rejects(collect(adapters[source], file, newNotes()));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
}
