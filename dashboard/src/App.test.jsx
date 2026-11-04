import React from "react";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App.jsx";
import { ledgerFixture, json } from "./test/ledger-fixture.js";

vi.mock("./ui/components/Sidebar.jsx", () => ({ AppLayout: ({ children }) => <main>{children}</main> }));
vi.mock("./ui/foundation/ThemeProvider.jsx", () => ({ ThemeProvider: ({ children }) => children }));

const TOTALS = {
  gross_tokens: 0,
  input_tokens: 0,
  output_tokens: 0,
  cache_read_tokens: 0,
  cache_write_tokens: 0,
  cost_usd: "0.000000",
  unpriced_records: 0,
  record_count: 1,
};

const ACTIVITY = {
  sessions: 0,
  turns: 0,
  cache_hit_ratio: null,
  first_seen: null,
  last_seen: null,
  active_span_ms: null,
};

const SNAPSHOT = { generated_at: "2026-10-18T00:00:00.000Z", price_version: "test", tz: "UTC", filters: {} };

const LAST_RUN = {
  status: "ok",
  finished_at: "2026-10-18T00:00:00.000Z",
  attempted: 0,
  inserted: 0,
  updated: 0,
  unchanged: 0,
  rejected: 0,
  anomaly_count: 0,
  anomalies: [],
};

/**
 * 按路径返回最小可用响应，避免页面在测试里真的发请求。
 */
function mockApi({ recordCount = 1, discoverySources = [{ source: "claude", files: 2 }] } = {}) {
  return vi.fn(async (url) => {
    const path = String(url);
    const totals = { ...TOTALS, record_count: recordCount };
    const body = path.includes("/usage/summary")
      ? {
          totals,
          activity: ACTIVITY,
          rolling: { last_7d: { gross_tokens: 0, cost_usd: "0.000000" }, last_30d: { gross_tokens: 0, cost_usd: "0.000000" } },
          snapshot: SNAPSHOT,
        }
      : path.includes("/discovery")
        ? { sources: discoverySources, supported: 22 }
        : path.includes("/usage/timeseries")
          ? { granularity: "day", points: [], unallocated: null, snapshot: SNAPSHOT }
          : path.includes("/usage/matrix")
            ? { granularity: "day", by: "source", rows: [], unallocated: null, snapshot: SNAPSHOT }
            : path.includes("/usage/breakdown")
              ? { by: "model", groups: [], totals, snapshot: SNAPSHOT }
              : path.includes("/sessions")
                ? { items: [], next_cursor: null, snapshot: SNAPSHOT }
                : path.includes("/sources")
                  ? { sources: [], last_run: LAST_RUN, snapshot: SNAPSHOT }
                  : path.includes("/pricing")
                    ? { price_version: "test", verified_at: null, currency: "USD", provisional: true, models: [], counts: { verified: 0, aggregate: 0, unknown: 0 }, snapshot: SNAPSHOT }
                    : { ok: true, version: "1.0.0", port: 3456, data_dir: "/tmp" };
    return new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
  });
}

describe("assembled local routes", () => {
  beforeEach(() => {
    document.head.innerHTML = '<meta name="lens-api-token" content="t">';
    window.localStorage.clear();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("首页在 /dashboard 通过 lazy 加载并渲染", async () => {
    vi.stubGlobal("fetch", mockApi());
    render(<MemoryRouter initialEntries={["/dashboard"]}><App /></MemoryRouter>);
    await waitFor(() => expect(screen.getByRole("heading", {
      name: /(夜深了|早上好|中午好|下午好|晚上好)/,
    })).toBeInTheDocument(), { timeout: 10_000 });
  }, 15_000);

  it("旧的 /usage 跳到首页的明细视图", async () => {
    vi.stubGlobal("fetch", mockApi());
    render(<MemoryRouter initialEntries={["/usage"]}><App /></MemoryRouter>);
    expect(await screen.findByRole("heading", { name: "明细" }, { timeout: 10_000 })).toBeInTheDocument();
  }, 15_000);

  it("/sources 渲染来源与同步页", async () => {
    vi.stubGlobal("fetch", mockApi());
    render(<MemoryRouter initialEntries={["/sources"]}><App /></MemoryRouter>);
    expect(await screen.findByRole("heading", { name: "工具" }, { timeout: 10_000 })).toBeInTheDocument();
  }, 15_000);

  it("没有后端的旧路由重定向到首页", async () => {
    vi.stubGlobal("fetch", mockApi());
    render(<MemoryRouter initialEntries={["/limits"]}><App /></MemoryRouter>);
    await waitFor(() =>
      expect(
        screen.getByRole("heading", { name: /(夜深了|早上好|中午好|下午好|晚上好)/ }),
      ).toBeInTheDocument(),
    );
  }, 15_000);

  it("账本为空且没点过去看看时渲染首次引导", async () => {
    vi.stubGlobal("fetch", mockApi({ recordCount: 0, discoverySources: [{ source: "claude", files: 2 }] }));
    render(<MemoryRouter initialEntries={["/dashboard"]}><App /></MemoryRouter>);
    expect(
      await screen.findByRole("heading", { name: "欢迎使用 Token Lens" }, { timeout: 10_000 }),
    ).toBeInTheDocument();
    expect(await screen.findByText(/在这台电脑上找到 1 个工具/)).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: /(夜深了|早上好|中午好|下午好|晚上好)/ })).toBeNull();
  }, 15_000);

  it("点过「去看看」后不再出现引导", async () => {
    window.localStorage.setItem("token-lens-onboarded", "1");
    vi.stubGlobal("fetch", mockApi({ recordCount: 0 }));
    render(<MemoryRouter initialEntries={["/dashboard"]}><App /></MemoryRouter>);
    await waitFor(() => expect(screen.getByRole("heading", {
      name: /(夜深了|早上好|中午好|下午好|晚上好)/,
    })).toBeInTheDocument(), { timeout: 10_000 });
    expect(screen.queryByRole("heading", { name: "欢迎使用 Token Lens" })).toBeNull();
  }, 15_000);

  it("T11 引导同步完成汇总与进入首页都使用新版数据", async () => {
    const fixture = ledgerFixture();
    fixture.state.intercept = u => {
      if (u.pathname.endsWith("/summary") && !fixture.state.generation) {
        const body = fixture.body(u);
        return json({ ...body, totals: { ...body.totals, record_count: 0 } });
      }
      if (u.pathname.endsWith("/discovery")) return json({ sources: [{ source: "codex", files: 1 }], supported: 1 });
    };
    vi.stubGlobal("fetch", fixture.fetch);
    render(<MemoryRouter><App /></MemoryRouter>);
    fireEvent.click(await screen.findByRole("button", { name: "开始统计" }));
    await screen.findByTitle("4,321 token");
    fireEvent.click(screen.getByRole("button", { name: /去看看/ }));
    await waitFor(() => expect(screen.getAllByTitle("4,321 token").length).toBeGreaterThan(1));
    expect(fixture.fetch.mock.calls.filter(([u]) => new URL(u).pathname.endsWith("/sync"))).toHaveLength(1);
  });

  it("T16 App 根在 StrictMode 重挂载后只观察一轮，卸载清理 timer 与监听", async () => {
    await import("./pages/v1/SessionsPage.jsx");
    vi.useFakeTimers();
    vi.stubGlobal("requestIdleCallback", vi.fn(() => 1));
    vi.stubGlobal("cancelIdleCallback", vi.fn());
    const fixture = ledgerFixture();
    vi.stubGlobal("fetch", fixture.fetch);
    window.localStorage.setItem("token-lens-onboarded", "1");
    let view;
    try {
      view = render(<React.StrictMode><MemoryRouter initialEntries={["/sessions"]}><App /></MemoryRouter></React.StrictMode>);
      await act(async () => {
        await vi.advanceTimersByTimeAsync(0);
      });
      expect(screen.getByText("old-first")).toBeInTheDocument();
      const sources = fixture.fetch.mock.calls.filter(([u, init]) => new URL(u).pathname.endsWith("/sources") && init.signal).length;
      await act(async () => { await vi.advanceTimersByTimeAsync(300000); });
      expect(fixture.fetch.mock.calls.filter(([u, init]) => new URL(u).pathname.endsWith("/sources") && init.signal)).toHaveLength(sources + 1);
      view.unmount();
      expect(vi.getTimerCount()).toBe(0);
      const count = fixture.fetch.mock.calls.length;
      fireEvent.focus(window);
      fireEvent(document, new Event("visibilitychange"));
      await vi.advanceTimersByTimeAsync(300000);
      expect(fixture.fetch.mock.calls).toHaveLength(count);
    } finally {
      cleanup();
      vi.useRealTimers();
    }
  });
});
