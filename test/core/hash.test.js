import { test } from 'node:test';
import assert from 'node:assert/strict';
import { computeContentHash } from '../../src/core/hash.js';

test('computeContentHash should produce deterministic hash', () => {
  const r1 = {
    source: 'claude',
    session_id: 'sess-123',
    timestamp: '2026-10-06T12:00:00.000Z',
    model: 'claude-3-5-sonnet',
    input_tokens: 100,
    output_tokens: 50,
    cache_read_tokens: 10,
    cache_creation_tokens: 0
  };

  const r2 = {
    source: 'claude',
    session_id: 'sess-123',
    timestamp: '2026-10-06T12:00:00.000Z',
    model: 'claude-3-5-sonnet',
    input_tokens: 100,
    output_tokens: 50,
    cache_read_tokens: 10,
    cache_creation_tokens: 0
  };

  const hash1 = computeContentHash(r1);
  const hash2 = computeContentHash(r2);

  assert.equal(typeof hash1, 'string');
  assert.equal(hash1.length, 32);
  assert.equal(hash1, hash2);
});

test('computeContentHash should differentiate different tokens', () => {
  const r1 = { source: 'codex', timestamp: '2026-10-06T12:00:00.000Z', input_tokens: 100 };
  const r2 = { source: 'codex', timestamp: '2026-10-06T12:00:00.000Z', input_tokens: 101 };

  assert.notEqual(computeContentHash(r1), computeContentHash(r2));
});
