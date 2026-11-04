import { vi } from "vitest";

export function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

export function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

export const snapshot = { generated_at: "2026-10-21T00:00:00Z", price_version: "test", tz: "UTC", filters: {} };
export function run(status = "ok", n = 1, details = {}) {
  const anomalies = details.anomalies ?? [];
  const now = Math.floor(Date.now() / 1000) * 1000;
  return { status, started_at: new Date(now - n * 1000).toISOString(),
    finished_at: status === "running" ? null : new Date(now).toISOString(),
    attempted: n, inserted: n, updated: 0, unchanged: 0, rejected: 0,
    ...details, anomalies, anomaly_count: anomalies.length };
}

export function ledgerFixture() {
  const state = { generation: 0, lastRun: run(), intercept: null };
  const totals = () => ({ gross_tokens: state.generation ? 4321 : 1234, input_tokens: 100,
    output_tokens: 20, cache_read_tokens: 10, cache_write_tokens: 0, cost_usd: "1.000000",
    record_count: 1, unpriced_records: 0 });
  const item = (id = "first") => ({ source: "codex", session_id: id,
    project_key: `D:/fixture/${state.generation ? "new" : "old"}-${id}`,
    started_at: "2026-10-21T00:00:00Z", last_seen_at: "2026-10-21T01:00:00Z", ...totals() });
  const body = (u) => {
    const path = u.pathname.replace("/api/v1", "");
    const by = u.searchParams.get("by");
    const t = totals();
    if (path === "/usage/summary") return { totals: t, activity: { sessions: 1, turns: 1,
      first_seen: "2026-10-01T00:00:00Z", last_seen: null, cache_hit_ratio: 0.1 },
      rolling: { last_7d: t, last_30d: t }, snapshot };
    if (path === "/usage/timeseries") return { granularity: u.searchParams.get("granularity"),
      points: [{ bucket: "2026-10-20", ...t }], unallocated: null, snapshot };
    if (path === "/usage/matrix") return { by, granularity: u.searchParams.get("granularity"),
      rows: [{ bucket: "2026-10-20", key: "codex", ...t }], unallocated: null, snapshot };
    if (path === "/usage/breakdown") return { by, totals: t, groups: [{
      key: by === "source_model" ? "gpt-6" : by === "project" ? item().project_key : "codex",
      source: "codex", model: "gpt-6", ...t }], snapshot };
    if (path === "/sources") return { sources: [{ source: "codex", records: state.generation ? 4321 : 1234,
      evidence: "A", status: "ok", record_mode: "event", first_observed_at: "2026-10-01T00:00:00Z",
      last_observed_at: "2026-10-21T00:00:00Z", limits: [], notes: [] }], last_run: state.lastRun, snapshot };
    if (path === "/sessions/detail") return { session: item(u.searchParams.get("session_id")),
      models: [], timeline: [], kinds: { event: 1, cumulative: 0 }, granularity: "hour", snapshot };
    if (path === "/sessions") return { items: [item(u.searchParams.has("cursor") ? "second" : "first")],
      next_cursor: u.searchParams.has("cursor") ? null : "page2", snapshot };
    if (path === "/pricing") return { models: [{ model: "gpt-6", state: "unknown", billing: "token",
      records: state.generation ? 4321 : 1234, prices: null, tiers: null, time_of_day: null }],
      counts: { verified: 0, aggregate: 0, unknown: 1 }, price_version: "test", snapshot };
    if (path === "/health") return { ok: true, version: "test", port: 0, data_dir: "fixture" };
    if (path === "/discovery") return { sources: [], supported: 1 };
    throw new Error(`Unexpected request ${u}`);
  };
  const fetch = vi.fn(async (input, init) => {
    const u = new URL(String(input));
    const intercepted = state.intercept?.(u, init);
    if (intercepted !== undefined) return intercepted;
    if (u.pathname.endsWith("/sync")) {
      state.generation++;
      state.lastRun = run("ok", state.generation + 1);
      const { attempted, inserted, updated, unchanged, rejected, anomalies } = state.lastRun;
      return json({ attempted, inserted, updated, unchanged, rejected, anomalies, fileCount: 1, durationMs: 1 });
    }
    return json(body(u));
  });
  return { state, fetch, body, item };
}
