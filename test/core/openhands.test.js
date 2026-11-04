import { test } from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join, relative } from 'node:path';
import { adapters, PARSER_REV } from '../../src/core/adapters/index.js';
import { normalizeTimestamp } from '../../src/core/adapters/_lines.js';
import { newNotes } from '../../src/core/adapters/_num.js';
import { discoverAll } from '../../src/core/discovery.js';
import { runIngestion } from '../../src/core/ingest.js';
import { Ledger } from '../../src/core/db/ledger.js';
import { costOf } from '../../src/core/pricing/engine.js';

const session = '11111111-2222-4333-8444-555555555555';
const time = '2026-10-26T12:00:00Z';
// SDK v1.28.1: Metrics.add_token_usage and ConversationStats serialization.
const usage = (fields = {}) => ({
  model: 'claude-opus-5-5', response_id: 'response-1', prompt_tokens: 100,
  completion_tokens: 20, cache_read_tokens: 30, cache_write_tokens: 10,
  reasoning_tokens: 5, context_window: 200000, per_turn_token: 120, ...fields
});
const state = (usages = [usage()]) => ({
  id: session, agent: { kind: 'Agent', llm: { model: 'current-model' } },
  stats: { usage_to_metrics: { agent: {
    model_name: 'current-model', token_usages: usages,
    accumulated_token_usage: usage({ prompt_tokens: 900000, completion_tokens: 800000 })
  } } }
});

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'tl-openhands-'));
  const directory = join(root, 'conversations', session.replaceAll('-', ''));
  const events = join(directory, 'events');
  const file = join(directory, 'base_state.json');
  mkdirSync(events, { recursive: true });
  const ledger = new Ledger(':memory:');
  t.after(() => { try { ledger.close(); } finally { rmSync(root, { recursive: true, force: true }); } });
  const put = (data = state()) => writeFileSync(file, typeof data === 'string' ? data : JSON.stringify(data));
  const event = (response = 'response-1', timestamp = time, index = 0, fields = {}) => {
    const id = `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`;
    const path = join(events, `event-${String(index).padStart(5, '0')}-${id}.json`);
    writeFileSync(path, JSON.stringify({ kind: 'MessageEvent', id, timestamp, source: 'agent', llm_response_id: response, ...fields }));
    return path;
  };
  const parse = async (path = file, notes) => {
    assert.equal(typeof adapters.openhands, 'function', 'openhands parser must be registered');
    return Array.fromAsync(adapters.openhands(path, notes));
  };
  const ingest = async (path = file, notes) => ledger.write.ingestBatch(await parse(path, notes), {
    priceOf: costOf, sourceFile: path, parserRev: PARSER_REV.openhands
  });
  return { root, directory, events, file, ledger, put, event, parse, ingest };
}

function environment(t, changes) {
  const saved = Object.fromEntries(Object.keys(changes).map(key => [key, process.env[key]]));
  t.after(() => {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  });
  for (const [key, value] of Object.entries(changes)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
}

function childSession(directory, id, usageId = 'agent', usages = [usage()]) {
  mkdirSync(join(directory, 'events'), { recursive: true });
  const data = state(usages);
  data.id = id;
  data.stats.usage_to_metrics = { [usageId]: data.stats.usage_to_metrics.agent };
  const file = join(directory, 'base_state.json');
  writeFileSync(file, JSON.stringify(data));
  usages.forEach((row, index) => {
    const eventId = `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`;
    writeFileSync(join(directory, 'events', `event-${String(index).padStart(5, '0')}-${eventId}.json`), JSON.stringify({
      kind: 'MessageEvent', id: eventId, source: 'agent', llm_response_id: row.response_id,
      timestamp: '2026-10-26T14:00:00Z'
    }));
  });
  return file;
}

test('openhands normal: exclusive tokens, usage model and response event time', async (t) => {
  const f = fixture(t); f.put(); f.event();
  assert.equal(PARSER_REV.openhands, 1);
  assert.deepEqual(await f.parse(), [{
    record_key: `openhands|${session}|agent|response-1`, source: 'openhands',
    session_id: session, project_key: null, model: 'claude-opus-5-5',
    observed_at: '2026-10-26T12:00:00.000Z', kind: 'event',
    input_tokens: 60, output_tokens: 20, cache_read_tokens: 30, cache_write_tokens: 10
  }]);
});

test('openhands repeat collection: row count, tokens and cost stay unchanged', async (t) => {
  const f = fixture(t); f.put(); f.event(); await f.ingest();
  const before = f.ledger.read.totals(); assert.ok(before.cost_micros > 0);
  const again = await f.ingest();
  assert.equal(again.inserted, 0); assert.equal(again.unchanged, 1);
  assert.deepEqual(f.ledger.read.totals(), before);
});

test('openhands growth: overwrite the same response and append a new response', async (t) => {
  const f = fixture(t); f.put(); f.event(); await f.ingest();
  f.put(state([usage({ prompt_tokens: 200 })]));
  assert.equal((await f.ingest()).updated, 1);
  assert.equal(f.ledger.read.totals().record_count, 1);
  assert.equal(f.ledger.read.totals().input_tokens, 160);
  f.put(state([usage({ prompt_tokens: 200 }), usage({ response_id: 'response-2' })]));
  f.event('response-2', time, 1);
  assert.equal((await f.ingest()).inserted, 1);
  assert.equal(f.ledger.read.totals().record_count, 2);
});

test('openhands snapshot rewrite: cumulative changes never add to event usage', async (t) => {
  const f = fixture(t); const data = state(); f.put(data); f.event(); await f.ingest();
  const before = f.ledger.read.totals();
  data.stats.usage_to_metrics.agent.accumulated_token_usage.prompt_tokens += 999999;
  f.put(data); assert.equal((await f.ingest()).unchanged, 1);
  assert.deepEqual(f.ledger.read.totals(), before);
  delete data.stats.usage_to_metrics.agent.token_usages; f.put(data);
  assert.deepEqual(await f.parse(), [], 'no fallback to cumulative usage');
});

test('openhands rotation and truncation: stable IDs keep one copy and vanished history', async (t) => {
  const f = fixture(t); f.put(state([usage(), usage({ response_id: 'response-2' })]));
  f.event(); f.event('response-2', time, 1); await f.ingest();
  const before = f.ledger.read.totals();
  const copy = join(f.directory, 'snapshot-copy.json'); copyFileSync(f.file, copy);
  assert.equal((await f.ingest(copy)).inserted, 0);
  assert.deepEqual(f.ledger.read.totals(), before);
  await f.ingest(); f.put();
  assert.ok((await f.ingest()).anomalies.some(text => text.includes('vanished')));
  assert.deepEqual(f.ledger.read.totals(), before);
});

test('openhands bad data: malformed events and fields stay visible, missing stays NULL', async (t) => {
  const f = fixture(t);
  f.put(state([usage({ prompt_tokens: undefined, completion_tokens: '7', cache_read_tokens: -1, cache_write_tokens: 'bad' }), null, usage({ response_id: 'zero', prompt_tokens: 0, completion_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0 })]));
  f.event(); f.event('zero', time, 1);
  writeFileSync(f.event('bad', time, 2), '{');
  const notes = newNotes(); const [row] = await f.parse(f.file, notes);
  assert.equal(row.input_tokens, null); assert.equal(row.output_tokens, 7);
  assert.equal(row.cache_read_tokens, null); assert.equal(row.cache_write_tokens, null);
  assert.deepEqual(notes, { bad_lines: 1, bad_fields: 3, bad_times: 0, zero_usage: 1 });
  f.put('{'); await assert.rejects(f.parse(), SyntaxError);
});

test('openhands synthetic client totals: zero delta across agent and condenser', async (t) => {
  const f = fixture(t); const data = state();
  data.stats.usage_to_metrics.condenser = { model_name: 'other', token_usages: [usage({ prompt_tokens: 50, completion_tokens: 8, cache_read_tokens: 4, cache_write_tokens: 1, response_id: 'response-c' })], accumulated_token_usage: usage({ prompt_tokens: 50 }) };
  f.put(data); f.event(); f.event('response-c', time, 1, { kind: 'Condensation', source: 'environment' });
  await f.ingest(); const total = f.ledger.read.totals();
  // Independently specified SDK totals: inclusive prompt=150, completion=28, cache=34+11.
  assert.deepEqual([total.input_tokens, total.output_tokens, total.cache_read_tokens, total.cache_write_tokens], [105, 28, 34, 11]);
  assert.equal(total.gross_tokens - 178, 0); assert.equal(total.record_count, 2);
  assert.ok((await f.parse()).every(row => row.kind === 'event'));
});

test('openhands missing and placeholder models: NULL without metrics or current-model fallback', async (t) => {
  const f = fixture(t); f.event();
  for (const model of [undefined, '', '   ', 'default', ' DEFAULT ']) {
    f.put(state([usage({ model })])); assert.equal((await f.parse())[0].model, null);
  }
  await f.ingest(); assert.equal(f.ledger.read.totals().unpriced_records, 1);
});

test('openhands accounting: deduct both caches, keep completion including reasoning once', async (t) => {
  const f = fixture(t); f.put(state([usage({ reasoning_tokens: 10000 })])); f.event();
  const [row] = await f.parse(); assert.equal(row.input_tokens, 60); assert.equal(row.output_tokens, 20);
  f.put(state([usage({ prompt_tokens: 5 })])); const notes = newNotes();
  assert.equal((await f.parse(f.file, notes))[0].input_tokens, null);
  assert.equal(notes.bad_fields, 1, 'negative exclusive input must not become zero');
  f.put(state([usage({ cache_write_tokens: undefined })]));
  const [partial] = await f.parse(); assert.equal(partial.cache_write_tokens, null);
  assert.equal(partial.input_tokens, null, 'unknown cache prevents a known exclusive input');
});

test('openhands event matching: earliest valid timestamp across action and message events', async (t) => {
  const f = fixture(t); f.put(); f.event('response-1', '2026-10-26T15:00:00Z');
  f.event('response-1', '2026-10-26T08:00:00-03:00', 1, { kind: 'ActionEvent' });
  f.event('response-1', 'invalid', 2);
  writeFileSync(join(f.events, 'unrelated.json'), JSON.stringify({ llm_response_id: 'response-1', timestamp: '2000-01-01T00:00:00Z' }));
  assert.equal((await f.parse())[0].observed_at, '2026-10-26T11:00:00.000Z');
});

test('openhands timezone: naive SDK event timestamps use collector local time', async (t) => {
  environment(t, { TZ: 'America/New_York' });
  const f = fixture(t); f.put(); f.event('response-1', '2026-10-26T12:00:00.123456');
  assert.equal(normalizeTimestamp('2026-10-26T12:00:00.123456'), '2026-10-26T16:00:00.123Z');
  assert.equal((await f.parse())[0].observed_at, '2026-10-26T16:00:00.123Z');
});

test('openhands unmatched and empty IDs: skip and count without losing valid entries', async (t) => {
  const f = fixture(t); const data = state([usage(), usage({ response_id: '' }), usage({ response_id: 'missing' })]);
  data.stats.usage_to_metrics['task:child'] = { token_usages: [usage({ response_id: 'child-response' })] };
  f.put(data); f.event(); const notes = newNotes();
  assert.equal((await f.parse(f.file, notes)).length, 1); assert.equal(notes.bad_times, 2);
  assert.equal(notes.subagent_copies, 1);
});

test('openhands task and delegate copies: ingest child records once with separate copy notes', async (t) => {
  const f = fixture(t); const data = state(); f.event();
  const rows = [usage({ response_id: 'child-one' }), usage({ response_id: 'child-two' })];
  data.stats.usage_to_metrics['task:one'] = { token_usages: rows };
  data.stats.usage_to_metrics['delegate:one'] = { token_usages: rows };
  f.put(data);
  const childId = '22222222-2222-4333-8444-555555555555';
  const file = childSession(join(f.directory, 'subagents', childId.replaceAll('-', '')), childId, 'agent', rows);
  environment(t, { OPENHANDS_CONVERSATIONS_DIR: join(f.root, 'conversations') });
  const dataDir = join(f.root, 'ledger');
  const result = await runIngestion({ dataDir });
  assert.equal(result.inserted, 3, 'one parent call and two child calls');
  assert.equal(result.counts.subagent_copies, 4); assert.equal(result.counts.bad_times, 0);
  assert.equal(result.anomalies.length, 0);
  for (const path of discoverAll().openhands) await f.ingest(path);
  assert.equal(f.ledger.read.totals().record_count, 3);
  assert.equal(f.ledger.read.totals().gross_tokens, 360);
  assert.deepEqual(f.ledger.read.sourceFiles().map(row => [row.source_file, row.records]).sort(), [[f.file, 1], [file, 2]].sort());
  const children = await f.parse(file);
  assert.ok(children.every(row => row.session_id === childId && row.observed_at === '2026-10-26T14:00:00.000Z'));
  const repeat = await runIngestion({ dataDir });
  assert.equal(repeat.inserted, 0); assert.equal(repeat.unchanged, 3);
  assert.equal(repeat.counts.subagent_copies, 4); assert.equal(repeat.counts.bad_times, 0);
});

test('openhands descendants: discover and ingest a subagent of a subagent', async (t) => {
  const f = fixture(t); f.put(); f.event();
  const childId = '22222222-2222-4333-8444-555555555555';
  const grandId = '33333333-2222-4333-8444-555555555555';
  const childDir = join(f.directory, 'subagents', childId.replaceAll('-', ''));
  childSession(childDir, childId);
  childSession(join(childDir, 'subagents', grandId.replaceAll('-', '')), grandId);
  environment(t, { OPENHANDS_CONVERSATIONS_DIR: join(f.root, 'conversations') });
  assert.equal(discoverAll().openhands.length, 3);
  const result = await runIngestion({ dataDir: join(f.root, 'ledger') });
  assert.equal(result.inserted, 3); assert.equal(result.counts.bad_times, 0);
  const rows = (await Promise.all(discoverAll().openhands.map(path => f.parse(path)))).flat();
  assert.deepEqual(new Set(rows.map(row => row.session_id)), new Set([session, childId, grandId]));
});

test('openhands agent hook: keep its own usage and count only the unmatched parent copy', async (t) => {
  const f = fixture(t); const data = state(); f.event();
  const usageId = 'agent-hook:review'; const rows = [usage({ response_id: 'hook-response' })];
  data.stats.usage_to_metrics[usageId] = { token_usages: rows }; f.put(data);
  const hookId = '44444444-2222-4333-8444-555555555555';
  const hookFile = childSession(join(f.root, 'conversations', hookId.replaceAll('-', '')), hookId, usageId, rows);
  environment(t, { OPENHANDS_CONVERSATIONS_DIR: join(f.root, 'conversations') });
  const result = await runIngestion({ dataDir: join(f.root, 'ledger') });
  assert.equal(result.inserted, 2); assert.equal(result.counts.subagent_copies, 1); assert.equal(result.counts.bad_times, 0);
  const [hook] = await f.parse(hookFile);
  assert.equal(hook.session_id, hookId); assert.equal(hook.observed_at, '2026-10-26T14:00:00.000Z');
  assert.equal(hook.input_tokens, 60);
});

test('openhands copy classification: prefixes never discard matched usage or bless unrelated misses', async (t) => {
  const f = fixture(t); const data = state();
  data.stats.usage_to_metrics = Object.fromEntries(['task:one', 'delegate:one', 'agent-hook:one', 'future-copy:one'].map(id => [id, {
    token_usages: [usage({ response_id: 'matched' }), usage({ response_id: 'missing' }), usage({ response_id: '' })]
  }]));
  f.put(data); f.event('matched'); const notes = newNotes();
  assert.equal((await f.parse(f.file, notes)).length, 4, 'matching the local event is the only admission rule');
  assert.equal(notes.subagent_copies, 6); assert.equal(notes.bad_times, 2);
});

test('openhands descendant discovery: exact subagents paths and base_state filenames only', async (t) => {
  const f = fixture(t); f.put(); f.event();
  const childId = '22222222-2222-4333-8444-555555555555';
  const childDir = join(f.directory, 'subagents', childId.replaceAll('-', ''));
  const file = childSession(childDir, childId);
  writeFileSync(join(childDir, 'other.json'), '{}');
  writeFileSync(join(childDir, 'base_state.json.bak'), '{}');
  childSession(join(f.directory, 'archive', 'ignored'), 'archive');
  childSession(join(childDir, 'events', 'ignored'), 'events');
  childSession(join(f.directory, 'subagents', 'intermediate', 'archive', 'ignored'), 'nested-archive');
  // A missing intermediate snapshot must not hide surviving descendant logs.
  const orphan = childSession(join(f.directory, 'subagents', 'intermediate', 'subagents', 'leaf'), 'leaf');
  environment(t, { OPENHANDS_CONVERSATIONS_DIR: join(f.root, 'conversations') });
  assert.deepEqual(new Set(discoverAll().openhands), new Set([f.file, file, orphan]));
});

test('openhands duplicate response IDs: numbered per usageId and stable on recollection', async (t) => {
  const f = fixture(t); const data = state([usage(), usage({ prompt_tokens: 101 }), usage({ response_id: 'response-1#2' })]);
  data.stats.usage_to_metrics.condenser = { token_usages: [usage()] };
  f.put(data); f.event(); f.event('response-1#2', time, 1); const notes = newNotes();
  const rows = await f.parse(f.file, notes);
  assert.deepEqual(rows.map(row => row.record_key), [
    `openhands|${session}|agent|response-1`, `openhands|${session}|agent|response-1#2`,
    `openhands|${session}|agent|response-1%232`, `openhands|${session}|condenser|response-1`
  ]);
  assert.equal(notes.duplicate_response_ids, 1);
  await f.ingest(); const before = f.ledger.read.totals();
  assert.equal((await f.ingest()).inserted, 0); assert.deepEqual(f.ledger.read.totals(), before);
});

test('openhands event-only change: ingestion reparses an unchanged base_state file', async (t) => {
  const f = fixture(t); f.put(); const before = statSync(f.file).mtimeMs;
  environment(t, { OPENHANDS_CONVERSATIONS_DIR: join(f.root, 'conversations') });
  const dataDir = join(f.root, 'ledger');
  const first = await runIngestion({ dataDir }); assert.equal(first.inserted, 0); assert.equal(first.counts.bad_times, 1);
  f.event(); assert.equal(statSync(f.file).mtimeMs, before);
  const second = await runIngestion({ dataDir }); assert.equal(second.inserted, 1);
  const stamp = new Date('2026-01-01T00:00:00Z'); utimesSync(f.file, stamp, stamp);
  const third = await runIngestion({ dataDir }); assert.equal(third.inserted, 0); assert.equal(third.unchanged, 1);
});

test('openhands discovery: exact filename, default home and literal override semantics', async (t) => {
  const f = fixture(t); f.put(); f.event();
  environment(t, { HOME: f.root, USERPROFILE: f.root, OPENHANDS_PERSISTENCE_DIR: undefined, OPENHANDS_CONVERSATIONS_DIR: undefined });
  assert.equal(homedir(), f.root);
  const make = base => {
    const target = join(base, 'one', 'base_state.json'); mkdirSync(join(base, 'one'), { recursive: true });
    copyFileSync(f.file, target); writeFileSync(join(base, 'one', 'other.json'), '{}'); return target;
  };
  const normal = make(join(f.root, '.openhands', 'conversations'));
  assert.deepEqual(discoverAll().openhands, [normal]);
  const persistence = join(f.root, 'custom'); process.env.OPENHANDS_PERSISTENCE_DIR = persistence;
  const custom = make(join(persistence, 'conversations')); assert.deepEqual(discoverAll().openhands, [custom]);
  process.env.OPENHANDS_CONVERSATIONS_DIR = join(f.root, 'conversations');
  assert.deepEqual(discoverAll().openhands, [f.file]);
  process.env.OPENHANDS_CONVERSATIONS_DIR = join(f.root, 'missing'); assert.deepEqual(discoverAll().openhands, []);
  process.env.OPENHANDS_CONVERSATIONS_DIR = '~'; assert.deepEqual(discoverAll().openhands, [], 'no shell expansion of overrides');
  // A relative or empty override is relative to the OpenHands process cwd, which is unknown here;
  // discovery must not follow the collector's own cwd.
  const previousCwd = process.cwd();
  try {
    process.chdir(join(f.root, 'conversations'));
    for (const value of ['', '.', relative(process.cwd(), join(f.root, 'conversations'))]) {
      process.env.OPENHANDS_CONVERSATIONS_DIR = value;
      assert.deepEqual(discoverAll().openhands, [], `relative conversations override ${JSON.stringify(value)}`);
    }
    delete process.env.OPENHANDS_CONVERSATIONS_DIR;
    process.chdir(f.root);
    process.env.OPENHANDS_PERSISTENCE_DIR = 'custom';
    assert.deepEqual(discoverAll().openhands, [], 'relative persistence override');
  } finally { process.chdir(previousCwd); }
});

test('openhands read-only and scope: source bytes stay intact, ACP agent is excluded', async (t) => {
  const f = fixture(t); f.put(); const eventFile = f.event();
  const before = readFileSync(f.file); const eventBefore = readFileSync(eventFile);
  await f.parse(); assert.deepEqual(readFileSync(f.file), before); assert.deepEqual(readFileSync(eventFile), eventBefore);
  const data = state(); data.agent.kind = 'ACPAgent'; f.put(data); assert.deepEqual(await f.parse(), []);
  f.put({ stats: data.stats }); const notes = newNotes(); assert.deepEqual(await f.parse(f.file, notes), []); assert.equal(notes.bad_fields, 1);
  assert.deepEqual(await f.parse(join(f.root, 'missing.json')), []);
});
