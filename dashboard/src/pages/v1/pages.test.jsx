import React from "react";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SessionsPage } from "./SessionsPage.jsx";
import { SourcesPage } from "./SourcesPage.jsx";
import { SettingsPage } from "./SettingsPage.jsx";
import { ThemeProvider } from "../../ui/foundation/ThemeProvider.jsx";

const SNAPSHOT = { generated_at: "2026-10-18T00:00:00.000Z", price_version: "pv", tz: "UTC", filters: {} };
const ACTIVITY = {
  sessions: 0,
  turns: 0,
  cache_hit_ratio: null,
  first_seen: null,
  last_seen: null,
  active_span_ms: null
};

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

/**
 * @param {(path: string) => { status?: number, body: any }} route
 */
function stubFetch(route) {
  const fn = vi.fn(async (url) => {
    const { status = 200, body } = route(String(url));
    return new Response(JSON.stringify(body), {
      status,
      headers: { "Content-Type": "application/json" },
    });
  });
  vi.stubGlobal("fetch", fn);
  return fn;
}

describe("v1 pages", () => {
  beforeEach(() => {
    document.head.innerHTML = '<meta name="lens-api-token" content="t">';
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("会话页：空列表给出空态", async () => {
    stubFetch(() => ({ body: { items: [], next_cursor: null, snapshot: SNAPSHOT } }));
    render(<MemoryRouter><SessionsPage /></MemoryRouter>);
    expect(await screen.findByText("还没有会话")).toBeInTheDocument();
  });

  it("会话页：有下一页时出现加载更多", async () => {
    stubFetch(() => ({
      body: {
        items: [{ session_id: "s1", source: "codex", project_key: null, started_at: "2026-10-10T00:00:00.000Z", last_seen_at: "2026-10-10T01:00:00.000Z", gross_tokens: 42, cost_usd: "1.500000", record_count: 1 }],
        next_cursor: "next",
        snapshot: SNAPSHOT,
      },
    }));

    render(<MemoryRouter><SessionsPage /></MemoryRouter>);

    // 标题用项目名；没有工作目录时写明，会话 ID 只放进详情
    expect(await screen.findByText("没有记录项目")).toBeInTheDocument();
    expect(screen.queryByText("s1")).toBeNull();
    expect(screen.getByRole("button", { name: "加载更多" })).toBeInTheDocument();
  });

  it("会话页：带 ?source=&session= 进来时直接打开那条会话", async () => {
    const fetchFn = stubFetch((path) => {
      if (path.includes("/sessions/detail")) {
        return {
          body: {
            session: { source: "codex", session_id: "s9", project_key: null, started_at: "2026-10-10T00:00:00.000Z", last_seen_at: "2026-10-10T01:00:00.000Z", ...totals({ gross_tokens: 5, record_count: 1 }) },
            models: [],
            timeline: [],
            kinds: { event: 1, cumulative: 0 },
            snapshot: SNAPSHOT,
          },
        };
      }
      return { body: { items: [], next_cursor: null, snapshot: SNAPSHOT } };
    });

    render(
      <MemoryRouter initialEntries={["/sessions?source=codex&session=s9"]}>
        <SessionsPage />
      </MemoryRouter>,
    );

    expect(await screen.findByRole("dialog")).toBeInTheDocument();
    await waitFor(() =>
      expect(fetchFn.mock.calls.some(([url]) => String(url).includes("session_id=s9"))).toBe(true),
    );
  });

  it("来源页：同步成功后显示计数", async () => {
    stubFetch((path) => {
      if (path.includes("/sync")) {
        return { body: { attempted: 3, inserted: 2, updated: 1, unchanged: 0, rejected: 0, fileCount: 5, durationMs: 1200, anomalies: [] } };
      }
      return { body: { sources: [{ source: "codex", evidence: "A", status: "ok", last_observed_at: "2026-10-10T00:00:00.000Z", records: 3, limits: [] }], snapshot: SNAPSHOT } };
    });

    render(<MemoryRouter><SourcesPage /></MemoryRouter>);
    // 来源用友好名，不用小写 id；证据等级写成人话
    await screen.findByText("Codex");
    expect(screen.getByText("用真实日志核对过")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "立即同步" }));

    expect(await screen.findByText(/扫描 5 个文件，新增 2 条/)).toBeInTheDocument();
  });

  it("来源页：口径说明标出影响，没找到的工具折叠成一组", async () => {
    stubFetch(() => ({
      body: {
        sources: [
          {
            source: "dsh", evidence: "B", status: "ok", first_observed_at: null, last_observed_at: "2026-10-10T00:00:00.000Z",
            records: 3, record_mode: "cumulative", limits: ["累计型：一个会话只有一条快照"],
            notes: [{ text: "只记录每个会话的总数。", impact: "affects" }]
          }
        ],
        last_run: null,
        snapshot: SNAPSHOT
      }
    }));
    render(<MemoryRouter><SourcesPage /></MemoryRouter>);
    expect(await screen.findByText("只记录每个会话的总数。")).toBeInTheDocument();
    expect(screen.getByText("有影响")).toBeInTheDocument();
    expect(screen.getAllByText("只记录每个会话的总数").length).toBeGreaterThan(0);
    await userEvent.click(screen.getByRole("button", { name: /还有 24 个支持的工具/ }));
    expect(screen.getByText("Claude Code")).toBeInTheDocument();
  });

  it("来源页：显示日志留存与自检，没有异常的项不列出", async () => {
    stubFetch(() => ({
      body: {
        sources: [
          {
            source: "claude", evidence: "A", status: "ok", first_observed_at: null, last_observed_at: "2026-10-10T00:00:00.000Z",
            records: 10, record_mode: "event", limits: [], notes: [],
            retention: { reviewable: 4, logs_gone: 6 },
            checks: { time_out_of_range: 0, huge_requests: 0, null_model: 3, mixed_kind_sessions: 0 }
          },
          {
            source: "codex", evidence: "A", status: "ok", first_observed_at: null, last_observed_at: "2026-10-10T00:00:00.000Z",
            records: 5, record_mode: "event", limits: [], notes: [],
            retention: { reviewable: 5, logs_gone: 0 },
            checks: { time_out_of_range: 0, huge_requests: 0, null_model: 0, mixed_kind_sessions: 0 }
          }
        ],
        last_run: null,
        snapshot: SNAPSHOT
      }
    }));
    render(<MemoryRouter><SourcesPage /></MemoryRouter>);
    expect(await screen.findByText("4 条还能对照原始日志复核")).toBeInTheDocument();
    expect(screen.getByText(/另有 6 条的日志已经不在了/)).toBeInTheDocument();
    expect(screen.getByText("没有模型名、不计价：3 条")).toBeInTheDocument();
    expect(screen.queryByText(/时间不在合理范围/)).not.toBeInTheDocument();
    expect(screen.getByText("全部记录都还能对照原始日志复核")).toBeInTheDocument();
    expect(screen.getByText("没发现异常")).toBeInTheDocument();
  });

  it("来源页：409 明示冲突与等待", async () => {
    stubFetch((path) => {
      if (path.includes("/sync")) {
        return { status: 409, body: { error: { code: "sync_in_progress", message: "已有同步在执行" } } };
      }
      return { body: { sources: [], snapshot: SNAPSHOT } };
    });

    render(<MemoryRouter><SourcesPage /></MemoryRouter>);
    await userEvent.click(screen.getByRole("button", { name: "立即同步" }));

    expect(await screen.findByText(/已有同步在执行，正在等待完成/)).toBeInTheDocument();
  });

  it("来源页：接口失败可重试", async () => {
    const fn = stubFetch(() => ({ status: 500, body: { error: { code: "internal", message: "内部错误" } } }));

    render(<MemoryRouter><SourcesPage /></MemoryRouter>);

    expect(await screen.findByText(/加载失败（internal）/)).toBeInTheDocument();
    const before = fn.mock.calls.length;
    await userEvent.click(screen.getByRole("button", { name: "重试" }));
    await waitFor(() => expect(fn.mock.calls.length).toBeGreaterThan(before));
  });

  it("设置页：区分价格状态与计费方式", async () => {
    stubFetch((path) => {
      if (path.includes("/pricing")) {
        return {
          body: {
            price_version: "pv",
            verified_at: "2026-10-18",
            currency: "USD",
            provisional: true,
            models: [
              { model: "claude-opus-5-5", records: 10, state: "verified", billing: "metered", source_url: "https://a.example/p", note: null },
              { model: "gemini-3.8-flash", records: 5, state: "aggregate", billing: "metered", source_url: "https://m.example/i", note: null },
              { model: "mimo-v2.6-pro", records: 3, state: "aggregate", billing: "plan", source_url: "https://m.example/i", note: null },
              { model: "qwen3:8b", records: 1, state: "unknown", billing: "metered", source_url: null, note: null },
            ],
            counts: { verified: 1, aggregate: 2, unknown: 1 },
            snapshot: SNAPSHOT,
          },
        };
      }
      return { body: { ok: true, version: "1.0.0", port: 3456, data_dir: "/tmp/data" } };
    });

    render(<ThemeProvider><SettingsPage /></ThemeProvider>);

    // 价格状态用人话：已对照官方价 / 估算价 / 查不到价格（概览一张 + 每行一张）
    expect((await screen.findAllByText("已对照官方价")).length).toBeGreaterThanOrEqual(2);
    expect(screen.getAllByText("估算价").length).toBeGreaterThanOrEqual(3);
    expect(screen.getAllByText("查不到价格").length).toBeGreaterThanOrEqual(2);
    // 套餐与价格状态分开显示：mimo 一行既是套餐，也是估算价
    expect(screen.getByText("套餐")).toBeInTheDocument();
    // 价格表版本、端口收进「关于」，默认不展开
    expect(screen.queryByText(/127\.0\.0\.1/)).toBeNull();
    await userEvent.click(screen.getByRole("button", { name: "关于这台电脑上的 Token Lens" }));
    expect(await screen.findByText(/127\.0\.0\.1:3456/)).toBeInTheDocument();
  });
});









