import React from "react";
import { act, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { HomePage } from "./HomePage.jsx";
import { ThemeProvider } from "../../ui/foundation/ThemeProvider.jsx";
import { syncState } from "../../lib/sync-state.js";
import { deferred } from "../../test/ledger-fixture.js";

const SNAPSHOT = { generated_at: "2026-10-21T00:00:00.000Z", price_version: "pv", tz: "UTC", filters: {} };
const totals = {
  gross_tokens: 100,
  input_tokens: 60,
  output_tokens: 30,
  cache_read_tokens: 10,
  cache_write_tokens: 0,
  cost_usd: "1.000000",
  unpriced_records: 0,
  record_count: 1,
};

function bodyFor(url) {
  const path = url.pathname.replace("/api/v1", "");
  const by = url.searchParams.get("by");
  if (path === "/sync") return { inserted: 0 };
  if (path === "/usage/summary") {
    return {
      totals,
      activity: { sessions: 1, turns: 1, cache_hit_ratio: 0.2, first_seen: "2026-10-01T00:00:00.000Z", last_seen: null, active_span_ms: null },
      rolling: { last_7d: { gross_tokens: 100, cost_usd: "1.000000" }, last_30d: { gross_tokens: 100, cost_usd: "1.000000" } },
      snapshot: SNAPSHOT,
    };
  }
  if (path === "/usage/timeseries") {
    return { granularity: url.searchParams.get("granularity"), points: [{ bucket: "2026-10-20", ...totals }], unallocated: null, snapshot: SNAPSHOT };
  }
  if (path === "/usage/breakdown") {
    const groups = by === "source_model"
      ? [
          { key: "deepseek-flash", source: "dsh", model: "deepseek-flash", ...totals, gross_tokens: 40 },
          { key: "claude-opus-5-5", source: "claude", model: "claude-opus-5-5", ...totals, gross_tokens: 30 },
        ]
      : [
          { key: "dsh", ...totals, gross_tokens: 40 },
          { key: "claude", ...totals, gross_tokens: 30 },
        ];
    return { by, groups, totals, snapshot: SNAPSHOT };
  }
  if (path === "/usage/matrix") {
    return { granularity: url.searchParams.get("granularity"), by, rows: [{ bucket: "2026-10-20", key: "dsh", ...totals }], unallocated: null, snapshot: SNAPSHOT };
  }
  if (path === "/sessions") return { items: [], next_cursor: null, snapshot: SNAPSHOT };
  if (path === "/sources") return { sources: [], last_run: null, snapshot: SNAPSHOT };
  if (path === "/pricing") return { price_version: "pv", verified_at: null, currency: "USD", provisional: true, models: [], snapshot: SNAPSHOT };
  throw new Error(`Unexpected API request: ${url}`);
}

function signature(call) {
  const url = new URL(String(call[0]));
  return [
    url.pathname.replace("/api/v1", ""),
    url.searchParams.get("from") ?? "null",
    url.searchParams.get("granularity") ?? "null",
    url.searchParams.get("by") ?? "null",
  ].join("|");
}

describe("首页周期预取", () => {
  let idleCallbacks;
  let fetchMock;

  beforeEach(() => {
    document.head.innerHTML = '<meta name="lens-api-token" content="fixture">';
    window.localStorage.clear();
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date(2026, 9, 21, 15, 0, 0));
    vi.stubGlobal("matchMedia", vi.fn((query) => ({
      matches: false,
      media: query,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    })));
    idleCallbacks = [];
    vi.stubGlobal("requestIdleCallback", vi.fn((callback) => {
      idleCallbacks.push(callback);
      return idleCallbacks.length;
    }));
    vi.stubGlobal("cancelIdleCallback", vi.fn());
    fetchMock = vi.fn(async (input) => {
      const url = new URL(String(input));
      return new Response(JSON.stringify(bodyFor(url)), { status: 200, headers: { "Content-Type": "application/json" } });
    });
    vi.stubGlobal("fetch", fetchMock);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  async function renderWeek() {
    const view = render(
      <ThemeProvider>
        <MemoryRouter initialEntries={["/dashboard?period=week"]}>
          <HomePage />
        </MemoryRouter>
      </ThemeProvider>,
    );
    expect(await screen.findByText(/用得最多的是/)).toBeInTheDocument();
    await waitFor(() => expect(idleCallbacks.length).toBeGreaterThan(0));
    return view;
  }

  async function runNextIdle() {
    const callback = idleCallbacks.shift();
    expect(callback).toBeTypeOf("function");
    await act(async () => callback());
  }

  it("数据就绪后按顺序预热另外两个周期和侧栏来源，不重复本周请求", async () => {
    await renderWeek();
    const start = fetchMock.mock.calls.length;
    await runNextIdle();
    const calls = fetchMock.mock.calls.slice(start).map(signature);
    expect(calls).toEqual([
      "/usage/summary|2026-10-21|null|null",
      "/usage/timeseries|2026-10-20|hour|null",
      "/usage/timeseries|2026-10-21|day|null",
      "/usage/breakdown|2026-10-21|null|source_model",
      "/usage/matrix|2026-10-21|hour|source",
      "/usage/breakdown|2026-10-21|null|source",
      "/usage/summary|2026-10-01|null|null",
      "/usage/summary|2026-09-01|null|null",
      "/usage/timeseries|2026-09-01|day|null",
      "/usage/timeseries|2026-10-01|day|null",
      "/usage/breakdown|2026-10-01|null|source_model",
      "/usage/matrix|2026-10-01|day|source",
      "/usage/breakdown|2026-10-01|null|source",
    ]);
    expect(calls.every((call) => !call.includes("2026-10-19") && !call.includes("2026-10-12"))).toBe(true);
  });

  it("单次预取失败静默并继续后续请求", async () => {
    fetchMock.mockImplementation(async (input) => {
      const url = new URL(String(input));
      if (url.pathname.endsWith("/usage/summary") && url.searchParams.get("from") === "2026-10-21") {
        return new Response(JSON.stringify({ error: { code: "test", message: "预热失败" } }), { status: 500 });
      }
      return new Response(JSON.stringify(bodyFor(url)), { status: 200, headers: { "Content-Type": "application/json" } });
    });
    await renderWeek();
    const start = fetchMock.mock.calls.length;
    await runNextIdle();
    const calls = fetchMock.mock.calls.slice(start).map(signature);
    expect(calls).toHaveLength(13);
    expect(calls[1]).toBe("/usage/timeseries|2026-10-20|hour|null");
    expect(screen.queryByText(/加载失败/)).toBeNull();
  });

  it("同步完成后重新预热一次", async () => {
    await renderWeek();
    await runNextIdle();
    await act(async () => { await syncState.startSync(); });
    await waitFor(() => expect(idleCallbacks.length).toBeGreaterThan(0));
    const start = fetchMock.mock.calls.length;
    await runNextIdle();
    expect(fetchMock.mock.calls.slice(start)).toHaveLength(13);
  });

  it("T15 同步使旧预取串行链失效，不再发旧链的下一步", async () => {
    await renderWeek();
    const gate = deferred();
    let held = false;
    fetchMock.mockImplementation(async input => {
      const url = new URL(String(input));
      if (!held && url.pathname.endsWith("/summary") && url.searchParams.get("from") === "2026-10-21") {
        held = true;
        await gate.promise;
      }
      return new Response(JSON.stringify(bodyFor(url)), { status: 200 });
    });
    const callback = idleCallbacks.shift();
    let oldRun;
    act(() => { oldRun = callback(); });
    await waitFor(() => expect(held).toBe(true));
    await act(async () => { await syncState.startSync(); });
    const beforeRelease = fetchMock.mock.calls.length;
    await act(async () => { gate.resolve(); await oldRun; });
    expect(fetchMock.mock.calls.length).toBe(beforeRelease);
    expect(idleCallbacks.length).toBeGreaterThan(0);
  });

  it("重新聚焦或可见时预热，60 秒内重复事件只执行一次", async () => {
    await renderWeek();
    await runNextIdle();

    act(() => window.dispatchEvent(new Event("focus")));
    await waitFor(() => expect(idleCallbacks.length).toBe(1));
    let start = fetchMock.mock.calls.length;
    await runNextIdle();
    expect(fetchMock.mock.calls.slice(start)).toHaveLength(13);

    await act(async () => {
      window.dispatchEvent(new Event("focus"));
      document.dispatchEvent(new Event("visibilitychange"));
    });
    expect(idleCallbacks).toHaveLength(0);

    vi.setSystemTime(new Date(2026, 9, 21, 15, 1, 0));
    act(() => document.dispatchEvent(new Event("visibilitychange")));
    await waitFor(() => expect(idleCallbacks.length).toBe(1));
    start = fetchMock.mock.calls.length;
    await runNextIdle();
    expect(fetchMock.mock.calls.slice(start)).toHaveLength(13);
  });

  it("卸载时取消尚未开始的空闲预取", async () => {
    const view = await renderWeek();
    const count = fetchMock.mock.calls.length;
    view.unmount();
    expect(window.cancelIdleCallback).toHaveBeenCalledWith(1);
    expect(fetchMock.mock.calls).toHaveLength(count);
  });

  it("卸载时移除焦点与可见性监听", async () => {
    const removeWindow = vi.spyOn(window, "removeEventListener");
    const removeDocument = vi.spyOn(document, "removeEventListener");
    const view = await renderWeek();
    view.unmount();
    expect(removeWindow).toHaveBeenCalledWith("focus", expect.any(Function));
    expect(removeDocument).toHaveBeenCalledWith("visibilitychange", expect.any(Function));
  });

  it("页面隐藏时不发预取请求", async () => {
    await renderWeek();
    await runNextIdle();
    vi.spyOn(document, "visibilityState", "get").mockReturnValue("hidden");
    const start = fetchMock.mock.calls.length;
    act(() => document.dispatchEvent(new Event("visibilitychange")));
    expect(idleCallbacks).toHaveLength(0);
    expect(fetchMock.mock.calls.slice(start)).toHaveLength(0);
  });

  it("hidden 后恢复 visible 只预取一次且 hidden 不占限频", async () => {
    await renderWeek();
    await runNextIdle();
    const visibility = vi.spyOn(document, "visibilityState", "get").mockReturnValue("hidden");
    act(() => document.dispatchEvent(new Event("visibilitychange")));
    expect(idleCallbacks).toHaveLength(0);

    visibility.mockReturnValue("visible");
    act(() => document.dispatchEvent(new Event("visibilitychange")));
    await waitFor(() => expect(idleCallbacks).toHaveLength(1));
    const start = fetchMock.mock.calls.length;
    await runNextIdle();
    expect(fetchMock.mock.calls.slice(start)).toHaveLength(13);
  });
});
