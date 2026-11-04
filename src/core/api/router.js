import { buildSummary, buildTimeseries, buildMatrix, buildBreakdown, buildUnallocated } from './v1/usage.js';
import { buildSessions, buildSessionDetail } from './v1/sessions.js';
import { buildSources, createDiscoveryService } from './v1/sources.js';
import { buildPricing, buildHealth } from './v1/pricing.js';
import { isSyncBusyError } from '../sync-lock.js';
import { PRICE_VERSION } from '../pricing/engine.js';
import { offsetMinutesOf } from './v1/common.js';

const USAGE_CACHE_PATHS = new Set([
  '/api/v1/usage/summary',
  '/api/v1/usage/timeseries',
  '/api/v1/usage/matrix',
  '/api/v1/usage/breakdown',
  '/api/v1/usage/unallocated'
]);

/**
 * 解析查询参数。多值参数当前只取第一个，避免悄悄改变语义。
 *
 * @param {URLSearchParams} search
 * @returns {Object}
 */
function params(search) {
  return {
    from: search.get('from') || '',
    to: search.get('to') || '',
    tz: search.get('tz') || '',
    source: search.get('source') || null,
    model: search.get('model') || null,
    project: search.get('project') || null,
    session_id: search.get('session_id') || null,
    granularity: search.get('granularity') || 'day',
    by: search.get('by') || 'model',
    limit: search.get('limit') ? Number(search.get('limit')) : undefined,
    cursor: search.get('cursor') || null,
    week_starts_on: search.get('week_starts_on') === 'mon' ? 'mon' : 'sun'
  };
}

/**
 * 建路由。
 *
 * @param {Object} ctx
 * @param {import('../db/read.js').LedgerQueries} ctx.queries
 * @param {(req:any,res:any,body:any,status?:number)=>void} ctx.json
 * @param {(req:any,res:any,status:number,code:string,message:string)=>void} ctx.reject
 * @param {() => Promise<Object>} ctx.runSync
 * @param {Object} ctx.meta
 * @param {() => Object<string, string[]>} [ctx.discover] 本地日志发现函数
 * @param {() => Date} [ctx.now] 测试注入当前时刻，用于缓存键里的本地日期
 * @returns {(req:any, res:any, pathname:string) => Promise<boolean>} 命中返回 true
 */
export function createRouter(ctx) {
  const { queries, json, meta } = ctx;
  const buildDiscovery = createDiscoveryService(ctx.discover);
  const usageCache = new Map();

  const v1 = {
    'GET /api/v1/health': (req, res) => json(req, res, buildHealth(meta)),

    'GET /api/v1/usage/summary': (req, res, q) => buildSummary(queries, q),
    'GET /api/v1/usage/timeseries': (req, res, q) => buildTimeseries(queries, q),
    'GET /api/v1/usage/matrix': (req, res, q) => buildMatrix(queries, q),
    'GET /api/v1/usage/breakdown': (req, res, q) => buildBreakdown(queries, q),
    'GET /api/v1/usage/unallocated': (req, res, q) => buildUnallocated(queries, q),
    'GET /api/v1/sessions': (req, res, q) => json(req, res, buildSessions(queries, q)),

    'GET /api/v1/sessions/detail': (req, res, q) => {
      const out = buildSessionDetail(queries, q);
      if (out.error) {
        json(req, res, { error: out.error }, 400);
        return;
      }
      if (out.notFound) {
        json(req, res, { error: { code: 'not_found', message: '没有这个会话' } }, 404);
        return;
      }
      json(req, res, out);
    },
    'GET /api/v1/sources': (req, res) => json(req, res, buildSources(queries)),
    'GET /api/v1/discovery': (req, res, q) =>
      json(req, res, buildDiscovery({ fresh: q.fresh === '1' })),
    'GET /api/v1/pricing': (req, res) => json(req, res, buildPricing(queries)),

    'POST /api/v1/pricing/refresh': (req, res) => {
      json(req, res, {
        error: {
          code: 'not_implemented',
          message: '联网更新价格尚未实现（Phase 2）；内置目录为离线暂定价'
        }
      }, 501);
    },

    'POST /api/v1/sync': async (req, res) => {
      try {
        const result = await ctx.runSync();
        if (!result) {
          json(req, res, { error: { code: 'sync_in_progress', message: '已有同步在执行' } }, 409);
          return;
        }
        json(req, res, result);
      } catch (err) {
        if (isSyncBusyError(err)) {
          json(req, res, { error: { code: 'sync_in_progress', message: '已有同步在执行' } }, 409);
          return;
        }
        throw err;
      }
    }
  };

  return async function handle(req, res, pathname) {
    const search = new URL(req.url, 'http://127.0.0.1').searchParams;
    const q = params(search);

    const v1Key = `${(req.method || 'GET').toUpperCase()} ${pathname}`;
    if (v1[v1Key]) {
      // 只对 GET 生效：from 晚于 to 的区间没有意义，报错而不是返回空结果
      if (v1Key.startsWith('GET ') && q.from && q.to && q.from > q.to) {
        json(req, res, { error: { code: 'invalid_range', field: 'from', message: 'from 晚于 to' } }, 400);
        return true;
      }
      if (v1Key.startsWith('GET ') && USAGE_CACHE_PATHS.has(pathname)) {
        const now = ctx.now ? ctx.now() : new Date();
        const localDate = new Date(now.getTime() + offsetMinutesOf(q.tz) * 60000).toISOString().slice(0, 10);
        const sorted = [...search.entries()].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
        const key = JSON.stringify([pathname, sorted, queries.dataVersion(), PRICE_VERSION, localDate]);
        if (usageCache.has(key)) {
          const cached = usageCache.get(key);
          usageCache.delete(key);
          usageCache.set(key, cached);
          json(req, res, cached);
          return true;
        }
        const body = await v1[v1Key](req, res, q);
        usageCache.set(key, body);
        if (usageCache.size > 64) usageCache.delete(usageCache.keys().next().value);
        json(req, res, body);
        return true;
      }
      await v1[v1Key](req, res, q);
      return true;
    }
    if (v1Key.startsWith('GET /api/v1/') || v1Key.startsWith('POST /api/v1/')) {
      json(req, res, { error: { code: 'not_found', message: `未实现的路由：${pathname}` } }, 404);
      return true;
    }

    return false;
  };
}




