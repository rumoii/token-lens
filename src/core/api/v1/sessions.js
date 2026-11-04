import { classifyPrice } from '../../pricing/catalog.js';
import { money, totalsShape, snapshotMeta, queryFilter, offsetMinutesOf } from './common.js';

/**
 * @param {import('../../db/read.js').LedgerQueries} queries
 * @param {Object} params
 * @returns {Object}
 */
export function buildSessions(queries, params) {
  const filter = queryFilter(params);

  const page = queries.sessions({ limit: params.limit, cursor: params.cursor, filter });

  return {
    items: page.items.map((s) => ({
      session_id: s.session_id,
      source: s.source,
      project_key: s.project_key,
      started_at: s.started_at,
      last_seen_at: s.last_seen_at,
      gross_tokens: s.gross_tokens,
      cost_usd: money(s.cost_micros),
      record_count: s.record_count
    })),
    next_cursor: page.next_cursor,
    snapshot: snapshotMeta(filter)
  };
}

/**
 * 单个会话的明细：汇总、模型构成、时间线。
 *
 * 会话身份是 `(source, session_id)` 一对，缺任一个返回参数错误，不存在返回 `notFound`。
 *
 * @param {import('../../db/read.js').LedgerQueries} queries
 * @param {{ source?: string, session_id?: string, granularity?: string }} params
 * @returns {{ error?: Object, notFound?: boolean, session?: Object, models?: Object[],
 *             timeline?: Object[], kinds?: Object, granularity?: string, snapshot?: Object }}
 */
export function buildSessionDetail(queries, params) {
  const source = String(params.source || '').trim();
  const sessionId = String(params.session_id || '').trim();
  if (!source || !sessionId) {
    return { error: { code: 'invalid_param', message: '需要同时给出 source 与 session_id' } };
  }

  const granularity = params.granularity === 'day' ? 'day' : 'hour';
  const detail = queries.sessionDetail({
    source,
    sessionId,
    granularity,
    offsetMinutes: offsetMinutesOf(params.tz)
  });
  if (!detail) return { notFound: true };

  return {
    session: {
      source: detail.summary.source,
      session_id: detail.summary.session_id,
      project_key: detail.summary.project_key,
      started_at: detail.summary.started_at,
      last_seen_at: detail.summary.last_seen_at,
      ...totalsShape(detail.summary)
    },
    models: detail.models.map((m) => ({
      model: m.model,
      ...totalsShape(m),
      price_state: classifyPrice(m.model).state
    })),
    timeline: detail.timeline.map((t) => ({
      bucket: t.bucket,
      ...totalsShape(t)
    })),
    kinds: detail.kinds,
    granularity,
    snapshot: snapshotMeta({ source, session_id: sessionId }, { granularity })
  };
}
