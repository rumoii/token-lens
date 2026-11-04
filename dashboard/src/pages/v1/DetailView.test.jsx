import React from "react";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, useLocation } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { HomePage } from "./HomePage.jsx";

const SNAPSHOT = { generated_at: "2026-10-21T00:00:00.000Z", price_version: "pv", tz: "UTC", filters: {} };

function totals(over = {}) {
  return {
    gross_tokens: 0,
    input_tokens: 0,
    output_tokens: 0,
    cache_read_tokens: 0,
    cache_write_tokens: 0,
    cost_usd: "0.000000",
    unpriced_records: 0,
    record_count: 0,
    ...over
  };
}

function stub() {
  const fn = vi.fn(async (url) => {
    const u = new URL(String(url));
    const path = u.pathname.replace("/api/v1", "");
    const by = u.searchParams.get("by");
    let body = {};
    if (path === "/usage/summary") {
      body = {
        totals: totals({ gross_tokens: 300, record_count: 3 }),
        activity: { sessions: 2, turns: 3, cache_hit_ratio: 0.5, first_seen: "2026-10-19T00:00:00.000Z", last_seen: null, active_span_ms: null },
        rolling: { last_7d: { gross_tokens: 0, cost_usd: null }, last_30d: { gross_tokens: 0, cost_usd: null } },
        snapshot: SNAPSHOT
      };
    } else if (path === "/usage/breakdown" && by === "source_model") {
      body = {
        by,
        groups: [
          { key: "deepseek-flash", source: "dsh", model: "deepseek-flash", ...totals({ gross_tokens: 200 }) },
          { key: "gpt-6.1-sol", source: "codex", model: "gpt-6.1-sol", ...totals({ gross_tokens: 100 }) }
        ],
        totals: totals({ gross_tokens: 300 }),
        snapshot: SNAPSHOT
      };
    } else if (path === "/usage/breakdown") {
      body = {
        by,
        groups:
          by === "source"
            ? [
                { key: "dsh", ...totals({ gross_tokens: 200, cost_usd: null }) },
                { key: "codex", ...totals({ gross_tokens: 100, cost_usd: "2.000000" }) }
              ]
            : [{ key: "D:\\Workspace\\token-lens", ...totals({ gross_tokens: 300 }) }],
        totals: totals({ gross_tokens: 300 }),
        snapshot: SNAPSHOT
      };
    } else if (path === "/usage/timeseries") {
      body = {
        granularity: "day",
        points: [{ bucket: "2026-10-20", ...totals({ gross_tokens: 250 }) }],
        unallocated: { ...totals({ gross_tokens: 50 }), reason: "cumulative_without_time_distribution" },
        snapshot: SNAPSHOT
      };
    } else if (path === "/usage/matrix") {
      body = {
        granularity: "day",
        by: "source",
        rows: [{ bucket: "2026-10-20", key: "dsh", ...totals({ gross_tokens: 250 }) }],
        unallocated: null,
        snapshot: SNAPSHOT
      };
    } else if (path === "/sources") {
      body = { sources: [], last_run: null, snapshot: SNAPSHOT };
    }
    return new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
  });
  vi.stubGlobal("fetch", fn);
  return fn;
}

let location = null;
function Spy() {
  location = useLocation();
  return null;
}

function renderAt(url) {
  return render(
    <MemoryRouter initialEntries={[url]}>
      <HomePage />
      <Spy />
    </MemoryRouter>
  );
}

const urls = (fn, path) => fn.mock.calls.map(([u]) => new URL(String(u))).filter((u) => u.pathname.endsWith(path));

describe("明细视图", () => {
  beforeEach(() => {
    document.head.innerHTML = '<meta name="lens-api-token" content="t">';
    window.localStorage.clear();
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date(2026, 9, 21, 15, 0, 0));
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it("地址里的筛选带进每个请求，并显示成可去掉的标签", async () => {
    const fn = stub();
    renderAt("/dashboard?period=week&view=detail&tool=dsh&dim=tool");
    expect(await screen.findByRole("heading", { name: "明细" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "去掉工具筛选" })).toBeInTheDocument();
    await waitFor(() => expect(urls(fn, "/usage/summary").some((u) => u.searchParams.get("source") === "dsh")).toBe(true));
    expect(urls(fn, "/usage/matrix").every((u) => u.searchParams.get("source") === "dsh")).toBe(true);

    await userEvent.click(screen.getByRole("button", { name: "去掉工具筛选" }));
    await waitFor(() => expect(new URLSearchParams(location.search).get("tool")).toBeNull());
    expect(new URLSearchParams(location.search).get("view")).toBe("detail");
  });

  it("没有价格的金额写「未定价」；点一行把它加进筛选并换个拆法", async () => {
    stub();
    renderAt("/dashboard?period=week&view=detail&dim=tool");
    expect((await screen.findAllByText("未定价")).length).toBeGreaterThan(0);
    await userEvent.click(screen.getByText("Codex", { selector: "span" }));
    await waitFor(() => expect(new URLSearchParams(location.search).get("tool")).toBe("codex"));
    expect(new URLSearchParams(location.search).get("dim")).toBe("model");
  });

  it("按时间拆时，跨天的会话快照单独说明，不进表", async () => {
    stub();
    renderAt("/dashboard?period=week&view=detail");
    expect(await screen.findByText(/不在这张表里/)).toBeInTheDocument();
  });

  it("换周期时保留工具筛选，去掉旧周期里的那个时段", async () => {
    stub();
    renderAt("/dashboard?period=week&view=detail&tool=dsh&bucket=2026-10-20&dim=tool");
    await screen.findByRole("heading", { name: "明细" });
    await userEvent.click(screen.getByRole("tab", { name: "本月" }));
    await waitFor(() => expect(new URLSearchParams(location.search).get("period")).toBe("month"));
    const q = new URLSearchParams(location.search);
    expect(q.get("tool")).toBe("dsh");
    expect(q.get("bucket")).toBeNull();
  });

  it("页头的「概览」切回首页概览", async () => {
    stub();
    renderAt("/dashboard?period=week&view=detail&tool=dsh");
    await screen.findByRole("heading", { name: "明细" });
    await userEvent.click(screen.getByRole("tab", { name: "概览" }));
    await waitFor(() => expect(new URLSearchParams(location.search).get("view")).toBeNull());
  });
});
