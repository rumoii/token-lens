import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { discoverAll } from '../../src/core/discovery.js';

function isolated(fn, extraKeys = []) {
  const home = mkdtempSync(join(tmpdir(), 'tl-l2-'));
  const keys = [...new Set(['HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA',
    'GEMINI_HOME', 'GOOSE_PATH_ROOT', 'COPILOT_HOME', 'OPENCLAW_HOME', 'OPENCLAW_STATE_DIR',
    'XDG_DATA_HOME', 'OPENCODE_DB', 'KILO_DB', 'OPENHANDS_CONVERSATIONS_DIR', 'OPENHANDS_PERSISTENCE_DIR',
    'MIMOCODE_HOME', 'MIMOCODE_DB', 'MIMOCODE_DISABLE_CHANNEL_DB', 'KIMI_SHARE_DIR',
    'MINIMAX_DATA_DIR', 'MAVIS_DATA_DIR', 'CODEBUDDY_HOME', 'WORKBUDDY_HOME',
    'ZCODE_DATA_BASE_DIR', 'ZCODE_SESSION_DB_PATH', 'ZCODE_SESSION_DB', ...extraKeys])];
  const saved = Object.fromEntries(keys.map(k => [k, process.env[k]]));
  Object.assign(process.env, { HOME: home, USERPROFILE: home, APPDATA: join(home, 'roaming'), LOCALAPPDATA: join(home, 'local') });
  for (const k of keys.slice(4)) delete process.env[k];
  const file = relative => {
    const path = join(home, relative);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, '{}\n');
    return path;
  };
  try { fn({ home, file }); }
  finally {
    for (const k of keys) { if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k]; }
    rmSync(home, { recursive: true, force: true });
  }
}

test('L2 trae: app-data only selects documented globalStorage trae usage files', () => isolated(({ file }) => {
  const base = process.platform === 'win32' ? 'roaming' : process.platform === 'darwin' ? 'Library/Application Support' : '.config';
  const expected = ['trae-usage.json', 'trae-events.jsonl'].map(name => file(`${base}/Trae CN/User/globalStorage/ext/${name}`));
  file(`${base}/Trae CN/User/globalStorage/ext/settings.json`);
  file(`${base}/Trae CN/cache/trae-settings.json`);
  file(`${base}/Trae CN/User/globalStorage/ext/trae-events.jsonl.bak`);
  assert.deepEqual(discoverAll().trae.sort(), expected.sort());
}));

for (const [source, folders] of Object.entries({ kimi: ['kimi', 'Kimi'] })) {
  test(`L2 ${source}: app-data selects sessions/logs, excludes settings/cache JSON`, () => isolated(({ file }) => {
    const expected = [];
    for (const base of ['roaming', 'local']) for (const folder of folders) {
      expected.push(file(`${base}/${folder}/sessions/project/a.json`), file(`${base}/${folder}/logs/project/a.jsonl`));
      file(`${base}/${folder}/settings.json`);
      file(`${base}/${folder}/cache/a.jsonl`);
      file(`${base}/${folder}/sessions/a.json.bak`);
    }
    // Case-insensitive Windows paths may refer to the same file.
    const normalize = paths => [...new Set(paths.map(p => process.platform === 'win32' ? p.toLowerCase() : p))].sort();
    assert.deepEqual(normalize(discoverAll()[source]), normalize(expected));
  }));
}

test('L2 kimi: KIMI_SHARE_DIR replaces ~/.kimi; a relative value is not resolved against cwd', () => isolated(({ home, file }) => {
  const fallback = file('.kimi/sessions/a.jsonl');
  const shared = file('share/sessions/b.jsonl');
  process.env.KIMI_SHARE_DIR = join(home, 'share');
  assert.deepEqual(discoverAll().kimi, [shared]);
  process.env.KIMI_SHARE_DIR = 'relative-share';
  assert.deepEqual(discoverAll().kimi, []);
  process.env.KIMI_SHARE_DIR = '';
  assert.deepEqual(discoverAll().kimi, [fallback]);
}));

test('L2 opencode: XDG data directory on every platform, never LOCALAPPDATA', () => isolated(({ home, file }) => {
  const fallback = file('.local/share/opencode/opencode.db');
  file('local/opencode/opencode.db');
  assert.deepEqual(discoverAll().opencode, [fallback]);
  const xdg = file('xdg/opencode/opencode.db');
  process.env.XDG_DATA_HOME = join(home, 'xdg');
  assert.deepEqual(discoverAll().opencode, [xdg]);
  process.env.XDG_DATA_HOME = 'relative-xdg';
  assert.deepEqual(discoverAll().opencode, [fallback]);
}));

test('L2 opencode: unset override keeps default and legacy paths without scanning channel or backup databases', () => isolated(({ file }) => {
  const expected = [file('.local/share/opencode/opencode.db'), file('.opencode/opencode.db')];
  for (const name of ['opencode-local.db', 'opencode-next.db', 'opencode-backup.db', 'opencode.db.bak']) {
    file(`.local/share/opencode/${name}`);
    file(`.opencode/${name}`);
  }
  assert.deepEqual(discoverAll().opencode, expected);
}));

test('L2 opencode: absolute OPENCODE_DB selects only the explicit file, including a channel database', () => isolated(({ home, file }) => {
  file('.local/share/opencode/opencode.db');
  file('.opencode/opencode.db');
  const selected = file('custom/opencode-local.db');
  process.env.XDG_DATA_HOME = join(home, 'xdg');
  file('xdg/opencode/opencode.db');
  process.env.OPENCODE_DB = selected;
  assert.deepEqual(discoverAll().opencode, [selected]);
}));

test('L2 opencode: relative OPENCODE_DB resolves against the data directory, including parent paths', () => isolated(({ home, file }) => {
  file('.local/share/opencode/opencode.db');
  file('.opencode/opencode.db');
  const cases = [
    ['nested/custom.db', file('.local/share/opencode/nested/custom.db')],
    ['../shared.db', file('.local/share/shared.db')]
  ];
  file('cwd/nested/custom.db');
  file('shared.db');
  const savedCwd = process.cwd();
  try {
    process.chdir(join(home, 'cwd'));
    for (const [value, selected] of cases) {
      process.env.OPENCODE_DB = value;
      assert.deepEqual(discoverAll().opencode, [selected]);
    }
  } finally { process.chdir(savedCwd); }
}));

test('L2 opencode: relative OPENCODE_DB uses the absolute XDG data root after its existing CR/LF cleanup', () => isolated(({ home, file }) => {
  file('.local/share/opencode/opencode.db');
  file('.local/share/opencode/nested/custom.db');
  file('.opencode/opencode.db');
  file('xdg/opencode/opencode.db');
  const selected = file('xdg/opencode/nested/custom.db');
  process.env.OPENCODE_DB = 'nested/custom.db';
  for (const xdg of [join(home, 'xdg'), `${join(home, 'xdg')}\r\n`]) {
    process.env.XDG_DATA_HOME = xdg;
    assert.deepEqual(discoverAll().opencode, [selected]);
  }
}));

test('L2 opencode: relative XDG data root is ignored when resolving OPENCODE_DB', () => isolated(({ file }) => {
  file('.local/share/opencode/opencode.db');
  file('.opencode/opencode.db');
  const selected = file('.local/share/opencode/custom.db');
  process.env.XDG_DATA_HOME = 'relative-xdg';
  process.env.OPENCODE_DB = 'custom.db';
  assert.deepEqual(discoverAll().opencode, [selected]);
}));

for (const [label, value] of [['memory', ':memory:'], ['empty', '']]) {
  test(`L2 opencode: ${label} OPENCODE_DB discovers nothing despite default and legacy databases`, () => isolated(({ file }) => {
    file('.local/share/opencode/opencode.db');
    file('.opencode/opencode.db');
    process.env.OPENCODE_DB = value;
    assert.deepEqual(discoverAll().opencode, []);
  }));
}

test('L2 opencode: missing or non-file OPENCODE_DB never falls back', () => isolated(({ home, file }) => {
  file('.local/share/opencode/opencode.db');
  file('.opencode/opencode.db');
  file('.local/share/opencode/directory/placeholder');
  for (const value of ['missing.db', 'directory', join(home, 'absent.db'), join(home, '.local/share/opencode/directory')]) {
    process.env.OPENCODE_DB = value;
    assert.deepEqual(discoverAll().opencode, []);
  }
}));

test('L2 minimax: discovers runtime SQLite, never legacy JSON or app-data paths', () => isolated(({ home, file }) => {
  const expected = [
    file('.minimax/v2/sqlite/runtime-state.sqlite'),
    file('.minimax-work/v2/sqlite/runtime-state.sqlite'),
    file('.minimax-code/v2/sqlite/runtime-state.sqlite')
  ];
  file('.minimax/sessions/project/old.json');
  file('.minimax/logs/project/old.jsonl');
  file('roaming/minimax/v2/sqlite/runtime-state.sqlite');
  file('local/MiniMax/v2/sqlite/runtime-state.sqlite');
  file('.config/minimax/v2/sqlite/runtime-state.sqlite');
  assert.deepEqual(discoverAll().minimax.sort(), expected.sort());
  process.env.MINIMAX_DATA_DIR = join(home, 'custom');
  const override = file('custom/v2/sqlite/runtime-state.sqlite');
  assert.deepEqual(discoverAll().minimax, [override]);
}));

test('L2 minimax: relative MINIMAX_DATA_DIR never follows the lens cwd or falls back', () => isolated(({ home, file }) => {
  file('.minimax/v2/sqlite/runtime-state.sqlite');
  file('cwd/relative-minimax/v2/sqlite/runtime-state.sqlite');
  file('other/placeholder');
  process.env.MINIMAX_DATA_DIR = 'relative-minimax';
  const savedCwd = process.cwd();
  try {
    for (const directory of ['cwd', 'other']) {
      process.chdir(join(home, directory));
      assert.deepEqual(discoverAll().minimax, [], '相对覆盖既不跟随 cwd，也不回退默认库');
    }
  } finally { process.chdir(savedCwd); }
}));

test('L2 minimax: empty MINIMAX_DATA_DIR uses default paths instead of the lens cwd', () => isolated(({ home, file }) => {
  const expected = [file('.minimax/v2/sqlite/runtime-state.sqlite'), file('.minimax-work/v2/sqlite/runtime-state.sqlite')];
  file('cwd/v2/sqlite/runtime-state.sqlite');
  process.env.MINIMAX_DATA_DIR = '';
  const savedCwd = process.cwd();
  try {
    process.chdir(join(home, 'cwd'));
    assert.deepEqual(discoverAll().minimax.sort(), expected.sort());
  } finally { process.chdir(savedCwd); }
}));

test('L2 pi: specification and discovery include observed one- and three-directory logs', () => isolated(({ file }) => {
  const expected = [file('.pi/agent/sessions/project/a.jsonl'), file('.pi/agent/sessions/project/branch/sub/b.jsonl')];
  file('.pi/agent/sessions/project/a.json');
  assert.deepEqual(discoverAll().pi.sort(), expected.sort());
  const spec = readFileSync(new URL('../../specs/log-schemas.yaml', import.meta.url), 'utf8');
  const pi = spec.split('pi_agent:')[1].split('hermes_agent:')[0];
  assert.ok(pi.includes('file_pattern: "**/*.jsonl"'), 'spec must describe the observed recursive layout');
}));

const mimoEnv = ['XDG_DATA_HOME', 'MIMOCODE_HOME', 'MIMOCODE_DB', 'MIMOCODE_DISABLE_CHANNEL_DB'];

test('L2 mimo: empty MIMOCODE_HOME falls back to the XDG data directory', () => isolated(({ home, file }) => {
  process.env.MIMOCODE_HOME = '';
  const defaultDb = file('.local/share/mimocode/mimocode.db');
  assert.deepEqual(discoverAll().mimo, [defaultDb]);
  process.env.XDG_DATA_HOME = join(home, 'xdg');
  const xdgDb = file('xdg/mimocode/mimocode.db');
  assert.deepEqual(discoverAll().mimo, [xdgDb]);
}, mimoEnv));

test('L2 mimo: relative XDG_DATA_HOME is ignored in favor of ~/.local/share', () => isolated(({ home, file }) => {
  const main = file('.local/share/mimocode/mimocode.db');
  const channel = file('.local/share/mimocode/mimocode-dev.db');
  const custom = file('.local/share/mimocode/custom.db');
  for (const name of ['mimocode.db', 'mimocode-dev.db', 'custom.db']) file(`cwd/relative-xdg/mimocode/${name}`);
  file('other/placeholder');
  process.env.XDG_DATA_HOME = 'relative-xdg';
  const savedCwd = process.cwd();
  try {
    for (const directory of ['cwd', 'other']) {
      process.chdir(join(home, directory));
      delete process.env.MIMOCODE_DB;
      delete process.env.MIMOCODE_DISABLE_CHANNEL_DB;
      assert.deepEqual(discoverAll().mimo, [main], '忽略相对 XDG，默认库不随 cwd 变化');
      process.env.MIMOCODE_DISABLE_CHANNEL_DB = '0';
      assert.deepEqual(discoverAll().mimo.sort(), [main, channel].sort());
      process.env.MIMOCODE_DB = 'custom.db';
      assert.deepEqual(discoverAll().mimo, [custom], '相对库名仍相对有效的数据目录');
    }
  } finally { process.chdir(savedCwd); }
}, mimoEnv));

// Case-insensitive Windows paths may refer to the same file.
const normalize = paths => [...new Set(paths.map(p => process.platform === 'win32' ? p.toLowerCase() : p))].sort();

test('L2 mimo: data-dir mimocode.db and channel dbs plus the MiMo Desktop app-data db', () => isolated(({ file }) => {
  process.env.MIMOCODE_DISABLE_CHANNEL_DB = 'false';
  const expected = [
    file('.local/share/mimocode/mimocode.db'),
    file('.local/share/mimocode/mimocode-dev.db'),
    file('roaming/Xiaomi MiMo/mimocode/mimocode.db')
  ];
  file('.local/share/mimocode/mimocode.db.bak');
  file('.local/share/mimocode/other.db');
  assert.deepEqual(normalize(discoverAll().mimo), normalize(expected));
}, mimoEnv));

test('L2 mimo: MIMOCODE_HOME and MIMOCODE_DB override the data dir and the db', () => isolated(({ home, file }) => {
  process.env.XDG_DATA_HOME = join(home, 'xdg');
  const custom = file('xdg/mimocode/mimocode.db');
  file('xdg/mimocode/other.db');
  assert.deepEqual(normalize(discoverAll().mimo), normalize([custom]));
  process.env.MIMOCODE_HOME = join(home, 'mh');
  const own = file('mh/data/mimocode.db');
  assert.deepEqual(normalize(discoverAll().mimo), normalize([own]), 'MIMOCODE_HOME/data 取代 xdg 数据目录');
  const relative = file('mh/data/mimocode-dev.db');
  process.env.MIMOCODE_DB = 'mimocode-dev.db';
  assert.deepEqual(discoverAll().mimo, [relative], '相对路径相对数据目录，且取代目录扫描');
  process.env.MIMOCODE_DB = custom;
  assert.deepEqual(discoverAll().mimo, [custom]);
  process.env.MIMOCODE_DB = ':memory:';
  assert.deepEqual(discoverAll().mimo, []);
}, mimoEnv));

test('L2 mimo: legacy ~/.mimo and AppData mimo logs are no longer discovered', () => isolated(({ home, file }) => {
  file('.mimo/sessions/project/a.jsonl');
  file('.mimo/logs/project/b.json');
  file('roaming/mimo/sessions/project/a.jsonl');
  file('local/mimo/sessions/project/a.jsonl');
  file('.config/mimo/sessions/project/a.jsonl');
  process.env.MIMO_HOME = join(home, 'elsewhere');
  file('elsewhere/sessions/a.jsonl');
  assert.deepEqual(discoverAll().mimo, []);
}, [...mimoEnv, 'MIMO_HOME']));

test('L2 mimo: relative MIMOCODE_HOME discovers nothing instead of following the lens cwd', () => isolated(({ home, file }) => {
  const base = mkdtempSync(join(tmpdir(), 'tl-l2-cwd-'));
  const savedCwd = process.cwd();
  try {
    process.chdir(base);
    mkdirSync(join(base, 'relhome', 'data'), { recursive: true });
    writeFileSync(join(base, 'relhome', 'data', 'mimocode.db'), '{}\n');
    file('.local/share/mimocode/mimocode.db');
    process.env.MIMOCODE_HOME = 'relhome';
    assert.deepEqual(discoverAll().mimo, [], '相对 MIMOCODE_HOME 不按采集进程的 cwd 解释，也不回退默认目录');
  } finally {
    process.chdir(savedCwd);
    rmSync(base, { recursive: true, force: true });
  }
}, mimoEnv));

test('L2 mimo: default discovery lists only mimocode.db, not backup or channel dbs', () => isolated(({ file }) => {
  const main = file('.local/share/mimocode/mimocode.db');
  file('.local/share/mimocode/mimocode-backup.db');
  assert.deepEqual(normalize(discoverAll().mimo), normalize([main]), '未设 MIMOCODE_DISABLE_CHANNEL_DB 时只发现 mimocode.db');
}, mimoEnv));

test('L2 mimo: MIMOCODE_DISABLE_CHANNEL_DB=false or 0 also discovers mimocode-*.db', () => isolated(({ file }) => {
  const both = [
    file('.local/share/mimocode/mimocode.db'),
    file('.local/share/mimocode/mimocode-backup.db')
  ];
  process.env.MIMOCODE_DISABLE_CHANNEL_DB = 'false';
  assert.deepEqual(normalize(discoverAll().mimo), normalize(both), 'false 打开 channel 库');
  process.env.MIMOCODE_DISABLE_CHANNEL_DB = '0';
  assert.deepEqual(normalize(discoverAll().mimo), normalize(both), '0 同样打开 channel 库');
}, mimoEnv));
