import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseDsh } from '../../src/core/adapters/dsh.js';

test('parseDsh should extract valid token usage from DSH session JSON', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-dsh-'));
  const filePath = join(tmp, 'session-test-uuid-1234.json');

  const mockDshSession = {
    version: 7,
    record: {
      identity: {
        createdAt: 1792138498430,
        cwd: 'D:/work/test-repo'
      },
      rows: {
        title: { val: 'test-session' },
        tokenUsage: {
          val: {
            totals: {
              uncachedInputTokens: 10000,
              outputTokens: 5000,
              cacheReadTokens: 50000,
              cacheWriteTokens: 0
            }
          }
        },
        modelSelection: {
          val: {
            lastUsed: {
              provider: 'deepseek-official',
              model: 'deepseek-flash'
            }
          }
        }
      }
    }
  };

  writeFileSync(filePath, JSON.stringify(mockDshSession, null, 2), 'utf8');

  const records = [];
  for await (const r of parseDsh(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 1);
  assert.equal(records[0].source, 'dsh');
  assert.equal(records[0].session_id, 'test-uuid-1234');
  assert.equal(records[0].model, 'deepseek-flash');
  assert.equal(records[0].input_tokens, 10000);
  assert.equal(records[0].output_tokens, 5000);
  assert.equal(records[0].cache_read_tokens, 50000);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseDsh should gracefully handle empty or zero token session', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-dsh-'));
  const filePath = join(tmp, 'session-empty.json');

  writeFileSync(filePath, JSON.stringify({ version: 7, record: { rows: {} } }), 'utf8');

  const records = [];
  for await (const r of parseDsh(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 0);
  rmSync(tmp, { recursive: true, force: true });
});

test('parseDsh should keep a legal zero instead of falling back to inputTokens', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-dsh-'));
  try {
    const filePath = join(tmp, 'session-zero-uncached.json');

    const mockDshSession = {
      version: 7,
      record: {
        identity: {
          createdAt: 1792138498430,
          cwd: 'D:/work/test-repo'
        },
        rows: {
          tokenUsage: {
            val: {
              totals: {
                uncachedInputTokens: 0,
                inputTokens: 5000,
                outputTokens: 10,
                cacheReadTokens: 5000,
                cacheWriteTokens: 0
              }
            }
          },
          modelSelection: {
            val: {
              lastUsed: {
                provider: 'deepseek-official',
                model: 'deepseek-flash'
              }
            }
          }
        }
      }
    };

    writeFileSync(filePath, JSON.stringify(mockDshSession, null, 2), 'utf8');

    const records = [];
    for await (const r of parseDsh(filePath)) {
      records.push(r);
    }

    assert.equal(records.length, 1);
    // uncachedInputTokens 是合法的 0，不能回落到 inputTokens 的 5000
    assert.equal(records[0].input_tokens, 0);
    assert.equal(records[0].output_tokens, 10);
    assert.equal(records[0].cache_read_tokens, 5000);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('parseDsh should report null model and null missing token fields', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-dsh-'));
  try {
    const filePath = join(tmp, 'session-no-model.json');

    const mockDshSession = {
      version: 7,
      record: {
        identity: {
          createdAt: 1792138498430
        },
        rows: {
          tokenUsage: {
            val: {
              totals: {
                uncachedInputTokens: 10,
                outputTokens: 5
              }
            }
          }
        }
      }
    };

    writeFileSync(filePath, JSON.stringify(mockDshSession, null, 2), 'utf8');

    const records = [];
    for await (const r of parseDsh(filePath)) {
      records.push(r);
    }

    assert.equal(records.length, 1);
    assert.equal(records[0].model, null);
    // 缺字段是未知，不是 0
    assert.equal(records[0].cache_read_tokens, null);
    assert.equal(records[0].cache_write_tokens, null);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('parseDsh should take project_key from identity.cwd or workingDirectory', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-dsh-'));
  try {
    const make = (name, record) => {
      const filePath = join(tmp, name);
      writeFileSync(filePath, JSON.stringify({
        version: 7,
        record: {
          identity: { createdAt: 1792138498430, ...(record.identity || {}) },
          rows: {
            tokenUsage: {
              val: {
                totals: {
                  uncachedInputTokens: 10,
                  outputTokens: 5,
                  cacheReadTokens: 0,
                  cacheWriteTokens: 0
                }
              }
            },
            ...(record.rows || {})
          }
        }
      }, null, 2), 'utf8');
      return filePath;
    };
    const first = async (filePath) => {
      for await (const r of parseDsh(filePath)) return r;
      return null;
    };

    const withCwd = await first(make('session-project-cwd.json', { identity: { cwd: '/home/u/app' } }));
    assert.equal(withCwd.project_key, '/home/u/app');

    const withoutCwd = await first(make('session-project-none.json', {}));
    assert.equal(withoutCwd.project_key, null);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
