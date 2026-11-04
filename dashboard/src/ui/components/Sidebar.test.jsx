import React, { useEffect } from "react";
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AppLayout } from "./Sidebar.jsx";
import { ThemeProvider } from "../foundation/ThemeProvider.jsx";
import { syncState } from "../../lib/sync-state.js";
function Monitor() { useEffect(() => syncState.startMonitor(), []); return null; }

const SNAPSHOT = { generated_at: "2026-10-27T00:00:00.000Z", price_version: "test", tz: "UTC", filters: {} };

function lastRun(status) {
  return { status, started_at: "2026-10-27T00:00:00.000Z", finished_at: status === "running" ? null : "2026-10-27T00:00:05.000Z",
    attempted: 0, inserted: 0, updated: 0, unchanged: 0, rejected: 0, anomaly_count: 0, anomalies: [] };
}

/** /sources 前 runningCalls 次报告 running，之后报告 ok。 */
function mockApi(runningCalls) {
  let sourcesCalls = 0;
  return vi.fn(async (url) => {
    const path = String(url);
    let body;
    if (path.includes("/sources")) {
      sourcesCalls += 1;
      body = { sources: [], last_run: lastRun(sourcesCalls <= runningCalls ? "running" : "ok"), snapshot: SNAPSHOT };
    } else {
      body = { by: "source", groups: [], totals: { gross_tokens: 0 }, snapshot: SNAPSHOT };
    }
    return new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
  });
}

describe("侧栏同步状态", () => {
  beforeEach(() => {
    document.head.innerHTML = '<meta name="lens-api-token" content="t">';
    window.localStorage.clear();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("打开时已有同步在跑：显示「正在同步」，结束后推进版本并刷新", async () => {
    vi.stubGlobal("fetch", mockApi(2));
    const done = vi.fn();
    const initialVersion = syncState.getSnapshot().version;
    const unsubscribe = syncState.subscribe(() => { if (syncState.getSnapshot().version > initialVersion) done(); });
    try {
      render(
        <MemoryRouter initialEntries={["/dashboard"]}>
          <ThemeProvider>
            <AppLayout><Monitor /></AppLayout>
          </ThemeProvider>
        </MemoryRouter>
      );
      expect((await screen.findAllByText("正在同步")).length).toBeGreaterThan(0);
      await waitFor(() => expect(done).toHaveBeenCalled(), { timeout: 8000 });
      await waitFor(() => expect(screen.queryByText("正在同步")).toBeNull(), { timeout: 3000 });
    } finally {
      unsubscribe();
    }
  }, 15_000);
});
