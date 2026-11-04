import { createHash } from 'node:crypto';

/**
 * 允许的 token 字段。缺失即 null（未知），不是 0。
 */
const TOKEN_FIELDS = ['input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens'];

const KINDS = new Set(['event', 'cumulative']);

const SPLIT_FIELDS = ['cache_write_5m_tokens', 'cache_write_1h_tokens'];

/** 没有登记版本的历史行（schema v4 之前入库）按第 1 版解析器产出处理。 */
const BASELINE_REV = 1;

/**
 * 内容指纹：只描述「这条记录现在说的是什么」，不参与身份判定。
 * 覆盖影响统计、时间归属与缓存分档计价的全部字段，任何一项变了都要写回。
 *
 * @param {Object} r
 * @returns {string}
 */
export function payloadHash(r) {
  const known = (v) => (v === null || v === undefined ? 'null' : Number(v));
  const fields = [
    r.kind || 'event',
    r.model || '',
    ...TOKEN_FIELDS.map((f) => known(r[f])),
    r.observed_at || '',
    r.ended_at || '',
    r.session_id || '',
    ...SPLIT_FIELDS.map((f) => known(r[f]))
  ];
  // NULL 的输入与 v4 逐字相同，避免未知提供方使全部旧行增加 revision。
  if (r.provider != null) fields.push(r.provider);
  const canonical = fields.join('\x1f');
  return createHash('sha256').update(canonical).digest('hex').slice(0, 32);
}

/** @returns {Object} 一次写入里按类计数的空计数器 */
function emptyCounts() {
  return {
    relabeled: 0, reactivated: 0, replaced: 0,
    deactivated: 0, vanished: 0, rev_corrections: 0, cumulative_decrease: 0
  };
}

/**
 * 比较用的总量：未知按 0 计，仅用于判断累计值是涨是跌。
 *
 * @param {Object} r
 * @returns {number}
 */
function grossOf(r) {
  return TOKEN_FIELDS.reduce((sum, f) => sum + (r[f] == null ? 0 : Number(r[f])), 0);
}

/**
 * @param {Object} r
 * @returns {string|null} 不合格原因，null 表示合格
 */
function validate(r) {
  if (!r || typeof r !== 'object') return 'record 不是对象';
  if (!r.source) return '缺少 source';
  if (!r.record_key) return '缺少 record_key（无稳定身份不得入库）';
  if (!r.observed_at) return '缺少 observed_at';
  if (r.provider != null && typeof r.provider !== 'string') return 'provider 不是字符串';
  if (r.ended_at !== null && r.ended_at !== undefined && typeof r.ended_at !== 'string') {
    return `ended_at 不是时间字符串：${r.ended_at}`;
  }
  if (!KINDS.has(r.kind || 'event')) return `kind 非法：${r.kind}`;
  for (const f of TOKEN_FIELDS) {
    const v = r[f];
    if (v === null || v === undefined) continue;
    if (!Number.isInteger(v) || v < 0) return `${f} 不是非负整数：${v}`;
  }
  return null;
}

/** 写入与事务；连接由 Ledger 所有者关闭。 */
export class LedgerWriter {
  #db;
  #selectKey;
  #insert;
  #update;
  #relabel;
  #touch;
  #reactivate;
  #supersede;
  #deactivate;
  #fileRows;
  #insertLegacy;
  #runStart;
  #runFinish;
  #runAbandon;
  #runFail;

  /**
   * @param {import('node:sqlite').DatabaseSync} db 由 Ledger 所有者管理的连接
   */
  constructor(db) {
    this.#db = db;

    this.#selectKey = this.#db.prepare(`
      SELECT id, revision, content_hash, kind, project_key, ended_at, active, superseded_by,
             source_file, parser_rev,
             input_tokens, output_tokens, cache_read_tokens, cache_write_tokens
      FROM usage_records
      WHERE record_key = ?
    `);

    this.#insert = this.#db.prepare(`
      INSERT INTO usage_records
        (record_key, content_hash, source, session_id, project_key, model, provider, observed_at, ended_at, kind,
         input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
         cache_write_5m_tokens, cache_write_1h_tokens,
         active, revision, price_version, cost_micros, price_source, source_file, parser_rev)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1,1,?,?,?,?,?)
    `);

    // 内容没变，只登记这次是从哪个文件、哪版解析器读到的
    this.#touch = this.#db.prepare(`
      UPDATE usage_records SET source_file = ?, parser_rev = ? WHERE id = ?
    `);

    // 曾因口径修正停用、现在又被产出的行：恢复计入
    this.#reactivate = this.#db.prepare(`
      UPDATE usage_records SET active = 1 WHERE id = ? AND superseded_by IS NULL
    `);

    // 身份规则变化：旧键的行停用，并指向接替它的新行
    this.#supersede = this.#db.prepare(`
      UPDATE usage_records SET active = 0, superseded_by = ? WHERE id = ? AND active = 1
    `);

    this.#deactivate = this.#db.prepare(`
      UPDATE usage_records SET active = 0 WHERE id = ? AND active = 1
    `);

    this.#fileRows = this.#db.prepare(`
      SELECT id, record_key, parser_rev FROM usage_records WHERE source_file = ? AND active = 1
    `);

    // 只改归属、不动用量事实：内容未变但项目识别结果变了时用
    this.#relabel = this.#db.prepare(`
      UPDATE usage_records SET project_key = ? WHERE id = ?
    `);

    // 项目与最后活动时间只在这次读到了值时覆盖：解析器这次没给出，不等于原来的值作废
    this.#update = this.#db.prepare(`
      UPDATE usage_records
      SET content_hash = ?, kind = ?,
          session_id = ?, project_key = coalesce(?, project_key), model = ?, provider = ?, observed_at = ?,
          ended_at = coalesce(?, ended_at),
          input_tokens = ?, output_tokens = ?, cache_read_tokens = ?, cache_write_tokens = ?,
          cache_write_5m_tokens = ?, cache_write_1h_tokens = ?,
          revision = revision + 1,
          price_version = ?, cost_micros = ?, price_source = ?,
          source_file = coalesce(?, source_file), parser_rev = coalesce(?, parser_rev)
      WHERE id = ?
    `);

    this.#runStart = this.#db.prepare(`
      INSERT INTO ingest_runs (started_at, status) VALUES (?, 'running')
    `);

    // 上一次运行没走到收尾（进程被杀）：采集持有跨进程锁，此刻不可能还有别的运行
    this.#runAbandon = this.#db.prepare(`
      UPDATE ingest_runs SET status = 'abandoned' WHERE status = 'running'
    `);

    this.#runFail = this.#db.prepare(`
      UPDATE ingest_runs SET finished_at = ?, status = 'failed', notes = ? WHERE id = ?
    `);

    this.#insertLegacy = this.#db.prepare(`
      INSERT INTO legacy_records
        (origin_row_id, content_hash, source, session_id, model, timestamp,
         input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, estimated_cost)
      VALUES (?,?,?,?,?,?,?,?,?,?,?)
    `);

    this.#runFinish = this.#db.prepare(`
      UPDATE ingest_runs
      SET finished_at = ?, status = ?, attempted = ?, inserted = ?, updated = ?,
          unchanged = ?, rejected = ?, notes = ?, counts = ?
      WHERE id = ?
    `);
  }

  /**
   * 价格由调用方注入，账本不 import 定价模块，避免形成循环。
   *
   * 给出 `sourceFile` 时，这批记录就是该文件这次完整解析的全部产出：
   * 该文件名下、本次没有再产出的活跃行，若由另一版解析器产出则停用（口径修正）；
   * 同一版解析器下消失的只计为 vanished 并上报，用量照常保留——客户端自己清理日志不等于用量没发生。
   * 一条都没产出的文件不做这一步，因为分不清「文件真的空了」与「适配器把读取失败吞掉了」。
   *
   * 记录可带 `replaces: string[]`：身份规则变了，旧键的行停用并指向新行。
   *
   * `elsewhere` 是该文件这次也产出了、但归另一个文件写入的键（跨文件复制的同一条记录及其 replaces），
   * 对这个文件来说同样算产出过，不会被当作消失。
   *
   * @param {Object} [options]
   * @param {(r: Object) => ({ cost_micros: number|null, price_version: string|null, price_source: string|null }|null)} [options.priceOf]
   * @param {string} [options.sourceFile] 这批记录来自的日志文件
   * @param {number} [options.parserRev] 产出这批记录的适配器版本
   * @param {Set<string>} [options.elsewhere] 该文件产出、但由别的文件写入的键
   * @returns {{ attempted: number, inserted: number, updated: number, unchanged: number, rejected: number, counts: Object, anomalies: string[] }}
   */
  ingestBatch(records, options = {}) {
    const priceOf = options.priceOf || (() => null);
    const sourceFile = options.sourceFile ?? null;
    const parserRev = options.parserRev ?? null;
    const elsewhere = options.elsewhere ?? new Set();
    const stats = { attempted: 0, inserted: 0, updated: 0, unchanged: 0, rejected: 0, counts: emptyCounts(), anomalies: [] };
    const counts = stats.counts;
    const produced = new Set();

    this.#db.exec('BEGIN IMMEDIATE');
    try {
      for (const r of records) {
        stats.attempted += 1;
        if (r?.record_key) produced.add(r.record_key);

        const reason = validate(r);
        if (reason) {
          stats.rejected += 1;
          stats.anomalies.push(`rejected: ${r?.record_key || '(no key)'} — ${reason}`);
          continue;
        }

        const kind = r.kind || 'event';
        const hash = payloadHash({ ...r, kind });
        const existing = this.#selectKey.get(r.record_key);
        const price = priceOf(r) || { cost_micros: null, price_version: null, price_source: null };

        if (!existing) {
          const info = this.#insert.run(
            r.record_key, hash, r.source, r.session_id ?? null, r.project_key ?? null,
            r.model ?? null, r.provider ?? null, r.observed_at, r.ended_at ?? null, kind,
            r.input_tokens ?? null, r.output_tokens ?? null,
            r.cache_read_tokens ?? null, r.cache_write_tokens ?? null,
            r.cache_write_5m_tokens ?? null, r.cache_write_1h_tokens ?? null,
            price.price_version, price.cost_micros, price.price_source,
            sourceFile, parserRev
          );
          stats.inserted += 1;
          this.#supersedeOld(r, Number(info.lastInsertRowid), stats);
          continue;
        }

        if (!existing.active) {
          if (existing.superseded_by !== null) {
            // 旧键已被新身份接替，又被产出说明新旧解析器同时在跑，不能两边都计
            stats.anomalies.push(`superseded_reproduced: ${r.record_key}`);
            continue;
          }
          this.#reactivate.run(existing.id);
          counts.reactivated += 1;
        }

        if (existing.content_hash === hash) {
          // 用量与时间都没变，但归属可能刚被识别出来（例如适配器这次才拿到 cwd）。
          // 最后活动时间在内容指纹里，回填它走下面的更新路径
          let touched = false;
          const nextProject = r.project_key ?? null;
          if (nextProject !== null && nextProject !== existing.project_key) {
            this.#relabel.run(nextProject, existing.id);
            counts.relabeled += 1;
            touched = true;
          }
          if ((sourceFile !== null && sourceFile !== existing.source_file) ||
              (parserRev !== null && parserRev !== existing.parser_rev)) {
            this.#touch.run(sourceFile ?? existing.source_file, parserRev ?? existing.parser_rev, existing.id);
          }
          if (!touched) stats.unchanged += 1;
          this.#supersedeOld(r, existing.id, stats);
          continue;
        }

        if (existing.kind === 'cumulative') {
          const previousGross = TOKEN_FIELDS.reduce((s, f) => s + (existing[f] == null ? 0 : Number(existing[f])), 0);
          const nextGross = grossOf(r);
          if (nextGross < previousGross) {
            if (parserRev !== null && parserRev !== (existing.parser_rev ?? BASELINE_REV)) {
              // 解析器版本变了：下降来自口径修正，接受新值
              counts.rev_corrections += 1;
            } else {
              // 同一版解析器读到累计值下降：不覆盖、不静默，保留旧值并上报
              counts.cumulative_decrease += 1;
              stats.anomalies.push(
                `cumulative_decrease: ${r.record_key} — ${previousGross} → ${nextGross}`
              );
              continue;
            }
          }
        }

        this.#update.run(
          hash, kind, r.session_id ?? null, r.project_key ?? null, r.model ?? null, r.provider ?? null, r.observed_at,
          r.ended_at ?? null,
          r.input_tokens ?? null, r.output_tokens ?? null,
          r.cache_read_tokens ?? null, r.cache_write_tokens ?? null,
          r.cache_write_5m_tokens ?? null, r.cache_write_1h_tokens ?? null,
          price.price_version, price.cost_micros, price.price_source,
          sourceFile, parserRev,
          existing.id
        );
        stats.updated += 1;
        this.#supersedeOld(r, existing.id, stats);
      }

      if (sourceFile !== null && (produced.size > 0 || elsewhere.size > 0)) {
        let vanished = 0;
        for (const row of this.#fileRows.all(sourceFile)) {
          if (produced.has(row.record_key) || elsewhere.has(row.record_key)) continue;
          if (parserRev !== null && (row.parser_rev ?? BASELINE_REV) !== parserRev) {
            this.#deactivate.run(row.id);
            counts.deactivated += 1;
          } else {
            vanished += 1;
          }
        }
        if (vanished > 0) {
          counts.vanished += vanished;
          stats.anomalies.push(`vanished: ${sourceFile} — ${vanished} 条记录不再出现，保留原值`);
        }
      }

      this.#db.exec('COMMIT');
    } catch (err) {
      this.#db.exec('ROLLBACK');
      throw err;
    }

    return stats;
  }

  /**
   * 把旧库行原样搬进 `legacy_records`。不做口径换算，不参与统计。
   *
   * @param {Object[]} rows `unified_records` 的原始行
   * @param {{ replace?: boolean }} [options]
   * @returns {number} 导入行数
   */
  importLegacyRows(rows, options = {}) {
    this.#db.exec('BEGIN IMMEDIATE');
    try {
      if (options.replace) {
        this.#db.exec('DELETE FROM legacy_records');
      }
      let imported = 0;
      for (const r of rows) {
        this.#insertLegacy.run(
          r.id ?? null, r.content_hash ?? null, r.source ?? null, r.session_id ?? null,
          r.model ?? null, r.timestamp ?? null,
          r.input_tokens ?? null, r.output_tokens ?? null,
          r.cache_read_tokens ?? null, r.cache_creation_tokens ?? null,
          r.estimated_cost ?? null
        );
        imported += 1;
      }
      this.#db.exec('COMMIT');
      return imported;
    } catch (err) {
      this.#db.exec('ROLLBACK');
      throw err;
    }
  }

  /**
   * 把 `r.replaces` 列出的旧键停用，并指向接替它的行。
   *
   * @param {Object} r
   * @param {number} newId
   * @param {Object} stats
   */
  #supersedeOld(r, newId, stats) {
    if (!Array.isArray(r.replaces)) return;
    for (const oldKey of r.replaces) {
      if (!oldKey || oldKey === r.record_key) continue;
      const old = this.#selectKey.get(oldKey);
      if (old && old.active) {
        this.#supersede.run(newId, old.id);
        stats.counts.replaced += 1;
      }
    }
  }

  /**
   * 采集开始时登记一次运行，状态为 running，界面据此知道同步正在进行。
   *
   * @returns {number} run id
   */
  beginRun() {
    this.#runAbandon.run();
    const info = this.#runStart.run(Math.floor(Date.now() / 1000));
    return Number(info.lastInsertRowid);
  }

  /**
   * 收尾一次运行。不给 `runId` 时当场登记并收尾。
   *
   * @param {string} status
   * @param {Object} stats
   * @param {number} [runId] `beginRun` 返回的 id
   * @returns {number} run id
   */
  recordRun(status, stats, runId) {
    const id = runId ?? this.beginRun();
    this.#runFinish.run(
      Math.floor(Date.now() / 1000), status,
      stats.attempted, stats.inserted, stats.updated, stats.unchanged, stats.rejected,
      stats.anomalies && stats.anomalies.length ? JSON.stringify(stats.anomalies) : null,
      stats.counts ? JSON.stringify(stats.counts) : null,
      id
    );
    return id;
  }

  /**
   * 运行中途失败：标成 failed，把错误写进异常列表。
   *
   * @param {number} runId
   * @param {string} message
   */
  failRun(runId, message) {
    this.#runFail.run(Math.floor(Date.now() / 1000), JSON.stringify([`run_failed: ${message}`]), runId);
  }

  /**
   * 用量按当前价格版本重算金额。
   *
   * 用量事实不变，只更新 `cost_micros` / `price_version`。价格版本与当前不同
   * （或从未计价）的记录才处理，因此换目录后只需跑一次。
   *
   * @param {(r: Object) => ({ cost_micros: number|null, price_version: string, price_source: string|null }|null)} priceOf
   * @param {string} version
   * @returns {number} 重算的行数
   */
  reprice(priceOf, version) {
    const rows = this.#db.prepare(`
      SELECT id, record_key, model, provider, kind, observed_at, ended_at,
             input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
             cache_write_5m_tokens, cache_write_1h_tokens
      FROM usage_records
      WHERE active = 1 AND (price_version IS NULL OR price_version != ?)
    `).all(version);

    if (rows.length === 0) return 0;

    const update = this.#db.prepare(`
      UPDATE usage_records SET price_version = ?, cost_micros = ?, price_source = ? WHERE id = ?
    `);

    this.#db.exec('BEGIN IMMEDIATE');
    try {
      for (const r of rows) {
        const price = priceOf({
          record_key: r.record_key,
          model: r.model,
          provider: r.provider,
          kind: r.kind,
          observed_at: r.observed_at,
          ended_at: r.ended_at,
          input_tokens: r.input_tokens,
          output_tokens: r.output_tokens,
          cache_read_tokens: r.cache_read_tokens,
          cache_write_tokens: r.cache_write_tokens,
          cache_write_5m_tokens: r.cache_write_5m_tokens,
          cache_write_1h_tokens: r.cache_write_1h_tokens
        }) || { cost_micros: null, price_version: version, price_source: null };

        update.run(price.price_version ?? version, price.cost_micros ?? null, price.price_source ?? null, r.id);
      }

      this.#db.prepare(`
        INSERT INTO pricing_snapshot (version, catalog_json, verified_at, created_at)
        VALUES (?, ?, ?, unixepoch())
        ON CONFLICT(version) DO UPDATE SET created_at = unixepoch()
      `).run(version, JSON.stringify({ version }), new Date().toISOString().slice(0, 10));

      this.#db.exec('COMMIT');
    } catch (err) {
      this.#db.exec('ROLLBACK');
      throw err;
    }

    return rows.length;
  }
}
