import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { discoverAll } from '../../src/core/discovery.js';

test('发现结果不随 cwd 变化', () => {
  const home = mkdtempSync(join(tmpdir(), 'tl-discovery-home-'));
  const rootA = mkdtempSync(join(tmpdir(), 'tl-discovery-a-'));
  const rootB = mkdtempSync(join(tmpdir(), 'tl-discovery-b-'));
  const savedCwd = process.cwd();
  const savedHome = process.env.HOME;
  const savedUserProfile = process.env.USERPROFILE;

  try {
    mkdirSync(join(home, '.claude', 'projects', 'p'), { recursive: true });
    writeFileSync(join(home, '.claude', 'projects', 'p', 'a.jsonl'), '{}', 'utf8');

    // 只有第二个 cwd 的父目录下有兄弟目录 sib/.aider.llm.history
    mkdirSync(join(rootB, 'sib'), { recursive: true });
    writeFileSync(join(rootB, 'sib', '.aider.llm.history'), '{}', 'utf8');
    mkdirSync(join(rootB, 'w'), { recursive: true });

    process.env.HOME = home;
    process.env.USERPROFILE = home;

    process.chdir(rootA);
    const fromA = discoverAll();
    process.chdir(join(rootB, 'w'));
    const fromB = discoverAll();

    assert.deepEqual(fromB, fromA, '发现结果不得随 cwd 变化');
    assert.deepEqual(fromA.aider, [], 'aider 只读 ~/.aider.llm.history');
  } finally {
    process.chdir(savedCwd);
    if (savedHome === undefined) delete process.env.HOME;
    else process.env.HOME = savedHome;
    if (savedUserProfile === undefined) delete process.env.USERPROFILE;
    else process.env.USERPROFILE = savedUserProfile;
    for (const dir of [home, rootA, rootB]) rmSync(dir, { recursive: true, force: true });
  }
});

test('主目录取自调用时的 HOME 与 USERPROFILE', () => {
  const home = mkdtempSync(join(tmpdir(), 'tl-discovery-home-'));
  const emptyHome = mkdtempSync(join(tmpdir(), 'tl-discovery-home2-'));
  const savedHome = process.env.HOME;
  const savedUserProfile = process.env.USERPROFILE;

  try {
    mkdirSync(join(home, '.claude', 'projects', 'p'), { recursive: true });
    writeFileSync(join(home, '.claude', 'projects', 'p', 'a.jsonl'), '{}', 'utf8');

    process.env.HOME = home;
    process.env.USERPROFILE = home;
    assert.equal(discoverAll().claude.length, 1, '临时 home 下的 claude 日志应当被发现');

    // 换成另一个空的临时 home：说明 home 是在调用时读取的，不是模块加载时
    process.env.HOME = emptyHome;
    process.env.USERPROFILE = emptyHome;
    assert.deepEqual(discoverAll().claude, []);
  } finally {
    if (savedHome === undefined) delete process.env.HOME;
    else process.env.HOME = savedHome;
    if (savedUserProfile === undefined) delete process.env.USERPROFILE;
    else process.env.USERPROFILE = savedUserProfile;
    for (const dir of [home, emptyHome]) rmSync(dir, { recursive: true, force: true });
  }
});

test('Kimi Code 主 agent 与子 agent 的 wire 日志都能被发现', () => {
  const home = mkdtempSync(join(tmpdir(), 'tl-discovery-kimi-code-'));
  const keys = ['HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'KIMI_SHARE_DIR'];
  const saved = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
  const session = join(home, '.kimi-code', 'sessions', 'wd_demo', 'session_123');
  const mainFile = join(session, 'agents', 'main', 'wire.jsonl');
  const subagentFile = join(session, 'agents', 'agent-0', 'wire.jsonl');

  try {
    for (const file of [mainFile, subagentFile]) {
      mkdirSync(join(file, '..'), { recursive: true });
      writeFileSync(file, '{}\n', 'utf8');
    }
    Object.assign(process.env, {
      HOME: home,
      USERPROFILE: home,
      APPDATA: join(home, 'AppData', 'Roaming'),
      LOCALAPPDATA: join(home, 'AppData', 'Local')
    });
    delete process.env.KIMI_SHARE_DIR;

    assert.deepEqual(discoverAll().kimi.sort(), [mainFile, subagentFile].sort());
  } finally {
    for (const key of keys) {
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
    }
    rmSync(home, { recursive: true, force: true });
  }
});
