#!/usr/bin/env node
/**
 * 对账台：同一批原始日志，用解析器独立重放一遍，和账本里存的数比。
 *
 * 三层证据：
 *   1. 不变量   —— 账本自己是否自洽（身份唯一、四类 token 不重叠、累计型不越界）
 *   2. 重放     —— 原始日志 → 解析器 → 按入库规则重放，结果是否等于账本
 *   3. 抽样     —— 每个来源的原始行与解析结果并排，供人工核对字段语义
 *
 * 只读账本与日志，不写库。报告写到工作区外。
 *
 * 用法：
 *   node scripts/audit/reconcile.mjs --out <path> [--source claude,codex] [--limit 3] [--data-dir <dir>]
 */

import { DatabaseSync } from 'node:sqlite';
import { join, resolve } from 'node:path';
import { mkdirSync, writeFileSync } from 'node:fs';

import { discoverAll } from '../../src/core/discovery.js';
import { adapters } from '../../src/core/adapters/index.js';
import { resolveDataDir } from '../../src/core/paths.js';
import { payloadHash } from '../../src/core/db/write.js';

const TOKEN_FIELDS = ['input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens'];

/**
 * @param {string[]} argv
 * @returns {{ sources: string[]|null, limit: number, out: string|null, dataDir: string|null }}
 */
function parseArgs(argv) {
  const out = { sources: null, limit: 3, out: null, dataDir: null };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--source') {
      out.sources = String(argv[++i] || '').split(',').map((s) => s.trim()).filter(Boolean);
    } else if (arg === '--limit') {
      out.limit = Math.max(1, Number(argv[++i]) || 3);
    } else if (arg === '--out') {
      out.out = argv[++i] || null;
    } else if (arg === '--data-dir') {
      out.dataDir = argv[++i] || null;
    }
  }
  return out;
}

/**
 * 只取落库用得到的字段，便于比较。
 *
 * @param {Object} r
 * @returns {Object}
 */
function snapshot(r) {
  const out = {
    model: r.model ?? null,
    project_key: r.project_key ?? null,
    session_id: r.session_id ?? null,
    observed_at: r.observed_at ?? null
  };
  for (const field of TOKEN_FIELDS) out[field] = r[field] ?? null;
  return out;
}

/** @param {Object} r */
function grossOf(r) {
  return TOKEN_FIELDS.reduce((sum, field) => sum + (r[field] == null ? 0 : Number(r[field])), 0);
}

/**
 * 按账本的入库规则重放一遍。
 *
 * 与 `ledger.write.ingestBatch` 同规则，但完全不碰数据库：
 * 新身份插入；内容指纹相同只有项目归属可变；累计型下降保留旧值并记异常。
 *
 * @param {Iterable<Object>} records
 */
function replay(records) {
  const state = new Map();
  const stats = { attempted: 0, inserted: 0, updated: 0, unchanged: 0, relabeled: 0, rejected: 0, anomalies: [] };

  for (const r of records) {
    stats.attempted += 1;

    if (!r || !r.record_key || !r.source || !r.observed_at) {
      stats.rejected += 1;
      stats.anomalies.push(`rejected: ${r && r.record_key ? r.record_key : '(no key)'}`);
      continue;
    }

    const kind = r.kind || 'event';
    const hash = payloadHash({ ...r, kind });
    const previous = state.get(r.record_key);

    if (!previous) {
      state.set(r.record_key, { ...snapshot(r), hash, kind });
      stats.inserted += 1;
      continue;
    }

    if (previous.hash === hash) {
      const nextProject = r.project_key ?? null;
      if (nextProject !== null && nextProject !== previous.project_key) {
        previous.project_key = nextProject;
        stats.relabeled += 1;
        continue;
      }
      stats.unchanged += 1;
      continue;
    }

    if (previous.kind === 'cumulative' && grossOf(r) < grossOf(previous)) {
      stats.anomalies.push(`cumulative_decrease: ${r.record_key}`);
      continue;
    }

    Object.assign(previous, snapshot(r), { hash });
    stats.updated += 1;
  }

  return { state, stats };
}

/**
 * @param {DatabaseSync} db
 * @param {string} source
 * @returns {{ rows: Object[], watermark: string|null }}
 */
function ledgerRowsOf(db, source) {
  const rows = db.prepare(`
    SELECT record_key, content_hash, kind, model, session_id, project_key, observed_at,
           input_tokens, output_tokens, cache_read_tokens, cache_write_tokens
    FROM usage_records
    WHERE active = 1 AND source = ?
  `).all(source);
  const max = db.prepare(`
    SELECT max(observed_at) AS m FROM usage_records WHERE active = 1 AND source = ?
  `).get(source);
  return { rows, watermark: max?.m || null };
}

/**
 * 账本内部不变量。每条都返回可判定的数字，不做解释。
 *
 * @param {DatabaseSync} db
 * @returns {Array<{ name: string, value: number, ok: boolean, note: string }>}
 */
function invariants(db) {
  const checks = [];

  const dupKeys = db.prepare(`
    SELECT count(*) AS c FROM (
      SELECT record_key FROM usage_records GROUP BY record_key HAVING count(*) > 1
    )
  `).get();
  checks.push({
    name: 'record_key 唯一',
    value: Number(dupKeys?.c || 0),
    ok: Number(dupKeys?.c || 0) === 0,
    note: '同一身份不得有两行'
  });

  const mixed = db.prepare(`
    SELECT count(*) AS c FROM (
      SELECT source, session_id FROM usage_records
      WHERE active = 1 AND session_id IS NOT NULL
      GROUP BY source, session_id HAVING count(DISTINCT kind) > 1
    )
  `).get();
  checks.push({
    name: '同一会话不混用事件型与累计型',
    value: Number(mixed?.c || 0),
    ok: Number(mixed?.c || 0) === 0,
    note: '混用会重复计数'
  });

  const inactive = db.prepare('SELECT count(*) AS c FROM usage_records WHERE active != 1').get();
  checks.push({
    name: '没有非活跃行',
    value: Number(inactive?.c || 0),
    ok: Number(inactive?.c || 0) === 0,
    note: '当前只有 active = 1 的写入路径'
  });

  const negative = db.prepare(`
    SELECT count(*) AS c FROM usage_records
    WHERE input_tokens < 0 OR output_tokens < 0 OR cache_read_tokens < 0 OR cache_write_tokens < 0
  `).get();
  checks.push({
    name: '没有负数 token',
    value: Number(negative?.c || 0),
    ok: Number(negative?.c || 0) === 0,
    note: '负数会污染所有聚合'
  });

  const kinds = db.prepare(`
    SELECT count(*) AS c FROM usage_records WHERE kind NOT IN ('event','cumulative')
  `).get();
  checks.push({
    name: 'kind 取值合法',
    value: Number(kinds?.c || 0),
    ok: Number(kinds?.c || 0) === 0,
    note: "只允许 event / cumulative"
  });

  return checks;
}

/**
 * 逐条比较重放结果与账本。
 *
 * 「重放有、账本没有」要分两种：晚于账本水位 = 还没采集；早于水位 = 真漏采。
 * 前者是账本过期，后者才是解析或入库的缺陷。
 *
 * @param {Map<string, Object>} state
 * @param {Object[]} rows
 * @param {string|null} watermark 账本里该来源最新的 observed_at
 */
function compare(state, rows, watermark) {
  const ledgerByKey = new Map(rows.map((row) => [row.record_key, row]));
  const onlyInLedger = [];
  const notIngested = [];
  const missed = [];
  const tokenDiffs = [];
  const modelDiffs = [];
  const projectDiffs = [];

  for (const [key, row] of ledgerByKey) {
    const replayed = state.get(key);
    if (!replayed) {
      onlyInLedger.push(key);
      continue;
    }
    for (const field of TOKEN_FIELDS) {
      const a = row[field] ?? null;
      const b = replayed[field] ?? null;
      if (a !== b) tokenDiffs.push(`${key} ${field}: 账本=${a} 重放=${b}`);
    }
    if ((row.model ?? null) !== (replayed.model ?? null)) {
      modelDiffs.push(`${key} model: 账本=${row.model} 重放=${replayed.model}`);
    }
    if ((row.project_key ?? null) !== (replayed.project_key ?? null)) {
      projectDiffs.push(`${key} project: 账本=${row.project_key} 重放=${replayed.project_key}`);
    }
  }

  for (const [key, replayed] of state) {
    if (ledgerByKey.has(key)) continue;
    const seenAt = replayed.observed_at || '';
    if (watermark && seenAt > watermark) notIngested.push(key);
    else missed.push(key);
  }

  const sumLedger = rows.reduce((acc, row) => {
    for (const field of TOKEN_FIELDS) acc[field] += Number(row[field] || 0);
    return acc;
  }, { input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0 });

  const sumReplay = [...state.values()].reduce((acc, row) => {
    for (const field of TOKEN_FIELDS) acc[field] += Number(row[field] || 0);
    return acc;
  }, { input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0 });

  return { onlyInLedger, notIngested, missed, tokenDiffs, modelDiffs, projectDiffs, sumLedger, sumReplay };
}

/**
 * 取原始文件的一段，供人工对照字段语义。
 *
 * @param {string} filePath
 * @param {number} maxChars
 * @returns {string}
 */
async function rawSample(filePath, maxChars = 600) {
  if (/\.zst$/i.test(filePath)) return '（zstd 压缩帧；字段语义见 specs/log-schemas.yaml）';

  const { open } = await import('node:fs/promises');
  const handle = await open(filePath, 'r');
  try {
    const buffer = Buffer.alloc(maxChars * 4);
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
    const text = buffer.subarray(0, bytesRead).toString('utf8').replace(/\s+/g, ' ').trim();
    return text.slice(0, maxChars);
  } finally {
    await handle.close();
  }
}

/**
 * @param {Object} options
 * @returns {Promise<Object>}
 */
async function auditSource(source, files, db, sampleLimit) {
  const parser = adapters[source];
  const started = Date.now();

  /** @type {Object[]} */
  const collected = [];
  const readErrors = [];

  for (const file of files) {
    try {
      for await (const record of parser(file)) collected.push(record);
    } catch (err) {
      readErrors.push(`${file}: ${err.message}`);
    }
  }

  const { state, stats } = replay(collected);
  const { rows, watermark } = ledgerRowsOf(db, source);
  const diff = compare(state, rows, watermark);

  const sample = [];
  for (const file of files.slice(0, sampleLimit)) {
    sample.push({ file, raw: await rawSample(file) });
  }

  // 账本有、重放没有：日志可能已经被删。只有源文件仍在时才可疑，
  // 所以这里算「不可验证」，不算不一致。
  const verifiable = state.size;
  const coverage = rows.length > 0 ? verifiable / rows.length : 0;

  return {
    source,
    watermark,
    fileCount: files.length,
    parsed: collected.length,
    replayed: state.size,
    ledger: rows.length,
    coverage,
    stats,
    readErrors,
    diff,
    sample,
    durationMs: Date.now() - started
  };
}

/** @param {number} n */
function fmt(n) {
  return Number(n || 0).toLocaleString('en-US');
}

/**
 * @param {Object[]} results
 * @param {Array<Object>} checks
 * @param {string} ledgerPath
 * @returns {string}
 */
function renderReport(results, checks, ledgerPath) {
  const now = new Date().toISOString();
  const lines = [];

  lines.push(`# 对账报告 ${now.slice(0, 10)}`);
  lines.push('');
  lines.push(`- 账本：\`${ledgerPath}\``);
  lines.push(`- 生成时间：${now}`);
  lines.push(`- 覆盖来源：${results.map((r) => r.source).join('、')}`);
  lines.push('');

  lines.push('## 一、账本不变量');
  lines.push('');
  lines.push('| 检查 | 值 | 结论 | 说明 |');
  lines.push('|---|---:|---|---|');
  for (const check of checks) {
    lines.push(`| ${check.name} | ${fmt(check.value)} | ${check.ok ? '通过' : '**失败**'} | ${check.note} |`);
  }
  lines.push('');

  lines.push('## 二、重放一致性');
  lines.push('');
  lines.push('读法：本节的「一致」只证明**入库无损**——同一解析器重放一遍，结果与账本逐条相同，');
  lines.push('说明去重、覆盖、累计型分流没有漂移。它**不证明字段语义正确**：解析器与账本出自同一份代码，');
  lines.push('口径错了两边会一起错。字段语义靠第五节抽样对照厂商文档。');
  lines.push('');
  lines.push('「不一致」= 同一身份两边 token/model/项目不同，或重放有而账本没有且时间早于账本水位（真漏采）。');
  lines.push('「未采集」= 重放有、账本没有，但时间晚于账本水位，即账本还没扫到。');
  lines.push('「不可验证」= 账本有但源日志已不在本机。');
  lines.push('');
  lines.push('| 来源 | 文件 | 解析 | 重放 | 账本 | 可验证覆盖 | 账本水位 | 不一致 | 未采集 | 不可验证 |');
  lines.push('|---|---:|---:|---:|---:|---:|---|---:|---:|---:|');
  for (const r of results) {
    const mismatched = r.diff.tokenDiffs.length + r.diff.modelDiffs.length + r.diff.projectDiffs.length + r.diff.missed.length;
    lines.push(
      `| ${r.source} | ${fmt(r.fileCount)} | ${fmt(r.parsed)} | ${fmt(r.replayed)} | ${fmt(r.ledger)} | ` +
      `${(r.coverage * 100).toFixed(1)}% | ${r.watermark || '—'} | ${fmt(mismatched)} | ` +
      `${fmt(r.diff.notIngested.length)} | ${fmt(r.diff.onlyInLedger.length)} |`
    );
  }
  lines.push('');

  lines.push('### 分项合计对照');
  lines.push('');
  lines.push('| 来源 | 口径 | input | output | cache_read | cache_write |');
  lines.push('|---|---|---:|---:|---:|---:|');
  for (const r of results) {
    lines.push(`| ${r.source} | 账本 | ${fmt(r.diff.sumLedger.input_tokens)} | ${fmt(r.diff.sumLedger.output_tokens)} | ${fmt(r.diff.sumLedger.cache_read_tokens)} | ${fmt(r.diff.sumLedger.cache_write_tokens)} |`);
    lines.push(`| ${r.source} | 重放 | ${fmt(r.diff.sumReplay.input_tokens)} | ${fmt(r.diff.sumReplay.output_tokens)} | ${fmt(r.diff.sumReplay.cache_read_tokens)} | ${fmt(r.diff.sumReplay.cache_write_tokens)} |`);
  }
  lines.push('');

  const detail = [];
  for (const r of results) {
    if (r.diff.tokenDiffs.length) detail.push(`**${r.source} token 差异**\n\n\`\`\`\n${r.diff.tokenDiffs.slice(0, 20).join('\n')}\n\`\`\``);
    if (r.diff.modelDiffs.length) detail.push(`**${r.source} model 差异**\n\n\`\`\`\n${r.diff.modelDiffs.slice(0, 20).join('\n')}\n\`\`\``);
    if (r.diff.projectDiffs.length) detail.push(`**${r.source} 项目归属差异**\n\n\`\`\`\n${r.diff.projectDiffs.slice(0, 20).join('\n')}\n\`\`\``);
    if (r.diff.missed.length) detail.push(`**${r.source} 漏采（早于账本水位却没入库）**\n\n\`\`\`\n${r.diff.missed.slice(0, 20).join('\n')}\n\`\`\``);
    if (r.stats.anomalies.length) detail.push(`**${r.source} 重放异常**\n\n\`\`\`\n${r.stats.anomalies.slice(0, 20).join('\n')}\n\`\`\``);
    if (r.readErrors.length) detail.push(`**${r.source} 读取失败**\n\n\`\`\`\n${r.readErrors.slice(0, 10).join('\n')}\n\`\`\``);
  }
  lines.push('## 三、差异明细');
  lines.push('');
  if (detail.length) {
    lines.push(detail.join('\n\n'));
  } else {
    lines.push('无。所有来源的 token、model、项目归属逐条一致，也没有真漏采。');
  }
  lines.push('');

  lines.push('## 四、未采集与不可验证');
  lines.push('');
  lines.push('「未采集」是账本落后于磁盘，跑一次采集即归零，不是缺陷。');
  lines.push('「不可验证」是账本里有、源日志已不在本机——日志被删的那一刻起，这些记录就成了孤证。');
  lines.push('');
  for (const r of results) {
    const parts = [];
    if (r.diff.notIngested.length) parts.push(`未采集 ${fmt(r.diff.notIngested.length)} 条`);
    if (r.diff.onlyInLedger.length) parts.push(`不可验证 ${fmt(r.diff.onlyInLedger.length)} 条（示例 ${r.diff.onlyInLedger.slice(0, 3).map((k) => `\`${k}\``).join('、')}）`);
    if (parts.length) lines.push(`- ${r.source}：${parts.join('；')}`);
  }
  lines.push('');

  lines.push('## 五、字段抽样（人工核对用）');
  lines.push('');
  lines.push('每个来源取前几个原始文件的开头一段。核对方式：按 `specs/log-schemas.yaml` 记录的字段位置，');
  lines.push('对着这段原始内容手算四类 token，与账本里同一 `record_key` 的四列比。对不上就是口径问题。');
  lines.push('');
  for (const r of results) {
    if (!r.sample.length) continue;
    lines.push(`### ${r.source}`);
    lines.push('');
    for (const s of r.sample) {
      lines.push(`文件：\`${s.file}\``);
      lines.push('');
      lines.push('```');
      lines.push(s.raw);
      lines.push('```');
      lines.push('');
    }
  }

  return lines.join('\n');
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.out) {
    throw new Error('缺少 --out <path>：报告要写到仓库以外的位置。');
  }
  const paths = resolveDataDir({ dataDir: args.dataDir || undefined });
  const ledgerPath = paths.ledgerPath;

  const db = new DatabaseSync(ledgerPath, { readOnly: true });
  let discovered;
  try {
    discovered = discoverAll();
  } catch (err) {
    db.close();
    throw err;
  }

  const allSources = Object.keys(adapters);
  const wanted = args.sources || allSources;
  const results = [];
  const checks = invariants(db);

  try {
    for (const source of wanted) {
      const files = discovered[source] || [];
      if (!files.length) {
        process.stderr.write(`[skip] ${source}: 本机没有发现日志\n`);
        continue;
      }
      process.stderr.write(`[run ] ${source}: ${files.length} 个文件…\n`);
      const result = await auditSource(source, files, db, args.limit);
      results.push(result);
      process.stderr.write(
        `[done] ${source}: 解析 ${fmt(result.parsed)} / 重放 ${fmt(result.replayed)} / 账本 ${fmt(result.ledger)} ` +
        `/ token差异 ${result.diff.tokenDiffs.length} / ${(result.durationMs / 1000).toFixed(1)}s\n`
      );
    }
  } finally {
    db.close();
  }

  const report = renderReport(results, checks, ledgerPath);
  const outPath = resolve(args.out);

  mkdirSync(join(outPath, '..'), { recursive: true });
  writeFileSync(outPath, report, 'utf8');

  process.stdout.write(`\n报告：${outPath}\n`);
  const failed = checks.filter((c) => !c.ok);
  process.stdout.write(`不变量：${checks.length - failed.length}/${checks.length} 通过\n`);
  for (const r of results) {
    const bad = r.diff.tokenDiffs.length + r.diff.modelDiffs.length + r.diff.projectDiffs.length + r.diff.missed.length;
    process.stdout.write(
      `${r.source}: ${bad === 0 ? '一致' : `${bad} 处不一致`}` +
      `，未采集 ${r.diff.notIngested.length}，不可验证 ${r.diff.onlyInLedger.length}` +
      `，可验证覆盖 ${(r.coverage * 100).toFixed(1)}%\n`
    );
  }
}

main().catch((err) => {
  console.error('对账失败：', err);
  process.exit(1);
});
