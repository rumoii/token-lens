import React from "react";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { HomePage } from "./HomePage.jsx";
import { TrendChart } from "./TrendChart.jsx";
import { TokenFormatContext } from "../../ui/foundation/TokenFormatProvider.jsx";
import * as tween from "../../lib/use-tween";

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
    ...over,
  };
}

function summaryOf(gross, over = {}) {
  return {
    totals: totals({ gross_tokens: gross, cost_usd: "10.000000", record_count: 5 }),
    activity: { sessions: 3, turns: 5, cache_hit_ratio: 0.5, first_seen: "2026-10-01T00:00:00.000Z", last_seen: null, active_span_ms: null, ...over },
    rolling: { last_7d: { gross_tokens: 0, cost_usd: null }, last_30d: { gross_tokens: 0, cost_usd: null } },
    snapshot: SNAPSHOT,
  };
}

/**
 * 按路径和 from 参数路由。`hold` 里的路径会挂起，直到测试手动放行。
 */
function stubApi(routes, hold = new Map()) {
  const fn = vi.fn(async (url) => {
    const u = new URL(String(url));
    const key = `${u.pathname.replace("/api/v1", "")}?by=${u.searchParams.get("by") ?? ""}&from=${u.searchParams.get("from") ?? ""}`;
    const gate = [...hold.entries()].find(([prefix]) => key.startsWith(prefix));
    if (gate) await gate[1].promise;
    const body = routes(u);
    return new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
  });
  vi.stubGlobal("fetch", fn);
  return fn;
}

function deferred() {
  let resolve;
  const promise = new Promise((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

/** 本周（10-19 起）DSH 占 45%、Claude 35%、Codex 20%；本月总量翻倍。 */
function routes(u) {
  const path = u.pathname.replace("/api/v1", "");
  const from = u.searchParams.get("from");
  const month = from === "2026-10-01";
  const scale = month ? 2 : 1;
  if (path === "/usage/summary") return summaryOf(1000 * scale);
  if (path === "/usage/breakdown") {
    return {
      by: "source_model",
      groups: [
        { key: "deepseek-flash", source: "dsh", model: "deepseek-flash", ...totals({ gross_tokens: 450 * scale, cost_usd: "1.000000" }) },
        { key: "claude-opus-5-5", source: "claude", model: "claude-opus-5-5", ...totals({ gross_tokens: 350 * scale, cost_usd: "8.000000" }) },
        { key: "gpt-6.1-sol", source: "codex", model: "gpt-6.1-sol", ...totals({ gross_tokens: 200 * scale, cost_usd: "1.000000" }) },
      ],
      totals: totals({ gross_tokens: 1000 * scale }),
      snapshot: SNAPSHOT,
    };
  }
  if (path === "/usage/timeseries") {
    return { granularity: "day", points: [{ bucket: "2026-10-20", ...totals({ gross_tokens: 550 * scale }) }], unallocated: null, snapshot: SNAPSHOT };
  }
  if (path === "/usage/matrix") {
    return {
      granularity: "day",
      by: "source",
      rows: [
        { bucket: "2026-10-20", key: "claude", ...totals({ gross_tokens: 350 * scale }) },
        { bucket: "2026-10-20", key: "codex", ...totals({ gross_tokens: 200 * scale }) },
      ],
      unallocated: { ...totals({ gross_tokens: 450 * scale }), reason: "cumulative_without_time_distribution" },
      snapshot: SNAPSHOT,
    };
  }
  if (path === "/sessions") return { items: [], next_cursor: null, snapshot: SNAPSHOT };
  if (path === "/sources") return { sources: [], last_run: null, snapshot: SNAPSHOT };
  if (path === "/pricing") return { price_version: "pv", verified_at: null, currency: "USD", provisional: true, models: [], snapshot: SNAPSHOT };
  return {};
}

describe("HomePage", () => {
  beforeEach(() => {
    document.head.innerHTML = '<meta name="lens-api-token" content="t">';
    window.localStorage.clear();
    // 只冻结日期：2026-10-21 周三。计时器照常走，异步查询不受影响
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date(2026, 9, 21, 15, 0, 0));
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it("概览主数字的数值和单位遵循英文设置", async () => {
    vi.spyOn(tween, "useTween").mockImplementation((value) => value);
    stubApi((u) => u.pathname.endsWith("/usage/summary") ? summaryOf(1200000) : routes(u));
    render(<MemoryRouter initialEntries={["/dashboard?period=week"]}>
      <TokenFormatContext.Provider value={{ unitSystem: "english" }}><HomePage /></TokenFormatContext.Provider>
    </MemoryRouter>);
    const number = await screen.findByTitle("1,200,000 token");
    expect(number.textContent).toBe("1.2Mtoken");
    expect(number.querySelector("span")).toHaveTextContent("M");
  });

  it("占比不过半时不说「大部分」，活跃天数只算到今天，快照用量单独说明", async () => {
    stubApi(routes);
    render(
      <MemoryRouter initialEntries={["/dashboard?period=week"]}>
        <HomePage />
      </MemoryRouter>,
    );

    expect(await screen.findByText(/用得最多的是/)).toBeInTheDocument();
    expect(screen.queryByText(/大部分花在/)).toBeNull();
    // 周三：本周已过 3 天，其中 1 天有用量
    expect(screen.getByText(/\/ 3 天/)).toBeInTheDocument();
    expect(screen.getByText(/来自跨天的会话快照/)).toBeInTheDocument();
    // 本周固定 7 个槽
    expect(document.querySelectorAll("[data-bucket]")).toHaveLength(7);
  });

  it("切周期时，新数据没到齐前保持上一个周期的完整画面", async () => {
    const pairsGate = deferred();
    stubApi(routes, new Map([["/usage/breakdown?by=source_model&from=2026-10-01", pairsGate]]));
    render(
      <MemoryRouter initialEntries={["/dashboard?period=week"]}>
        <HomePage />
      </MemoryRouter>,
    );
    await screen.findByText(/用得最多的是/);
    expect(screen.getAllByTitle("1,000 token").length).toBeGreaterThan(0);

    await userEvent.click(screen.getByRole("tab", { name: "本月" }));
    // 本月的 summary 已经回来，但工具排行还没到：仍显示本周，不混算
    await waitFor(() => expect(document.querySelector("[aria-busy='true']")).not.toBeNull());
    expect(screen.queryByTitle("2,000 token")).toBeNull();
    expect(screen.getAllByTitle("1,000 token").length).toBeGreaterThan(0);

    await act(async () => pairsGate.resolve());
    expect((await screen.findAllByTitle("2,000 token")).length).toBeGreaterThan(0);
    expect(document.querySelector("[aria-busy='true']")).toBeNull();
    expect(window.localStorage.getItem("token-lens-period")).toBe("period=month");
  });
});

describe("HomePage 原型 v2 选定的方案", () => {
  beforeEach(() => {
    document.head.innerHTML = '<meta name="lens-api-token" content="t">';
    window.localStorage.clear();
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date(2026, 9, 21, 15, 30, 0));
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it("D3：总结句只讲结论，不重复大数字", async () => {
    stubApi(routes);
    render(
      <MemoryRouter initialEntries={["/dashboard?period=week"]}>
        <HomePage />
      </MemoryRouter>,
    );
    // 本周和上周同样 1000：说「差不多」，数字只在大数字里出现
    const line = await screen.findByText(/和上周差不多/);
    expect(line.textContent).not.toMatch(/token|\$|%/);
    expect(line.textContent).toMatch(/其次是/);
  });

  it("B7：今天视图换成「最忙的一小时」和「这一小时」", async () => {
    stubApi(routes);
    render(
      <MemoryRouter initialEntries={["/dashboard?period=today"]}>
        <HomePage />
      </MemoryRouter>,
    );
    expect(await screen.findByText("最忙的一小时")).toBeInTheDocument();
    expect(screen.getByText("这一小时")).toBeInTheDocument();
    expect(screen.queryByText("日均用量")).toBeNull();
    expect(screen.queryByText("活跃天数")).toBeNull();
  });

  it("D8：新用户的「这一年」写明从哪天开始记录，下面有年度小结", async () => {
    stubApi(routes);
    render(
      <MemoryRouter initialEntries={["/dashboard?period=week"]}>
        <HomePage />
      </MemoryRouter>,
    );
    expect(await screen.findByText(/从 10 月 20 日开始记录/)).toBeInTheDocument();
    expect(screen.getByText("到现在一共")).toBeInTheDocument();
    expect(screen.getByText("最忙的一天")).toBeInTheDocument();
  });

  it("工具排行和常用模型都链到带筛选的明细", async () => {
    stubApi(routes);
    render(
      <MemoryRouter initialEntries={["/dashboard?period=week"]}>
        <HomePage />
      </MemoryRouter>,
    );
    const toolLink = await screen.findByTitle("看 DSH 的明细");
    expect(toolLink.getAttribute("href")).toBe("/dashboard?period=week&view=detail&tool=dsh&dim=model");
    expect(screen.getByTitle("看 deepseek-flash 的明细").getAttribute("href")).toContain("model=deepseek-flash");
  });
});

describe("TrendChart", () => {
  const buckets = [
    { bucket: "2026-10-19", by: new Map([["claude", 10]]), total: 10, cost: 1, future: false },
    { bucket: "2026-10-20", by: new Map([["claude", 20]]), total: 20, cost: 2, future: false },
    { bucket: "2026-10-21", by: new Map(), total: 0, cost: null, future: true },
  ];

  it("鼠标移出后收起提示", () => {
    render(<TrendChart buckets={buckets} order={["claude"]} colorOf={() => "red"} granularity="day" />);
    fireEvent.mouseEnter(document.querySelector("[data-bucket='2026-10-20']"));
    expect(screen.getByRole("tooltip")).toBeInTheDocument();
    fireEvent.mouseLeave(screen.getByRole("group"));
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it("键盘：聚焦显示最后一个有数据的时段，方向键移动，失焦收起", () => {
    render(<TrendChart buckets={buckets} order={["claude"]} colorOf={() => "red"} granularity="day" />);
    const chart = screen.getByRole("group");
    fireEvent.focus(chart);
    expect(screen.getByRole("tooltip")).toHaveTextContent("10月20日");
    fireEvent.keyDown(chart, { key: "ArrowRight" });
    expect(screen.getByRole("tooltip")).toHaveTextContent("还没到");
    fireEvent.keyDown(chart, { key: "ArrowLeft" });
    fireEvent.keyDown(chart, { key: "ArrowLeft" });
    expect(screen.getByRole("tooltip")).toHaveTextContent("10月19日");
    fireEvent.blur(chart);
    expect(screen.queryByRole("tooltip")).toBeNull();
  });
});
