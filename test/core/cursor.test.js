import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { parseCursor } from '../../src/core/adapters/cursor.js';

test('parseCursor should parse official Cursor usage CSV export', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-cursor-'));
  const filePath = join(tmp, 'cursor-usage-october.csv');

  const csvContent = [
    'Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost',
    '2026-10-15T08:00:00.000Z,claude-3-5-sonnet,12000,10000,5000,2000,17000,$0.054',
    '2026-10-15T09:00:00.000Z,gpt-4o,8000,8000,2000,1500,11500,$0.035'
  ].join('\n');

  writeFileSync(filePath, csvContent, 'utf8');

  const records = [];
  for await (const r of parseCursor(filePath)) {
    records.push(r);
  }

  assert.equal(records.length, 2);

  // 第一行：有缓存写入
  assert.equal(records[0].source, 'cursor');
  assert.equal(records[0].model, 'claude-3-5-sonnet');
  assert.equal(records[0].input_tokens, 10000);
  assert.equal(records[0].output_tokens, 2000);
  assert.equal(records[0].cache_read_tokens, 5000);
  assert.equal(records[0].cache_creation_tokens, 2000); // 12000 - 10000

  // 第二行
  assert.equal(records[1].model, 'gpt-4o');
  assert.equal(records[1].input_tokens, 8000);
  assert.equal(records[1].output_tokens, 1500);
  assert.equal(records[1].cache_read_tokens, 2000);
  assert.equal(records[1].cache_creation_tokens, 0);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseCursor should parse state.vscdb composerData and chatdata', async () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tl-test-cursor-db-'));
  const dbPath = join(tmp, 'state.vscdb');

  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);
  `);

  const mockComposer = {
    'composer-1': {
      id: 'composer-1',
      model: 'claude-3-5-sonnet',
      createdAt: 1784357000000,
      conversation: [
        { type: 1, role: 'user', tokenCount: 4000 },
        { type: 2, role: 'assistant', tokenCount: 1500 }
      ]
    }
  };

  const mockChat = {
    tabs: [
      {
        tabId: 'tab-101',
        model: 'gpt-4o',
        createdAt: 1784358000000,
        chatMessages: [
          { role: 'user', tokenCount: 3000 },
          { role: 'assistant', tokenCount: 800 }
        ]
      }
    ]
  };

  const insert = db.prepare('INSERT INTO ItemTable VALUES (?, ?)');
  insert.run('composerData', JSON.stringify(mockComposer));
  insert.run('workbench.panel.aichat.view.aichat.chatdata', JSON.stringify(mockChat));
  db.close();

  const records = [];
  for await (const r of parseCursor(dbPath)) {
    records.push(r);
  }

  assert.equal(records.length, 2);

  // Composer
  assert.equal(records[0].source, 'cursor');
  assert.equal(records[0].session_id, 'composer-1');
  assert.equal(records[0].model, 'claude-3-5-sonnet');
  assert.equal(records[0].input_tokens, 4000);
  assert.equal(records[0].output_tokens, 1500);

  // Chat
  assert.equal(records[1].source, 'cursor');
  assert.equal(records[1].session_id, 'tab-101');
  assert.equal(records[1].model, 'gpt-4o');
  assert.equal(records[1].input_tokens, 3000);
  assert.equal(records[1].output_tokens, 800);

  rmSync(tmp, { recursive: true, force: true });
});

test('parseCursor should ignore empty CSV or non-existent db gracefully', async () => {
  const records = [];
  for await (const r of parseCursor('non-existent.vscdb')) {
    records.push(r);
  }
  assert.equal(records.length, 0);
});
