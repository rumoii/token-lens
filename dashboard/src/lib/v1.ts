/**
 * `/api/v1` 客户端。
 *
 * 令牌由服务端注入 `index.html` 的 `<meta name="lens-api-token">`，前端从 DOM 读取，
 * 不落 localStorage、不硬编码。
 */

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
  }
}

export type TokenTotals = {
  gross_tokens: number;
  input_tokens: number | null;
  output_tokens: number | null;
  cache_read_tokens: number | null;
  cache_write_tokens: number | null;
  cost_usd: string | null;
  unpriced_records: number;
  record_count: number;
};

export type Snapshot = {
  generated_at: string;
  price_version: string;
  tz: string;
  filters: Record<string, unknown>;
  [key: string]: unknown;
};

export type Activity = {
  sessions: number;
  turns: number;
  cache_hit_ratio: number | null;
  first_seen: string | null;
  last_seen: string | null;
  active_span_ms: number | null;
};

export type Summary = {
  totals: TokenTotals;
  activity: Activity;
  rolling: {
    last_7d: { gross_tokens: number; cost_usd: string | null };
    last_30d: { gross_tokens: number; cost_usd: string | null };
  };
  snapshot: Snapshot;
};

export type Granularity = "day" | "month" | "hour";

export type Matrix = {
  granularity: Granularity;
  by: "model" | "source" | "project";
  rows: Array<TokenTotals & { bucket: string; key: string | null }>;
  unallocated: {
    gross_tokens: number;
    cost_usd: string | null;
    record_count: number;
    reason: string;
  } | null;
  snapshot: Snapshot;
};

export type Timeseries = {
  granularity: "day" | "month" | "hour";
  points: Array<TokenTotals & { bucket: string }>;
  unallocated: {
    gross_tokens: number;
    cost_usd: string | null;
    record_count: number;
    reason: string;
  } | null;
  snapshot: Snapshot;
};

export type PriceState = "verified" | "aggregate" | "unknown" | "local";

export type CostByKind = {
  input: string | null;
  output: string | null;
  cache_read: string | null;
  cache_write: string | null;
};

export type BreakdownBy = "model" | "source" | "project" | "source_model";

export type Breakdown = {
  by: BreakdownBy;
  groups: Array<
    TokenTotals & {
      key: string | null;
      /** 只在 `by=source_model` 时出现 */
      source?: string;
      model?: string | null;
      price_state: PriceState | null;
      cost_by_kind: CostByKind | null;
    }
  >;
  totals: TokenTotals;
  snapshot: Snapshot;
};

export type SessionRow = {
  session_id: string;
  source: string;
  project_key: string | null;
  started_at: string;
  last_seen_at: string;
  gross_tokens: number;
  cost_usd: string | null;
  record_count: number;
};

export type Sessions = {
  items: SessionRow[];
  next_cursor: string | null;
  snapshot: Snapshot;
};

export type SessionDetail = {
  session: {
    source: string;
    session_id: string;
    project_key: string | null;
    started_at: string;
    last_seen_at: string;
  } & TokenTotals;
  models: Array<{ model: string | null; price_state: PriceState } & TokenTotals>;
  timeline: Array<{ bucket: string } & TokenTotals>;
  kinds: { event: number; cumulative: number };
  granularity: Granularity;
  snapshot: Snapshot;
};

export type Sources = {
  sources: Array<{
    source: string;
    evidence: string;
    status: string;
    first_observed_at: string | null;
    last_observed_at: string | null;
    records: number;
    record_mode: "event" | "cumulative" | "mixed";
    /** 出处日志仍在的条数与日志已删的条数；两者之和等于 records */
    retention?: { reviewable: number; logs_gone: number };
    /** 账本自检：可疑记录的条数（mixed_kind_sessions 是会话数） */
    checks?: { time_out_of_range: number; huge_requests: number; null_model: number; mixed_kind_sessions: number };
    /** 口径原文 */
    limits: string[];
    /** 与 `limits` 一一对应、给使用者看的说明 */
    notes: Array<{ text: string; impact: "affects" | "handled" }>;
  }>;
  last_run: {
    status: string;
    started_at?: string | null;
    finished_at: string | null;
    attempted: number;
    inserted: number;
    updated: number;
    unchanged: number;
    rejected: number;
    /** 按类计数（schema v4 起）；更早的运行为 null */
    counts?: Record<string, number> | null;
    anomaly_count: number;
    anomalies: string[];
  } | null;
  snapshot: Snapshot;
};

export type Discovery = {
  sources: Array<{ source: string; files: number }>;
  supported: number;
};

export type Prices = {
  input: number | null;
  output: number | null;
  cache_read: number | null;
  cache_write_5m: number | null;
  cache_write_1h: number | null;
};

export type Pricing = {
  price_version: string;
  verified_at: string | null;
  currency: string;
  provisional: boolean;
  models: Array<{
    model: string | null;
    records: number;
    state: PriceState;
    billing: "metered" | "plan" | "local";
    local_records: number;
    local_providers: Record<string, number>;
    source_url: string | null;
    note: string | null;
    prices: Prices | null;
    tiers: Array<{ above: number; prices: Prices }> | null;
    time_of_day: {
      utc_offset_minutes: number;
      peak: Array<{ days: number[]; from: number; to: number }>;
      off_peak_prices: Prices;
      holidays_count: number;
      holidays_through: string | null;
    } | null;
    price_marks: Record<string, number>;
  }>;
  counts: Record<PriceState, number>;
  snapshot: Snapshot;
};

export type SyncResult = {
  attempted: number;
  inserted: number;
  updated: number;
  unchanged: number;
  rejected: number;
  fileCount: number;
  durationMs: number;
  anomalies: string[];
};

type Query = Record<string, string | number | null | undefined>;

/**
 * 从注入的 meta 读取令牌。缺令牌时不猜测、不回退到无鉴权请求。
 *
 * @returns {string|null}
 */
export function readApiToken(): string | null {
  if (typeof document === "undefined") return null;
  const el = document.querySelector('meta[name="lens-api-token"]');
  const content = el?.getAttribute("content")?.trim();
  return content ? content : null;
}

/**
 * 浏览器时区名。用来让服务端按本地时区切时间桶——否则「今天」会被切在 UTC 的边界上。
 *
 * @returns {string|null}
 */
function browserTimeZone(): string | null {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || null;
  } catch {
    return null;
  }
}

/**
 * @param {string} path `/` 开头，相对 `/api/v1`
 * @param {Object} [options]
 * @returns {Promise<string>}
 */
function buildUrl(path: string, params?: Query): string {
  const url = new URL(`/api/v1${path}`, window.location.origin);
  for (const [key, value] of Object.entries(params || {})) {
    if (value === undefined || value === null || value === "") continue;
    url.searchParams.set(key, String(value));
  }
  return url.toString();
}

/**
 * 发出一次 `/api/v1` 请求。
 *
 * 非 2xx 一律抛 ApiError，错误体里带 code 与 message；不返回半成品数据。
 *
 * @template T
 * @param {string} path
 * @param {Object} [options]
 * @returns {Promise<T>}
 */
export async function request<T>(
  path: string,
  options: { method?: string; params?: Query; fetchImpl?: typeof fetch; signal?: AbortSignal } = {},
): Promise<T> {
  const { method = "GET", params, fetchImpl, signal } = options;

  // 读请求统一带浏览器时区，服务端据此切时间桶；写请求不带，避免无意义的参数
  const tz = method === "GET" ? browserTimeZone() : null;
  const query = tz ? { tz, ...params } : params;
  const url = buildUrl(path, query);

  // 同一个读请求还在路上时直接复用：侧栏与页面常在同一刻要同一份数据
  if (method === "GET" && !fetchImpl && !signal) {
    const requests = inflight;
    const pending = requests.get(url);
    if (pending) return pending as Promise<T>;
    const promise = send<T>(url, method, fetch).finally(() => {
      if (requests.get(url) === promise) requests.delete(url);
    });
    requests.set(url, promise);
    return promise;
  }
  return send<T>(url, method, fetchImpl ?? fetch, signal);
}

let inflight = new Map<string, Promise<unknown>>();

/** 旧代次的完成只清理其自身的表，不能占用或删除新版请求。 */
export function invalidateReadRequests() {
  inflight = new Map();
}

async function send<T>(url: string, method: string, fetchImpl: typeof fetch, signal?: AbortSignal): Promise<T> {
  const token = readApiToken();

  const headers: Record<string, string> = { Accept: "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;

  const response = await fetchImpl(url, {
    method,
    headers,
    cache: "no-store",
    ...(signal ? { signal } : {}),
  });

  if (!response.ok) {
    let code = "http_error";
    let message = `HTTP ${response.status}`;
    try {
      const body = await response.json();
      if (body?.error?.code) code = String(body.error.code);
      if (body?.error?.message) message = String(body.error.message);
    } catch {
      // 非 JSON 错误体：保留状态码信息
    }
    throw new ApiError(response.status, code, message);
  }

  return (await response.json()) as T;
}

export const api = {
  health: () => request<{ ok: boolean; version: string; port: number; data_dir: string }>("/health"),

  summary: (params?: Query) => request<Summary>("/usage/summary", { params }),

  timeseries: (granularity: Granularity, params?: Query) =>
    request<Timeseries>("/usage/timeseries", { params: { ...params, granularity } }),

  matrix: (granularity: Granularity, by: "model" | "source" | "project", params?: Query) =>
    request<Matrix>("/usage/matrix", { params: { ...params, granularity, by } }),

  breakdown: (by: BreakdownBy, params?: Query) =>
    request<Breakdown>("/usage/breakdown", { params: { ...params, by } }),

  unallocated: (params?: Query) =>
    request<{ unallocated: Timeseries["unallocated"]; snapshot: Snapshot }>("/usage/unallocated", {
      params,
    }),

  sessions: (params?: Query) => request<Sessions>("/sessions", { params }),

  sessionDetail: (params: { source: string; session_id: string; granularity?: Granularity }) =>
    request<SessionDetail>("/sessions/detail", { params }),

  sources: () => request<Sources>("/sources"),

  /** `fresh` 跳过服务端一分钟的扫盘缓存，给「重新检测」用。 */
  discovery: (options: { fresh?: boolean } = {}) =>
    request<Discovery>("/discovery", { params: options.fresh ? { fresh: "1" } : undefined }),

  pricing: () => request<Pricing>("/pricing"),

  sync: () => request<SyncResult>("/sync", { method: "POST" }),
};

