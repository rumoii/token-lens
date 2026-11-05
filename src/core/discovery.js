import { homedir } from 'node:os';
import { isAbsolute, join, resolve } from 'node:path';
import { existsSync, globSync, lstatSync, readdirSync, readFileSync, statSync } from 'node:fs';

/**
 * 安全地对目标目录执行 glob 搜索，若目录不存在则直接返回空数组。
 * 显式返回完整绝对路径。
 *
 * @param {string} cwd 搜索根目录
 * @param {string} pattern Glob 匹配模式
 * @returns {string[]} 匹配到的绝对路径列表
 */
function safeGlob(cwd, pattern) {
  if (!existsSync(cwd)) return [];
  try {
    const matches = globSync(pattern, {
      cwd,
      nodir: true
    });
    return matches.map(file => resolve(cwd, file));
  } catch {
    return [];
  }
}

/** 同一个文件可能被多条规则命中，按首次出现的顺序去重。 */
function unique(list) {
  return [...new Set(list)];
}

/**
 * @param {string} home
 */
function getHermesDbPath(home) {
  if (process.platform === 'win32') {
    const localAppData = process.env.LOCALAPPDATA || join(home, 'AppData', 'Local');
    return join(localAppData, 'hermes', 'state.db');
  }
  return join(home, '.hermes', 'state.db');
}

/**
 * 获取跨平台各种 VS Code 变体 globalStorage 目录列表。
 *
 * @param {string} home
 * @param {string[]} [ideDirs]
 * @returns {string[]}
 */
function getGlobalStorageBases(home, ideDirs = ['Code', 'Code - Insiders', 'VSCodium', 'Cursor']) {
  if (process.platform === 'win32') {
    const appData = process.env.APPDATA || join(home, 'AppData', 'Roaming');
    return ideDirs.map(ide => join(appData, ide, 'User', 'globalStorage'));
  }
  if (process.platform === 'darwin') {
    return ideDirs.map(ide => join(home, 'Library', 'Application Support', ide, 'User', 'globalStorage'));
  }
  return ideDirs.map(ide => join(home, '.config', ide, 'User', 'globalStorage'));
}

/**
 * @param {string} home
 */
function getCursorStateDbPath(home) {
  if (process.platform === 'win32') {
    const appData = process.env.APPDATA || join(home, 'AppData', 'Roaming');
    return join(appData, 'Cursor', 'User', 'globalStorage', 'state.vscdb');
  }
  if (process.platform === 'darwin') {
    return join(home, 'Library', 'Application Support', 'Cursor', 'User', 'globalStorage', 'state.vscdb');
  }
  return join(home, '.config', 'Cursor', 'User', 'globalStorage', 'state.vscdb');
}

/**
 * 上游 packages/util/src/global-roots.ts：各平台都用 XDG_DATA_HOME，否则 ~/.local/share。
 * 相对 XDG_DATA_HOME 按 XDG 规范忽略（同 getMimocodeDbPaths）。
 * OPENCODE_DB 已设置时只发现指定的普通文件；空串解析为数据目录，CR/LF 保留原值。
 * 渠道名任意，与备份库、迁移残留的文件名分不开，不扫描渠道库；需用 OPENCODE_DB 显式指定。
 * @param {string} home
 */
function getOpencodeDbPaths(home) {
  const xdgData = (process.env.XDG_DATA_HOME || '').replace(/[\r\n]+/g, '');
  const data = join(isAbsolute(xdgData) ? xdgData : join(home, '.local', 'share'), 'opencode');
  const override = process.env.OPENCODE_DB;
  if (override !== undefined) {
    if (override === ':memory:') return [];
    const file = isAbsolute(override) ? override : resolve(data, override);
    try { return statSync(file).isFile() ? [file] : []; } catch { return []; }
  }
  const main = join(data, 'opencode.db');
  return [
    ...(existsSync(main) ? [main] : []),
    ...safeGlob(home, '.opencode/opencode.db')
  ];
}

/**
 * 上游 kimi_cli/share.py：KIMI_SHARE_DIR 非空时用它，否则 ~/.kimi。相对值相对的是 Kimi
 * 进程的 cwd，这里无从得知，返回 null（同 getOpenhandsRoot）。
 * @param {string} home
 */
function getKimiShareDir(home) {
  const share = process.env.KIMI_SHARE_DIR;
  if (!share) return join(home, '.kimi');
  return isAbsolute(share) ? share : null;
}

/** Kilo 的 xdg-basedir 在 Windows 也使用 ~/.local/share；KILO_HOME 不参与数据路径。 */
function getKiloDbPath(home) {
  const xdgData = (process.env.XDG_DATA_HOME || '').replace(/[\r\n]+/g, '');
  const data = join(isAbsolute(xdgData) ? xdgData : join(home, '.local', 'share'), 'kilo');
  const override = process.env.KILO_DB;
  if (override === ':memory:') return null;
  if (override) return isAbsolute(override) ? override : join(data, override);
  return join(data, 'kilo.db');
}

/**
 * MiMo Code（OpenCode 分支）的库：MIMOCODE_HOME/data，否则 xdg 数据目录下的 mimocode
 * （xdg-basedir 在 Windows 也使用 ~/.local/share）。MIMOCODE_HOME 为空串时按未设置处理；非空但不是绝对路径时
 * 什么都不发现（返回 []）：上游 resolveMimocodeHome 对非绝对值直接抛错，MiMo 不会启动，
 * 也就不会写库；相对值也不按采集进程的 cwd 解释（同 getOpenhandsRoot）。相对 XDG_DATA_HOME
 * 按 XDG 规范忽略，回退 ~/.local/share。MIMOCODE_DB 覆盖：
 * 绝对路径直接用，:memory: 不发现，相对路径相对数据目录。未覆盖时默认只发现数据目录下的
 * mimocode.db；上游 MIMOCODE_DISABLE_CHANNEL_DB 默认禁用 channel 库，仅当其值（不区分
 * 大小写）为 false 或 0 时才额外发现 mimocode-*.db（备份库混入会把账本改小）。
 */
function getMimocodeDbPaths(home) {
  const homeOverride = process.env.MIMOCODE_HOME;
  if (homeOverride && !isAbsolute(homeOverride)) return [];
  const xdgData = (process.env.XDG_DATA_HOME || '').replace(/[\r\n]+/g, '');
  const data = homeOverride
    ? join(homeOverride, 'data')
    : join(isAbsolute(xdgData) ? xdgData : join(home, '.local', 'share'), 'mimocode');
  const override = process.env.MIMOCODE_DB;
  if (override === ':memory:') return [];
  if (override) {
    const file = isAbsolute(override) ? override : join(data, override);
    return existsSync(file) ? [file] : [];
  }
  const main = safeGlob(data, 'mimocode.db');
  const flag = (process.env.MIMOCODE_DISABLE_CHANNEL_DB || '').toLowerCase();
  return flag === 'false' || flag === '0' ? [...main, ...safeGlob(data, 'mimocode-*.db')] : main;
}

/**
 * OpenHands 的覆盖变量为相对路径或空串时，相对的是 OpenHands 进程的 cwd，这里无从得知；
 * 不按采集进程的 cwd 解释，返回 null。
 * @param {string} home
 */
function getOpenhandsRoot(home) {
  const conversations = process.env.OPENHANDS_CONVERSATIONS_DIR;
  if (conversations !== undefined) return isAbsolute(conversations) ? conversations : null;
  const persistence = process.env.OPENHANDS_PERSISTENCE_DIR;
  if (persistence !== undefined) return isAbsolute(persistence) ? join(persistence, 'conversations') : null;
  return join(home, '.openhands', 'conversations');
}

/** 只沿会话/subagents/会话展开；迭代遍历，不限深度，不跟随子目录链接。 */
function getOpenhandsFiles(root) {
  const files = [];
  if (!root) return files;
  const pending = [root];
  while (pending.length) {
    let entries;
    const base = pending.pop();
    try { entries = readdirSync(base, { withFileTypes: true }); } catch { continue; }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const directory = join(base, entry.name);
      const file = join(directory, 'base_state.json');
      try { if (statSync(file).isFile()) files.push(file); } catch { /* 尚未写出状态。 */ }
      const children = join(directory, 'subagents');
      try { if (lstatSync(children).isDirectory()) pending.push(children); } catch { /* 没有子会话。 */ }
    }
  }
  return files;
}

/**
 * @param {string} home
 */
function getGooseDbPath(home) {
  if (process.platform === 'win32') {
    const appData = process.env.APPDATA || join(home, 'AppData', 'Roaming');
    return join(appData, 'goose', 'sessions', 'sessions.db');
  }
  if (process.platform === 'darwin') {
    return join(home, 'Library', 'Application Support', 'goose', 'sessions', 'sessions.db');
  }
  return join(home, '.local', 'share', 'goose', 'sessions', 'sessions.db');
}

/**
 * @param {string} home
 */
function getZedDbPath(home) {
  if (process.platform === 'win32') {
    const localAppData = process.env.LOCALAPPDATA || join(home, 'AppData', 'Local');
    return join(localAppData, 'Zed', 'threads', 'threads.db');
  }
  if (process.platform === 'darwin') {
    return join(home, 'Library', 'Application Support', 'Zed', 'threads', 'threads.db');
  }
  return join(home, '.local', 'share', 'zed', 'threads', 'threads.db');
}

function getZcodeDbPath(home) {
  return join(home, '.zcode', 'cli', 'db', 'db.sqlite');
}

/** Prisma fixes SQLite to server/storage; STORAGE_DIR controls other storage, not its DB URL. */
function getAnythingllmDbPath(home) {
  const base = process.platform === 'win32' ? (process.env.APPDATA || join(home, 'AppData', 'Roaming'))
    : process.platform === 'darwin' ? join(home, 'Library', 'Application Support') : join(home, '.config');
  return join(base, 'anythingllm-desktop', 'storage', 'anythingllm.db');
}

/** Third-party token_stats.rs: projects JSONL and history/<workspace>/<conversation>/index.json. */
function getCodebuddyFiles(home) {
  const files = [];
  const walk = (root, desktop) => {
    let entries;
    try { entries = readdirSync(root, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      const path = join(root, entry.name);
      if (entry.isDirectory()) {
        const ignored = desktop ? ['messages', 'check-point', 'backups', 'Public'] : ['subagents'];
        if (!ignored.includes(entry.name)) walk(path, desktop);
      } else if (entry.isFile() && (desktop
        ? entry.name === 'index.json' && root.split(/[\\/]/).at(-3) === 'history'
        : entry.name.endsWith('.jsonl'))) files.push(path);
    }
  };
  for (const name of ['.codebuddy', '.workbuddy', '.workbuddy-ai']) walk(join(home, name, 'projects'), false);
  const base = process.platform === 'win32' ? (process.env.LOCALAPPDATA || join(home, 'AppData', 'Local'))
    : process.platform === 'darwin' ? join(home, 'Library', 'Application Support') : join(home, '.local', 'share');
  walk(join(base, 'CodeBuddyExtension', 'Data'), true);
  return files;
}

/** 桌面版通过 HOME/USERPROFILE 传递数据根；相对配置依赖 agent 的 cwd，不在此猜测。 */
function getZcodeFiles(home) {
  const readJson = file => {
    try { return JSON.parse(readFileSync(file, 'utf8')); } catch { return null; }
  };
  const bases = new Set([home]);
  const settings = readJson(join(home, '.zcode', 'v2', 'setting.json'));
  for (const value of [process.env.ZCODE_DATA_BASE_DIR, settings?.dataBaseDir]) {
    if (typeof value === 'string' && isAbsolute(value.trim())) bases.add(value.trim());
  }
  const files = [];
  for (const base of bases) {
    files.push(getZcodeDbPath(base));
    const config = readJson(join(base, '.zcode', 'cli', 'config.json'));
    for (const value of [config?.storage?.sessionDbPath, process.env.ZCODE_SESSION_DB_PATH, process.env.ZCODE_SESSION_DB]) {
      if (typeof value !== 'string' || !value.trim()) continue;
      const path = value.trim();
      if (path.startsWith('~/')) files.push(join(base, path.slice(2)));
      else if (isAbsolute(path)) files.push(path);
    }
  }
  return files.filter(file => {
    try { return statSync(file).isFile(); } catch { return false; }
  });
}

/**
 * 探测本机所有支持工具的日志与数据库文件路径。
 * 主目录取调用时的 homedir()，结果不随模块加载时机变化。
 *
 * @returns {{ [source: string]: string[] }}
 */
export function discoverAll() {
  const home = homedir();
  const minimaxDataDir = process.env.MINIMAX_DATA_DIR;
  const hermesDefault = getHermesDbPath(home);
  const cursorDbDefault = getCursorStateDbPath(home);
  const kimiShare = getKimiShareDir(home);
  const kiloDb = getKiloDbPath(home);
  const openhandsRoot = getOpenhandsRoot(home);
  const gooseDbDefault = getGooseDbPath(home);
  const zedDbDefault = getZedDbPath(home);
  const globalBases = getGlobalStorageBases(home);
  const anythingllmDb = getAnythingllmDbPath(home);
  const extIds = ['saoudrizwan.claude-dev', 'rooveterinaryinc.roo-cline'];

  const clineFiles = [];
  for (const base of globalBases) {
    for (const extId of extIds) {
      const taskGlob = safeGlob(join(base, extId, 'tasks'), '*/api_conversation_history.json');
      clineFiles.push(...taskGlob);
    }
  }

  const found = {
    claude: safeGlob(join(home, '.claude', 'projects'), '**/*.jsonl'),
    codex: safeGlob(join(home, '.codex', 'sessions'), '**/rollout-*.{jsonl,jsonl.zst}'),
    qwen: safeGlob(join(home, '.qwen', 'usage'), '*-usage-*.jsonl'),
    dsh: safeGlob(join(home, '.dsh', 'storages', 'session_projcache', 'sessions'), '*.json'),
    grok: safeGlob(join(home, '.grok', 'sessions'), '*/*/updates.jsonl'),
    aider: safeGlob(home, '.aider.llm.history'),
    pi: safeGlob(join(home, '.pi', 'agent', 'sessions'), '**/*.jsonl'),
    hermes: existsSync(hermesDefault) ? [hermesDefault] : [],
    cline: clineFiles,
    gemini: [
      ...safeGlob(process.env.GEMINI_HOME || join(home, '.gemini'), 'sessions/**/*.{json,jsonl}'),
      ...safeGlob(join(home, '.config', 'gemini'), 'sessions/**/*.{json,jsonl}')
    ],
    cursor: [
      ...(existsSync(cursorDbDefault) ? [cursorDbDefault] : []),
      ...safeGlob(home, '*cursor*.csv')
    ],
    opencode: getOpencodeDbPaths(home),
    kilo: kiloDb && existsSync(kiloDb) ? [kiloDb] : [],
    openhands: getOpenhandsFiles(openhandsRoot),
    goose: [
      ...(existsSync(gooseDbDefault) ? [gooseDbDefault] : []),
      ...safeGlob(process.env.GOOSE_PATH_ROOT || join(home, '.goose'), 'data/sessions/sessions.db')
    ],
    zed: [
      ...(existsSync(zedDbDefault) ? [zedDbDefault] : []),
      ...safeGlob(home, '.local/share/zed/threads/threads.db')
    ],
    continue: safeGlob(join(home, '.continue', 'sessions'), '*.json'),
    trae: [
      ...safeGlob(home, '*trae*.{json,jsonl}'),
      ...getGlobalStorageBases(home, ['TRAE SOLO', 'Trae CN', 'TRAE SOLO CN', 'trae'])
        .flatMap(base => safeGlob(base, '**/*trae*.{json,jsonl}'))
    ],
    copilot: safeGlob(process.env.COPILOT_HOME || join(home, '.copilot'), '{session-store.db,data.db}'),
    openclaw: safeGlob(process.env.OPENCLAW_HOME || process.env.OPENCLAW_STATE_DIR || join(home, '.openclaw'), 'agents/*/{sessions,session-sqlite-import-archive}/*.jsonl*'),
    mimo: [
      ...getMimocodeDbPaths(home),
      // Windows MiMo Desktop 的库位置来自第三方工具（iCxin/xiaomi-mimo-usage）的说明：第三方说法，未核实。
      ...safeGlob(process.env.APPDATA || join(home, 'AppData', 'Roaming'), 'Xiaomi MiMo/mimocode/mimocode.db')
    ],
    kimi: [
      ...safeGlob(join(home, '.kimi-code'), 'sessions/*/*/agents/*/wire.jsonl'),
      ...(kimiShare ? safeGlob(kimiShare, '{sessions,logs}/**/*.{json,jsonl}') : []),
      ...safeGlob(process.env.APPDATA || join(home, 'AppData', 'Roaming'), '{kimi,Kimi}/{sessions,logs}/**/*.{json,jsonl}'),
      ...safeGlob(process.env.LOCALAPPDATA || join(home, 'AppData', 'Local'), '{kimi,Kimi}/{sessions,logs}/**/*.{json,jsonl}'),
      ...safeGlob(join(home, '.config', 'kimi'), '{sessions,logs}/**/*.{json,jsonl}')
    ],
    minimax: minimaxDataDir ? (
      isAbsolute(minimaxDataDir) ? safeGlob(minimaxDataDir, 'v2/sqlite/runtime-state.sqlite') : []
    ) : [
      ...safeGlob(join(home, '.minimax'), 'v2/sqlite/runtime-state.sqlite'),
      ...safeGlob(home, '.minimax-*/v2/sqlite/runtime-state.sqlite')
    ],
    codebuddy: getCodebuddyFiles(home),
    zcode: getZcodeFiles(home),
    commandcode: safeGlob(join(home, '.commandcode', 'projects'), '*/*.jsonl')
      .filter(file => !/\.(?:checkpoints|prompts)\.jsonl$/.test(file)),
    anythingllm: existsSync(anythingllmDb) ? [anythingllmDb] : []
  };

  return Object.fromEntries(Object.entries(found).map(([source, list]) => [source, unique(list)]));
}
