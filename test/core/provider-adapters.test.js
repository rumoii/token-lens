import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { DatabaseSync } from 'node:sqlite';
import { adapters, PARSER_REV } from '../../src/core/adapters/index.js';

function directory(t) {
  const dir = mkdtempSync(join(tmpdir(), 'tl-provider-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

async function parse(source, path) {
  const rows = [];
  for await (const row of adapters[source](path)) rows.push(row);
  return rows;
}

test('Pi：读取消息 provider；缺失不从模型名推断；model_change 仅随继承模型带出', async t => {
  const file = join(directory(t), 'pi.jsonl');
  const message = (id, fields) => ({ type: 'message', id, timestamp: '2026-10-26T01:00:00Z',
    message: { role: 'assistant', usage: { input: 10, output: 2 }, ...fields } });
  writeFileSync(file, [
    { type: 'session', id: 's' },
    { type: 'model_change', modelId: 'model-a', provider: 'ollama' },
    message('a', {}),
    message('b', { model: 'model-b', provider: 'xiaomi-token-plan-cn' }),
    message('c', { model: 'ollama/model-c' }),
    { type: 'model_change', modelId: 'model-d' },
    message('d', {}),
    message('e', { model: 'model-e', provider: { name: 'ollama' } })
  ].map(JSON.stringify).join('\n'));
  const rows = await parse('pi', file);
  assert.equal(rows.length, 5);
  assert.deepEqual(rows.map(r => r.provider), ['ollama', 'xiaomi-token-plan-cn', null, null, null]);
  assert.equal(PARSER_REV.pi, 6);
});

test('Codex：只继承 session_meta.model_provider，下一会话缺失时清空', async t => {
  const file = join(directory(t), 'rollout.jsonl');
  const usage = n => ({ type: 'token_usage_record', timestamp: '2026-10-26T01:00:00Z',
    payload: { response_id: String(n), usage: { model: 'ollama/model', input_tokens: 10, output_tokens: 2, cached_input_tokens: 0 } } });
  writeFileSync(file, [
    { type: 'session_meta', payload: { id: 's', model_provider: 'lmstudio' } }, usage(1),
    { type: 'session_meta', payload: { id: 'next' } }, usage(2)
  ].map(JSON.stringify).join('\n'));
  assert.deepEqual((await parse('codex', file)).map(r => r.provider), ['lmstudio', null]);
  assert.equal(PARSER_REV.codex, 4);
});

for (const source of ['opencode', 'kilo']) {
  test(`${source}：消息明确的 providerID；缺失不从模型名推断`, async t => {
    const file = join(directory(t), `${source}.db`);
    const db = new DatabaseSync(file);
    db.exec(`CREATE TABLE session_message (id TEXT, session_id TEXT, type TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)`);
    const insert = db.prepare("INSERT INTO session_message VALUES (?, 's', 'assistant', 1792976400000, 1792976400000, ?)");
    const tokens = { input: 10, output: 2, cache: { read: 0, write: 0 } };
    insert.run('one', JSON.stringify({ model: { id: 'model', providerID: 'ollama' }, time: { created: 1792976400000 }, tokens }));
    insert.run('two', JSON.stringify({ model: { id: 'ollama/model' }, time: { created: 1792976400000 }, tokens }));
    insert.run('three', JSON.stringify({ model: { id: 'model', providerID: 3 }, time: { created: 1792976400000 }, tokens }));
    db.close();
    assert.deepEqual((await parse(source, file)).map(r => r.provider), ['ollama', null, null]);
    assert.equal(PARSER_REV[source], source === 'kilo' ? 3 : 6);
  });
}

test('OpenCode v1：助手消息顶层 providerID', async t => {
  const file = join(directory(t), 'opencode.db');
  const db = new DatabaseSync(file);
  db.exec('CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)');
  db.prepare("INSERT INTO message VALUES ('m', 's', 1792976400000, 1792976400000, ?)").run(JSON.stringify({
    role: 'assistant', modelID: 'model', providerID: 'lmstudio', tokens: { input: 10, output: 2 }
  }));
  db.close();
  assert.equal((await parse('opencode', file))[0].provider, 'lmstudio');
});

test('Goose：读取 sessions.provider_name；NULL 不从 model_config_json 的模型名猜', async t => {
  const file = join(directory(t), 'goose.db');
  const db = new DatabaseSync(file);
  db.exec(`CREATE TABLE sessions (id TEXT, model_config_json TEXT, provider_name TEXT, created_at TEXT,
    input_tokens INTEGER, output_tokens INTEGER, total_tokens INTEGER)`);
  const insert = db.prepare("INSERT INTO sessions VALUES (?, ?, ?, '2026-10-26T01:00:00Z', 10, 2, 12)");
  insert.run('one', '{"model_name":"model"}', 'ollama');
  insert.run('two', '{"model_name":"ollama/model"}', null);
  db.close();
  assert.deepEqual((await parse('goose', file)).map(r => r.provider), ['ollama', null]);
  assert.equal(PARSER_REV.goose, 5);
});

test('OpenClaw：读取助手消息 provider，缺字段和非法类型保持 NULL', async t => {
  const file = join(directory(t), 'openclaw.jsonl');
  writeFileSync(file, ['ollama', undefined, { name: 'ollama' }].map((provider, i) => JSON.stringify({
    id: String(i), timestamp: '2026-10-26T01:00:00Z',
    message: { role: 'assistant', model: 'ollama/model', provider, usage: { input: 10, output: 2 } }
  })).join('\n'));
  assert.deepEqual((await parse('openclaw', file)).map(r => r.provider), ['ollama', null, null]);
  assert.equal(PARSER_REV.openclaw, 5);
});
