#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { aggregate, discover, fields } from './oracle/common.mjs';
import { oracle as claude } from './oracle/claude.mjs';
import { oracle as codex } from './oracle/codex.mjs';
import { oracle as qwen } from './oracle/qwen.mjs';
import { oracle as dsh } from './oracle/dsh.mjs';
import { oracle as pi } from './oracle/pi.mjs';
import { oracle as kimi } from './oracle/kimi.mjs';

const oracles = { claude, codex, qwen, dsh, pi, kimi };
const repository = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const columns = ['input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens'];
const hash = buffer => createHash('sha256').update(buffer).digest('hex');
const keyOf = row => JSON.stringify([row.source, row.session_id]);

export function compareSessions(expected, actual) {
  const left = new Map(expected.map(row => [keyOf(row), row]));
  const right = new Map(actual.map(row => [keyOf(row), row]));
  return [...new Set([...left.keys(), ...right.keys()])].sort().map(key => {
    const oracle = left.get(key) ?? null, ledger = right.get(key) ?? null;
    const differences = [];
    if (!oracle || !ledger) differences.push({ field: 'presence', oracle: !!oracle, ledger: !!ledger });
    for (const field of ['records', ...fields]) {
      if ((oracle?.[field] ?? null) !== (ledger?.[field] ?? null)) differences.push({ field, oracle: oracle?.[field] ?? null,
        ledger: ledger?.[field] ?? null, delta: typeof oracle?.[field] === 'number' && typeof ledger?.[field] === 'number' ? ledger[field] - oracle[field] : null });
    }
    for (const field of fields) {
      if ((oracle?.unknown[field] ?? null) !== (ledger?.unknown[field] ?? null)) differences.push({ field: `${field}_unknown`,
        oracle: oracle?.unknown[field] ?? null, ledger: ledger?.unknown[field] ?? null });
    }
    return { source: (oracle ?? ledger).source, session_id: (oracle ?? ledger).session_id, equal: differences.length === 0, oracle, ledger, differences };
  });
}

export function parseArgs(argv) {
  const options = { sources: Object.keys(oracles) };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!['--data-dir', '--out', '--source'].includes(arg) || !argv[i + 1] || argv[i + 1].startsWith('--')) throw new Error(`参数无效：${arg}`);
    const value = argv[++i];
    if (arg === '--source') {
      options.sources = [...new Set(value.split(',').map(s => s.trim()))];
      if (options.sources.some(source => !Object.hasOwn(oracles, source))) throw new Error(`来源只能是 ${Object.keys(oracles).join(',')}`);
    } else options[arg === '--out' ? 'out' : 'dataDir'] = resolve(value);
  }
  if (!options.dataDir || !options.out) throw new Error('必须指定 --data-dir <全新临时目录> --out <仓库外报告目录>');
  return options;
}

function inside(parent, target) {
  const rel = relative(parent, target);
  return rel === '' || (!rel.startsWith(`..${sep}`) && rel !== '..' && !isAbsolute(rel));
}

function canonical(target) {
  if (existsSync(target)) return realpathSync(target);
  return join(canonical(dirname(target)), relative(dirname(target), target));
}

export function validatePaths(options, home = homedir()) {
  for (const target of [options.dataDir, options.out]) {
    if (target.split(/[\\/]/).some(part => part.toLowerCase() === '.token-lens')) throw new Error('禁止使用已安装账本目录');
    const actual = canonical(target);
    if (actual.split(/[\\/]/).some(part => part.toLowerCase() === '.token-lens')) throw new Error('禁止使用已安装账本目录');
    if (inside(canonical(repository), actual)) throw new Error('数据和报告目录必须在仓库外');
    // Neither a tool log directory nor an ancestor of it may become a write root.
    for (const tool of ['.claude', '.codex', '.qwen', '.dsh', '.pi', '.kimi-code']) {
      const source = canonical(join(home, tool));
      if (inside(source, actual) || inside(actual, source)) throw new Error('写入目录不能覆盖真实工具目录');
    }
  }
  if (inside(options.dataDir, options.out) || inside(options.out, options.dataDir)) throw new Error('数据目录与报告目录不能相互包含');
  if (existsSync(options.dataDir) && (!statSync(options.dataDir).isDirectory() || readdirSync(options.dataDir).length)) {
    throw new Error('--data-dir 必须不存在或为空；拒绝读取、修改已有账本');
  }
}

function freezeLogs(sources, originalHome, frozenHome) {
  const manifest = [];
  for (const source of sources) {
    for (const original of discover(source, originalHome)) {
      const before = statSync(original);
      const bytes = readFileSync(original);
      const after = statSync(original);
      const file = join(frozenHome, relative(originalHome, original));
      mkdirSync(dirname(file), { recursive: true });
      writeFileSync(file, bytes, { flag: 'wx' });
      manifest.push({ source, original, file, bytes: bytes.length, sha256: hash(bytes),
        capture_changed: before.size !== after.size || before.mtimeMs !== after.mtimeMs,
        captured_at: new Date().toISOString() });
    }
  }
  return manifest;
}

function isolate(dataDir) {
  const runtime = join(dataDir, 'runtime');
  const home = join(runtime, 'home'), cwd = join(runtime, 'cwd'), temp = join(runtime, 'temp');
  const overrides = { HOME: home, USERPROFILE: home, APPDATA: join(home, 'AppData/Roaming'),
    LOCALAPPDATA: join(home, 'AppData/Local'), TEMP: temp, TMP: temp, TMPDIR: temp,
    TOKEN_LENS_DATA_DIR: dataDir };
  for (const directory of [home, cwd, temp, overrides.APPDATA, overrides.LOCALAPPDATA]) mkdirSync(directory, { recursive: true });
  for (const name of Object.keys(process.env)) {
    if (Object.hasOwn(overrides, name.toUpperCase()) || name.toUpperCase() === 'DB_PATH' ||
        /^(GEMINI_HOME|GOOSE_PATH_ROOT|COPILOT_HOME|OPENCLAW_HOME|OPENCLAW_STATE_DIR|XDG_DATA_HOME|KILO_DB|OPENHANDS_CONVERSATIONS_DIR|OPENHANDS_PERSISTENCE_DIR|MIMOCODE_HOME|MIMOCODE_DB|MIMOCODE_DISABLE_CHANNEL_DB|MINIMAX_DATA_DIR|MAVIS_DATA_DIR|ZCODE_DATA_BASE_DIR|ZCODE_SESSION_DB_PATH|ZCODE_SESSION_DB|KIMI_HOME|CODEBUDDY_HOME|WORKBUDDY_HOME)$/i.test(name)) delete process.env[name];
  }
  Object.assign(process.env, overrides);
  process.chdir(cwd);
  return { home, cwd, temp };
}

function ledgerEntries(dataDir) {
  const db = new DatabaseSync(join(dataDir, 'ledger.db'), { readOnly: true });
  try {
    return db.prepare(`SELECT source, session_id, record_key, source_file, observed_at,
      input_tokens, output_tokens, cache_read_tokens, cache_write_tokens
      FROM usage_records WHERE active = 1 ORDER BY source, session_id, record_key`).all().map(row => ({
      source: row.source, session_id: row.session_id, record_key: row.record_key, file: row.source_file, observed_at: row.observed_at,
      ...Object.fromEntries(fields.map((field, index) => [field, row[columns[index]]]))
    }));
  } finally { db.close(); }
}

function entryDetails(result, rows, session) {
  const expected = result.entries.filter(row => row.session_id === session.session_id);
  const actual = rows.filter(row => row.source === result.source && row.session_id === session.session_id);
  const used = new Set(), details = [];
  for (const row of expected) {
    const id = row.raw?.message_id ?? row.raw?.response_id ?? row.raw?.id ?? row.raw?.uuid;
    const matches = result.source === 'dsh' ? rows.filter(other => other.source === 'dsh' && other.file === row.file)
      : id == null ? [] : actual.filter(other => other.record_key.endsWith(`|${id}`));
    const matched = matches.length === 1 ? matches[0] : null;
    if (matched) used.add(matched.record_key);
    const identityDifference = matched && row.session_id !== matched.session_id;
    if (!matched || identityDifference || fields.some(field => row[field] !== matched[field])) details.push({
      status: identityDifference ? 'session_identity_difference' : matched ? 'token_difference' : 'unmatched_oracle_entry', file: row.file, line: row.line,
      identity: row.identity, oracle: row, ledger: matched,
      reason: explain(row, matched)
    });
  }
  for (const row of actual) if (!used.has(row.record_key)) {
    const fileMatch = result.source === 'dsh' ? result.entries.find(other => other.file === row.file) : null;
    details.push({ status: fileMatch ? 'session_identity_difference' : 'unmatched_ledger_entry', ledger: row,
      ...(fileMatch ? { oracle: fileMatch, file: fileMatch.file, line: fileMatch.line } : {}),
      reason: fileMatch ? explain(fileMatch, row) : '未匹配 oracle 事件 ID；具体原因未定位。' });
  }
  return details;
}

// These explanations were added only after the first independent comparison.
// They describe the production code; they never change the oracle's numbers.
function explain(row, matched) {
  if (row.source === 'dsh' && matched && row.session_id !== matched.session_id && fields.every(f => row[f] === matched[f])) {
    return '同一物理文件的四项 token 完全相同；会话名不同。规格未定义 session- 前缀，oracle 保留文件 stem；src/core/adapters/dsh.js:33 去掉前缀。登记为身份规格缺口，不当作用量多算。';
  }
  if (!matched && fields.every(field => row[field] === 0)) {
    const lines = { claude: 'claude.js:61-64', pi: 'pi.js:51-54', dsh: 'dsh.js:28-31' };
    return `原始条目四项明确为零；src/core/adapters/${lines[row.source] ?? '（该来源）'} 排除零用量。只影响条数/会话存在性，不改变 token 合计。`;
  }
  if (row.source === 'qwen' && matched && row.raw.thoughts > 0 && row.raw.total === row.raw.input + row.raw.output &&
      matched.output === row.raw.output && row.output === row.raw.output + row.raw.thoughts &&
      ['input', 'cache_read', 'cache_write'].every(f => row[f] === matched[f])) {
    return '规格/brief 要求 outputTokens + thoughtsTokens；src/core/adapters/qwen.js:35-40 在 totalTokens = inputTokens + outputTokens 时保留原 output。两者恰差 thoughtsTokens。客户端总量支持后一种包含关系，故这是规格与实现口径分歧，不能据此断言适配器漏计。';
  }
  return matched ? '原始字段归一后与账本不同；具体语义原因未定位，原值附后。'
    : '该会话未匹配到相同事件 ID；具体原因未定位。';
}

function fileComparison(result, rows) {
  return result.entries.map(oracle => {
    const matches = rows.filter(row => row.source === result.source && row.file === oracle.file);
    const ledger = matches.length === 1 ? matches[0] : null;
    return { file: oracle.file, line: oracle.line, oracle, ledger,
      equal: !!ledger && fields.every(f => oracle[f] === ledger[f]),
      only_zero: !ledger && fields.every(f => oracle[f] === 0) };
  });
}

function buckets(entries) {
  const groups = new Map();
  for (const row of entries) {
    const at = row.ended_at ?? row.observed_at;
    const bucket = at ? new Date(Math.floor(Date.parse(at) / 1800000) * 1800000).toISOString() : null;
    const key = JSON.stringify([row.file, bucket, row.session_id]);
    const group = groups.get(key) ?? { file: row.file, bucket, session_id: row.session_id, rows: [] };
    group.rows.push(row);
    groups.set(key, group);
  }
  return [...groups.values()].map(group => ({ file: group.file, bucket: group.bucket,
    ...aggregate(group.rows)[0], entries: group.rows.map(row => ({ line: row.line, identity: row.identity })) }));
}

function codexSessions(result) {
  const grouped = new Map();
  for (const check of result?.cross_checks ?? []) {
    const rows = grouped.get(check.session_id) ?? [];
    rows.push(check);
    grouped.set(check.session_id, rows);
  }
  return [...grouped].map(([session_id, files]) => ({ session_id,
    status: files.length > 1 ? 'multiple_file_totals_unresolved' : files[0].status,
    files: files.map(row => ({ file: row.file, line: row.line, usage_records: row.usage_records,
      total_token_usage: row.total_token_usage, usage_minus_total: row.usage_minus_total,
      raw_last_minus_total: row.raw_last_minus_total })) }));
}

const code = value => `\`${String(value ?? 'NULL').replaceAll('`', '\\`')}\``;

export function renderReport(report) {
  const lines = ['# L3 独立 oracle 对账', '', `生成时间：${report.generated_at}`, '',
    `任务基线：b781368；Node：${report.node_version}；临时账本：${code(report.data_dir)}`, '',
    '两套实现读同一份冻结日志。oracle 只依赖规格、原始字段和 Node 内建模块。未知值用 NULL，合计为已知部分之和，同时比较每字段未知条数；全未知合计仍为 NULL。', '',
    '会话分母为两边会话并集；无样本记 N/A，不能视为通过。零用量原始事件保留以暴露条数差异。Claude 单文件取同 ID 最后快照，跨文件归最早文件。', '',
    '| 来源 | 文件 | 会话 | 零差异 | 比例 | oracle 条数 | 账本条数 |',
    '|---|---:|---:|---:|---:|---:|---:|'];
  for (const row of report.summary) lines.push(`| ${row.source} | ${row.files} | ${row.sessions} | ${row.equal} | ${row.ratio === null ? 'N/A' : (row.ratio * 100).toFixed(2) + '%'} | ${row.oracle_records} | ${row.ledger_records} |`);
  lines.push('', '## 逐来源 token 合计', '', '| 来源 | 口径 | input | output | cache_read | cache_write | 未知条数 input/output/read/write |', '|---|---|---:|---:|---:|---:|---|');
  for (const result of report.results) {
    for (const [label, entries] of [['oracle', result.entries], ['账本', report.ledger_entries.filter(row => row.source === result.source)]]) {
      const total = aggregate(entries.map(row => ({ ...row, session_id: null })))[0];
      lines.push(`| ${result.source} | ${label} | ${fields.map(f => total?.[f] ?? 'NULL').join(' | ')} | ${fields.map(f => total?.unknown[f] ?? 0).join('/')} |`);
    }
  }
  lines.push('', '## 按会话的差异', '');
  for (const session of report.sessions.filter(row => !row.equal)) {
    lines.push(`### ${session.source} / ${code(session.session_id)}`, '',
      '| 字段 | oracle | 账本 | 账本减 oracle |', '|---|---:|---:|---:|');
    for (const diff of session.differences) lines.push(`| ${diff.field} | ${diff.oracle ?? 'NULL'} | ${diff.ledger ?? 'NULL'} | ${diff.delta ?? '—'} |`);
    lines.push('');
    for (const detail of session.entries) {
      const evidence = detail.oracle ?? detail.ledger;
      lines.push(`- ${detail.status}：${code(detail.file ?? evidence.file)}:${detail.line ?? '未知行号'}；${code(detail.identity ?? evidence.record_key)}。${detail.reason}`);
      lines.push(`  - oracle：${code(detail.oracle ? JSON.stringify(Object.fromEntries(fields.map(f => [f, detail.oracle[f]]))) : '无匹配')}；账本：${code(detail.ledger ? JSON.stringify(Object.fromEntries(fields.map(f => [f, detail.ledger[f]]))) : '无匹配')}`);
      if (detail.oracle) lines.push(`  - 原字段：${code(JSON.stringify(detail.oracle.raw))}`);
    }
    lines.push('');
  }
  if (report.sessions.every(row => row.equal)) lines.push('无会话级差异。', '');
  const checks = report.results.find(row => row.source === 'codex')?.cross_checks ?? [];
  const hasDiff = values => Object.values(values).some(value => value !== null && value !== 0);
  const multipleFiles = report.codex_session_checks.filter(row => row.status === 'multiple_file_totals_unresolved');
  lines.push('## Codex 客户端自报总量交叉核对', '',
    '比较每个会话文件末尾 total_token_usage 与唯一响应 usage 之和。last_token_usage 同时保留原始逐行和、以及仅累计值发生变化时的和；后一种是诊断口径，不能把累计值不变的通知一律断言为重复用量。累计回退单独登记，不猜压缩或续接语义。值为逐条之和减客户端末尾总量。', '',
    `文件级检查 ${checks.length} 份；末尾累计缺失 ${checks.filter(row => !row.total_token_usage).length} 份；usage 合计差异 ${checks.filter(row => hasDiff(row.usage_minus_total)).length} 份；原始 last 逐行合计差异 ${checks.filter(row => hasDiff(row.raw_last_minus_total)).length} 份。`, '',
    'raw last 逐行和保留了所有累计通知附带的 last，不能当成已去重的请求序列。累计不变通知的请求身份未知，不猜重放通知与新请求的边界。', '',
    `按日志 session_id 分组：${report.codex_session_checks.length} 组，其中 ${multipleFiles.length} 组对应多个文件。各文件分别上报累计值，规格未说明这些累计是否共享范围；保留分文件核对，不猜应取最大、末份或相加。`, '');
  for (const group of multipleFiles) lines.push(`- 多文件停止项 ${code(group.session_id)}：${group.files.map(row => code(row.file)).join('、')}。`);
  lines.push('', '| 会话 / 文件 | usage input/output/cached/total 差额 | 原始 last 差额 | 累计值变化时 last 差额 | 状态 |', '|---|---|---|---|---|');
  for (const check of report.results.find(row => row.source === 'codex')?.cross_checks ?? []) {
    lines.push(`| ${code(check.session_id)} / ${code(check.file)}:${check.line ?? '?'} | ${code(JSON.stringify(check.usage_minus_total))} | ${code(JSON.stringify(check.raw_last_minus_total))} | ${code(JSON.stringify(check.last_minus_total))} | ${check.status}；回退 ${check.cumulative_resets}；累计不变通知 ${check.repeated_token_count} |`);
  }
  lines.push('', '### Codex 累计值未反映的响应条目', '', '以下只描述可观察的时间邻接关系：响应之后的 token_count 累计未增加，或响应落在最后一条累计通知之后。不能据此断定哪种表示是实际计费用量。每文件的 residual_after_unreflected 为总差额减这些条目的和；不为零的仍未完全定位。', '');
  for (const check of report.results.find(row => row.source === 'codex')?.cross_checks ?? []) {
    if (!Object.values(check.usage_minus_total).some(n => n !== null && n !== 0)) continue;
    lines.push(`- ${code(check.file)}；残差：${code(JSON.stringify(check.residual_after_unreflected))}`);
    for (const response of check.unreflected_responses) lines.push(`  - 原文件解压后第 ${response.line} 行，${code(response.response_id)}，${response.reason}；后继累计通知行 ${response.notice_line ?? '无'}；usage=${code(JSON.stringify(response.usage))}；last=${code(JSON.stringify(response.last_token_usage ?? null))}`);
  }
  lines.push('', '## DSH 客户端自报 totals', '', '逐会话直接以 record.rows.tokenUsage.val.totals 为基准；多份同会话快照仅保留最后活动时间最新的一份。不存在的字段维持未知。', '');
  for (const check of report.results.find(row => row.source === 'dsh')?.cross_checks ?? []) lines.push(`- ${code(check.session_id)}：${code(check.file)}:1 ${code(JSON.stringify(check.totals))}`);
  const kimiChecks = report.results.find(row => row.source === 'kimi')?.cross_checks ?? [];
  if (kimiChecks.length) {
    const measured = kimiChecks.filter(row => row.type === 'measured_total');
    lines.push('', '## Kimi Code 客户端自测总量', '', '每条 usage.record 与同一 agent、同一时刻的 token_counting.measured 配对：四项之和等于客户端自测的 tokens，说明四项互不重叠。', '',
      `配对 ${measured.length} 条，相等 ${measured.filter(row => row.ok).length} 条，不等 ${measured.filter(row => row.ok === false).length} 条；没有配对的 usage.record ${kimiChecks.filter(row => row.type === 'measured_missing').length} 条。`, '');
    for (const check of measured.filter(row => !row.ok)) lines.push(`- ${code(check.file)}:${check.line} 四项之和 ${check.sum}，自测 ${check.measured}`);
  }
  lines.push('', '## 规格偏差、解析问题与未知字段', '');
  for (const result of report.results) {
    const unknown = fields.map(field => `${field}=${result.sessions.reduce((n, row) => n + row.unknown[field], 0)}`).join('，');
    lines.push(`### ${result.source}`, '', `未知条数：${unknown}。`, '');
    for (const issue of result.issues) lines.push(`- ${code(issue.type)} ${code(issue.file)}:${issue.line ?? '?'} ${code(JSON.stringify(issue))}`);
    lines.push(`去重：文件内快照 ${result.duplicates.filter(row => row.type === 'snapshot').length}；跨文件复制 ${result.duplicates.filter(row => row.type === 'cross_file_copy').length}。`, '');
  }
  lines.push('## A3 定位与边界', '',
    'pi、dsh 的历史总量与另一种计算方式有差异，尚未定位。缺少历史逐文件与 30 分钟桶证据，当前核对结果不能证明历史 A3 差异已经消除。', '',
    'diff.json 的 a3 保存本次 pi/dsh 每文件、每会话、每 30 分钟桶及条目行号。DSH 是整场累计，桶仅标记最后活动时间，不代表该半小时实际消耗。Pi 不同会话同 ID/时间/四项 token 的候选复制单独列出，不凭短 ID 直接删数。', '');
  const piResult = report.results.find(row => row.source === 'pi');
  lines.push(`本次 Pi 跨会话完全相同条目的候选组：${piResult?.copy_candidates?.length ?? 0}。`, '');
  for (const rows of piResult?.copy_candidates ?? []) lines.push(`- ${rows.map(row => `${code(row.file)}:${row.line} ${code(row.session_id)} / ${code(row.raw.id)}`).join('；')}`);
  const dshFiles = report.dsh_file_comparison;
  lines.push('', `DSH 按同一物理文件补充核对：${dshFiles.filter(row => row.equal).length}/${dshFiles.length} 份四项 token 一致；${dshFiles.filter(row => row.only_zero).length} 份明确全零未入库。此项不替换上面的严格会话名比较。`, '');
  for (const row of dshFiles) lines.push(`- ${code(row.file)}:1：oracle 会话=${code(row.oracle.session_id)}；账本会话=${code(row.ledger?.session_id)}；${row.equal ? 'token 相同' : row.only_zero ? '全零，未入库' : '未定位差异'}`);
  lines.push('', '规格停止项：Qwen 的 thoughts 包含关系、Codex 新缓存写字段和累计不一致、DSH 文件名前缀均已登记，未猜测更改 oracle 口径，也未修改适配器。Pi 深层目录递归扫描与当前日志布局一致；历史扫描范围与分桶证据不足，覆盖差异尚未定位。', '');
  lines.push('', '## 采集范围与隔离证据', '',
    `临时 HOME：${code(report.runtime.home)}；cwd：${code(report.runtime.cwd)}；TEMP/TMP：${code(report.runtime.temp)}。DB_PATH 清除；内核只收到显式临时 dataDir。`, '',
    '只发现五个指定工具的日志路径，未发现或打开已安装账本。临时目录及冻结副本保留作复核，不自动删除；其内容可能含会话正文。', '',
    `采集结果：${code(JSON.stringify(report.ingestion))}`, '',
    '原始文件路径、字节数、SHA-256、采集期间是否变化，以及运行后是否变化，完整保存在 diff.json.manifest。两套实现比较冻结副本；运行后原日志变化不影响这次对账，但新内容不在覆盖范围。', '');
  const changed = report.manifest.filter(row => row.capture_changed || row.changed_after_capture);
  for (const row of changed) lines.push(`- 运行期间变化：${code(row.original)}；采集时变化=${row.capture_changed}；采集后变化=${row.changed_after_capture}`);
  return lines.join('\n');
}

export async function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  const originalHome = homedir();
  validatePaths(options, originalHome);
  const runtime = isolate(options.dataDir);
  const manifest = freezeLogs(options.sources, originalHome, runtime.home);
  const { runIngestion } = await import('../../src/core/ingest.js');
  const ingestion = await runIngestion({ dataDir: options.dataDir });
  const results = [];
  for (const source of options.sources) results.push(await oracles[source]({ home: runtime.home }));
  const rows = ledgerEntries(options.dataDir);
  const sessions = compareSessions(results.flatMap(result => result.sessions), aggregate(rows));
  for (const session of sessions) if (!session.equal) session.entries = entryDetails(results.find(row => row.source === session.source), rows, session);
  for (const row of manifest) {
    try { row.changed_after_capture = hash(readFileSync(row.original)) !== row.sha256; }
    catch { row.changed_after_capture = true; }
  }
  const summary = results.map(result => {
    const selected = sessions.filter(row => row.source === result.source);
    const equal = selected.filter(row => row.equal).length;
    return { source: result.source, files: result.files.length, sessions: selected.length, equal,
      ratio: selected.length ? equal / selected.length : null, oracle_records: result.entries.length,
      ledger_records: rows.filter(row => row.source === result.source).length };
  });
  const report = { schema_version: 1, generated_at: new Date().toISOString(), node_version: process.version, data_dir: options.dataDir,
    runtime, ingestion, summary, sessions, results, manifest, ledger_entries: rows,
    dsh_file_comparison: results.some(row => row.source === 'dsh') ? fileComparison(results.find(row => row.source === 'dsh'), rows) : [],
    codex_session_checks: codexSessions(results.find(row => row.source === 'codex')),
    a3: Object.fromEntries(results.filter(row => ['pi', 'dsh'].includes(row.source)).map(row => [row.source, buckets(row.entries)])) };
  // Report evidence points back to original files; the manifest retains both paths.
  const originals = new Map(manifest.map(row => [row.file, row.original]));
  const external = JSON.parse(JSON.stringify(report, (key, value) => key !== 'runtime' && typeof value === 'string' && originals.has(value) ? originals.get(value) : value));
  external.manifest = manifest;
  mkdirSync(options.out, { recursive: true });
  writeFileSync(join(options.out, 'diff.json'), JSON.stringify(external, null, 2) + '\n');
  writeFileSync(join(options.out, 'report.md'), renderReport(external));
  process.stdout.write(JSON.stringify({ out: options.out, summary }, null, 2) + '\n');
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
