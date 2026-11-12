import { existsSync, realpathSync, mkdirSync, writeFileSync, lstatSync, copyFileSync, readdirSync, readFileSync } from 'node:fs';
import { resolve, isAbsolute, relative, sep, join, dirname } from 'node:path';
import { homedir, userInfo } from 'node:os';
import { createHash } from 'node:crypto';

export const overrides = ['DB_PATH', 'TOKEN_LENS_DATA_DIR', 'XDG_DATA_HOME', 'OPENCODE_DB', 'KILO_DB', 'MIMOCODE_HOME', 'MIMOCODE_DB', 'MIMOCODE_DISABLE_CHANNEL_DB', 'KIMI_SHARE_DIR', 'OPENHANDS_CONVERSATIONS_DIR', 'OPENHANDS_PERSISTENCE_DIR', 'ZCODE_DATA_BASE_DIR', 'ZCODE_SESSION_DB_PATH', 'ZCODE_SESSION_DB', 'MINIMAX_DATA_DIR', 'GEMINI_HOME', 'GOOSE_PATH_ROOT', 'COPILOT_HOME', 'OPENCLAW_HOME', 'OPENCLAW_STATE_DIR', 'NODE_OPTIONS', 'NODE_PATH'];
export function inside(root, path) {
  const rel = relative(root, path);
  return rel === '' || (!rel.startsWith(`..${sep}`) && rel !== '..' && !isAbsolute(rel));
}
export function parseArgs(args = process.argv.slice(2)) {
  const values = {};
  for (let i = 0; i < args.length; i += 2) {
    if (!['--home', '--out', '--now', '--tz', '--seed'].includes(args[i]) || !args[i + 1] || values[args[i].slice(2)]) throw Error('invalid arguments');
    values[args[i].slice(2)] = args[i + 1];
  }
  if (!values.now || !values.tz || !isAbsolute(values.home ?? '') || !isAbsolute(values.out ?? '')) throw Error('home/out must be absolute; now/tz required');
  if (!/^\d{4}-\d\d-\d\dT.*(?:Z|[+-]\d\d:\d\d)$/.test(values.now) || !Number.isFinite(Date.parse(values.now))) throw Error('invalid ISO now');
  new Intl.DateTimeFormat('en', { timeZone: values.tz });
  const suppliedHome = resolve(values.home), out = resolve(values.out);
  if (values.seed !== undefined) values.seed = validateSeed(values.seed, out);
  const userHomes = [...new Set([homedir(), userInfo().homedir])].map(path => resolve(path));
  // Reject protected paths before doing any filesystem work on them.
  for (const userHome of userHomes) {
    if (suppliedHome.toLowerCase() === userHome.toLowerCase() || inside(join(userHome, '.token-lens'), suppliedHome) || inside(join(userHome, '.token-lens'), out)) throw Error('unsafe home/output');
  }
  const home = realpathSync(suppliedHome);
  for (const userHome of userHomes) if (home.toLowerCase() === userHome.toLowerCase() || inside(join(userHome, '.token-lens'), home)) throw Error('unsafe resolved home');
  if (inside(home, out) || inside(out, home)) throw Error('unsafe home/output');
  return { ...values, home, out, now: new Date(values.now).toISOString() };
}
// Validate before creating output or reading any protected ledger. Never open the seed with SQLite.
export function validateSeed(seed, out) {
  if (!isAbsolute(seed)) throw Error('seed must be absolute');
  seed = resolve(seed);
  const homes = [homedir(), userInfo().homedir, process.env.HOME, process.env.USERPROFILE].filter(Boolean);
  for (const home of homes) {
    const ledger = join(resolve(home), '.token-lens');
    if (inside(ledger, seed) || inside(ledger, out)) throw Error('seed/output inside real ledger');
  }
  if (inside(seed, out) || inside(out, seed)) throw Error('seed/output overlap');
  for (const path of [seed, out]) {
    for (let cursor = path; ; cursor = dirname(cursor)) {
      if (existsSync(cursor) && lstatSync(cursor).isSymbolicLink()) throw Error('seed/output path links are not allowed');
      if (dirname(cursor) === cursor) break;
    }
  }
  seed = realpathSync(seed);
  for (const home of homes) if (inside(join(resolve(home), '.token-lens'), seed)) throw Error('resolved seed inside real ledger');
  if (inside(seed, out) || inside(out, seed)) throw Error('resolved seed/output overlap');
  for (const name of ['ledger.db', 'ledger.db-wal', 'ledger.db-shm']) {
    const file = join(seed, name);
    if (name !== 'ledger.db' && !existsSync(file)) continue;
    const stat = lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) throw Error('seed ledger must be an ordinary file');
  }
  return seed;
}
export function copySeed(seed, target) {
  mkdirSync(target, { recursive: true });
  for (const name of ['ledger.db', 'ledger.db-wal', 'ledger.db-shm']) {
    if (existsSync(join(seed, name))) copyFileSync(join(seed, name), join(target, name));
  }
  return createHash('sha256').update(readFileSync(join(target, 'ledger.db'))).digest('hex');
}
export function environment(home, tz, temp) {
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if ([...overrides, 'HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'TZ', 'TMP', 'TEMP', 'TMPDIR', 'NODE_TEST_CONTEXT'].includes(key.toUpperCase())) delete env[key];
  }
  Object.assign(env, { HOME: home, USERPROFILE: home, APPDATA: join(home, 'AppData/Roaming'), LOCALAPPDATA: join(home, 'AppData/Local'), TZ: tz, TMP: temp, TEMP: temp, TMPDIR: temp });
  mkdirSync(temp, { recursive: true });
  return env;
}
export function validateSnapshot(home) {
  const walk = directory => {
    for (const name of readdirSync(directory)) {
      const file = join(directory, name), stat = lstatSync(file);
      if (stat.isSymbolicLink()) throw Error('snapshot links are not allowed');
      if (stat.isDirectory()) walk(file);
      else if (file.endsWith(join('.zcode', 'v2', 'setting.json')) || file.endsWith(join('.zcode', 'cli', 'config.json'))) {
        let settings;
        try { settings = JSON.parse(readFileSync(file, 'utf8')); } catch { continue; }
        for (const path of [settings?.dataBaseDir, settings?.storage?.sessionDbPath]) {
          if (typeof path === 'string' && isAbsolute(path.trim()) && !inside(home, resolve(path.trim()))) throw Error('snapshot config points outside home');
        }
      }
    }
  };
  walk(home);
}
export const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
export function safeNotes(value) { return value === null ? null : JSON.parse(value).map(note => digest(note)); }
export function ledgerRows(db) {
  const result = [];
  for (const table of ['usage_records', 'legacy_records', 'pricing_snapshot', 'ingest_runs']) {
    const order = { usage_records: 'record_key', pricing_snapshot: 'version' }[table] ?? 'id';
    const rows = db.prepare(`SELECT * FROM ${table} ORDER BY ${order}`).all();
    const keys = table === 'usage_records' ? new Map(rows.map(row => [row.id, row.record_key])) : null;
    for (const row of rows) {
      if (table === 'usage_records') { delete row.id; row.superseded_by = row.superseded_by === null ? null : keys.get(row.superseded_by); }
      if (table === 'ingest_runs') { row.notes = safeNotes(row.notes); row.counts = row.counts === null ? null : JSON.parse(row.counts); }
      if (table === 'pricing_snapshot') row.catalog_json = JSON.parse(row.catalog_json);
      result.push({ type: 'ledger_row', table, expected: row });
    }
  }
  return result;
}
export function usageDigest(rows) {
  const stable = value => {
    if (Array.isArray(value)) return value.map(stable);
    if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).filter(key => key !== 'ingested_at').sort().map(key => [key, stable(value[key])]));
    return value;
  };
  return digest(stable(rows.filter(row => row.table === 'usage_records').map(row => row.expected)));
}
export function writeJsonl(file, rows) { writeFileSync(file, rows.map(row => JSON.stringify(row)).join('\n') + '\n'); }

// Source probes are private temporary inputs, never exported. Preserve paths in
// the primary comparison; only the independent parser-note audit uses mirrors.
export function mirrorSource(home, files, target, source) {
  const copy = file => {
    if (!existsSync(file)) return;
    const rel = relative(home, file);
    if (!inside(home, file) || !inside(home, realpathSync(file)) || lstatSync(file).isSymbolicLink()) throw Error('source escaped supplied home');
    const destination = join(target, rel);
    if (lstatSync(file).isDirectory()) {
      mkdirSync(destination, { recursive: true });
      for (const entry of readdirSync(file)) copy(join(file, entry));
    } else { mkdirSync(dirname(destination), { recursive: true }); copyFileSync(file, destination); }
  };
  for (const file of files) {
    copy(file);
    for (const suffix of ['-wal', '-shm']) copy(`${file}${suffix}`);
    if (source === 'grok') copy(join(dirname(file), 'summary.json'));
    if (source === 'cline') copy(join(dirname(file), 'ui_messages.json'));
    if (source === 'openhands') copy(join(dirname(file), 'events'));
    if (source === 'codebuddy' && file.endsWith('index.json')) copy(join(dirname(dirname(file)), 'index.json'));
    if (source === 'copilot') {
      const sibling = join(dirname(file), 'session-store.db');
      copy(sibling); for (const suffix of ['-wal', '-shm']) copy(sibling + suffix);
    }
  }
  if (source === 'zcode') {
    const config = file => {
      if (!existsSync(file)) return null;
      let value;
      try { value = JSON.parse(readFileSync(file, 'utf8')); } catch { return null; }
      const originalBase = value.dataBaseDir;
      if (typeof value.dataBaseDir === 'string' && isAbsolute(value.dataBaseDir.trim())) value.dataBaseDir = join(target, relative(home, value.dataBaseDir.trim()));
      const session = value.storage?.sessionDbPath;
      if (typeof session === 'string' && isAbsolute(session.trim())) value.storage.sessionDbPath = join(target, relative(home, session.trim()));
      const destination = join(target, relative(home, file));
      mkdirSync(dirname(destination), { recursive: true });
      writeFileSync(destination, JSON.stringify(value));
      return originalBase;
    };
    const base = config(join(home, '.zcode/v2/setting.json'));
    config(join(home, '.zcode/cli/config.json'));
    if (typeof base === 'string' && isAbsolute(base.trim())) config(join(base.trim(), '.zcode/cli/config.json'));
  }
  mkdirSync(target, { recursive: true });
}
