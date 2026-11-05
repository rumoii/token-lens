import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// From process.env reads in src/core/discovery.js and src/core/adapters, plus legacy
// oracle path overrides. Keep this list in sync when adding discovery variables.
export const CLIENT_ENV_OVERRIDES = Object.freeze([
  'XDG_DATA_HOME', 'OPENCODE_DB', 'KILO_DB', 'GEMINI_HOME', 'GOOSE_PATH_ROOT', 'COPILOT_HOME',
  'OPENCLAW_HOME', 'OPENCLAW_STATE_DIR', 'KIMI_SHARE_DIR', 'MINIMAX_DATA_DIR',
  'MIMOCODE_HOME', 'MIMOCODE_DB', 'MIMOCODE_DISABLE_CHANNEL_DB',
  'OPENHANDS_CONVERSATIONS_DIR', 'OPENHANDS_PERSISTENCE_DIR',
  'MAVIS_DATA_DIR', 'ZCODE_DATA_BASE_DIR', 'ZCODE_SESSION_DB_PATH', 'ZCODE_SESSION_DB',
  'KIMI_HOME', 'CODEBUDDY_HOME', 'WORKBUDDY_HOME'
]);

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const dashboard = join(root, 'dashboard');
const checks = {
  core: { label: 'Core tests', cwd: root, args: ['--test', 'test/core/*.test.js'] },
  dashboard: {
    label: 'Dashboard tests', cwd: dashboard,
    args: ['node_modules/vitest/vitest.mjs', 'run']
  },
  build: {
    label: 'Dashboard build', cwd: dashboard,
    args: ['node_modules/vite/bin/vite.js', 'build']
  },
  types: {
    label: 'Dashboard typecheck', cwd: dashboard,
    args: ['node_modules/typescript/bin/tsc', '--noEmit']
  }
};
const groups = {
  all: ['core', 'dashboard', 'build', 'types'],
  core: ['core'],
  dashboard: ['dashboard']
};

function verify() {
  const [group = 'all', ...extra] = process.argv.slice(2);
  if (!Object.hasOwn(groups, group) || extra.length) {
    throw new Error('Usage: node scripts/verify-local.mjs [all|core|dashboard]');
  }
  const selected = groups[group].map((name) => checks[name]);
  for (const check of selected) {
    const entry = check.args[0];
    if (!entry.startsWith('-') && !existsSync(resolve(check.cwd, entry))) {
      const remedy = check.cwd === dashboard
        ? 'install the locked dependencies with npm ci --prefix dashboard'
        : 'restore the missing repository file';
      throw new Error(`${check.label}: missing local file ${entry}; ${remedy}.`);
    }
  }

  const temporaryParent = realpathSync(tmpdir());
  const temporaryRoot = mkdtempSync(join(temporaryParent, 'tl-verify-'));
  let status = 0;
  try {
    const home = join(temporaryRoot, 'home');
    const data = join(temporaryRoot, 'data');
    const temp = join(temporaryRoot, 'tmp');
    const roaming = join(home, 'AppData', 'Roaming');
    const local = join(home, 'AppData', 'Local');
    for (const directory of [home, data, temp, roaming, local]) {
      mkdirSync(directory, { recursive: true });
    }
    const overrides = {
      HOME: home, USERPROFILE: home, APPDATA: roaming, LOCALAPPDATA: local,
      TOKEN_LENS_DATA_DIR: data, TEMP: temp, TMP: temp, TMPDIR: temp
    };
    const env = { ...process.env };
    // A nested node --test must not inherit the caller's test-worker marker and skip its files.
    // Windows treats environment keys case-insensitively, including inherited variants.
    for (const key of Object.keys(env)) {
      if (['DB_PATH', 'NODE_TEST_CONTEXT'].includes(key.toUpperCase()) ||
          CLIENT_ENV_OVERRIDES.includes(key.toUpperCase()) || Object.hasOwn(overrides, key.toUpperCase())) delete env[key];
    }
    Object.assign(env, overrides);

    for (const check of selected) {
      console.log(`\n[verify] ${check.label}`);
      const child = spawnSync(process.execPath, check.args, {
        cwd: check.cwd, env, stdio: 'inherit', windowsHide: true
      });
      if (child.error) throw child.error;
      if (child.status !== 0) {
        console.error(`[verify] ${check.label} failed (${child.signal || child.status}).`);
        status = child.status || 1;
        break;
      }
    }
  } finally {
    // Only remove the directory created by this invocation, under the resolved temp parent.
    if (dirname(temporaryRoot) !== temporaryParent || !basename(temporaryRoot).startsWith('tl-verify-') ||
        realpathSync(temporaryRoot) !== temporaryRoot) {
      throw new Error(`Refusing to clean an unexpected temporary directory: ${temporaryRoot}`);
    }
    rmSync(temporaryRoot, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  }
  return status;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = verify();
  } catch (error) {
    console.error(`[verify] ${error.message}`);
    process.exitCode = 1;
  }
}
