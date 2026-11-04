import React from "react";
import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { MemoryRouter, useLocation, useNavigate } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AppLayout } from "../../ui/components/Sidebar.jsx";
import { ThemeProvider } from "../../ui/foundation/ThemeProvider.jsx";
import { HomePage } from "./HomePage.jsx";
import { SessionsPage } from "./SessionsPage.jsx";
import { SourcesPage } from "./SourcesPage.jsx";
import { SettingsPage } from "./SettingsPage.jsx";
import { syncState, SYNC_IDLE_MS, SYNC_WAIT_MS } from "../../lib/sync-state.js";
import { deferred, json, ledgerFixture, run } from "../../test/ledger-fixture.js";

function TestNav({ to }) {
  const navigate = useNavigate();
  return <><button onClick={() => navigate(to)}>切换测试筛选</button><button onClick={() => navigate(-1)}>返回测试筛选</button></>;
}
function Monitor() { React.useEffect(() => syncState.startMonitor(), []); return null; }

function Pages() {
  const { pathname } = useLocation();
  return pathname === "/sessions" ? <SessionsPage /> : pathname === "/sources" ? <SourcesPage />
    : pathname === "/settings" ? <SettingsPage /> : <HomePage />;
}
function mount(path, extra = null) {
  return render(<ThemeProvider><MemoryRouter initialEntries={[path]}><AppLayout>{extra}<Pages /></AppLayout></MemoryRouter></ThemeProvider>);
}
function syncButton() { return screen.getAllByRole("button", { name: "立即同步" })[0]; }
function main() { return within(screen.getByRole("main")); }

describe("R5 窗口同步", () => {
  let fixture;
  beforeEach(() => {
    window.localStorage.clear();
    document.head.innerHTML = '<meta name="lens-api-token" content="fixture">';
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date(2026, 9, 21, 15));
    vi.stubGlobal("requestIdleCallback", vi.fn(() => 1));
    vi.stubGlobal("cancelIdleCallback", vi.fn());
    fixture = ledgerFixture();
    vi.stubGlobal("fetch", fixture.fetch);
  });
  afterEach(() => { cleanup(); vi.useRealTimers(); vi.unstubAllGlobals(); });

  it.each(["/sources", "/dashboard"])("B2-1 %s 异常完成刷新页面并展示成功警告", async path => {
    fixture.state.intercept = u => {
      if (!u.pathname.endsWith("/sync")) return;
      fixture.state.generation = 1;
      fixture.state.lastRun = run("completed_with_anomalies", 2, { anomalies: ["read_failed: fixture warning"] });
      return json({ ...fixture.state.lastRun, fileCount: 1, durationMs: 1 });
    };
    mount(path, <Monitor />);
    await waitFor(() => expect(document.querySelector("[aria-busy='true']")).toBeNull());
    fireEvent.click(syncButton());
    await screen.findAllByText(/同步完成，有异常警告/);
    expect(screen.getAllByText(/read_failed: fixture warning/).length).toBeGreaterThan(0);
    expect(screen.queryByText("上次同步没有完成。")).toBeNull();
    expect(screen.queryByText("上次同步失败")).toBeNull();
    if (path === "/sources") await main().findByText(/4,321 条记录/);
    else await main().findAllByTitle("4,321 token");
    expect(syncState.getSnapshot().phase).toBe("success");
  });

  it("B2-4 等待超时后点击侧栏同步会重新 POST", async () => {
    vi.useRealTimers(); vi.useFakeTimers();
    mount("/sources", <Monitor />);
    await act(async () => { await vi.advanceTimersByTimeAsync(0); });
    fixture.state.intercept = u => u.pathname.endsWith("/sync") ? json({ error: { code: "sync_in_progress" } }, 409) : undefined;
    fireEvent.click(syncButton());
    await act(async () => { await vi.advanceTimersByTimeAsync(SYNC_WAIT_MS); });
    expect(syncState.getSnapshot().phase).toBe("timed_out");
    fixture.state.intercept = null;
    fireEvent.click(syncButton());
    await act(async () => { await vi.advanceTimersByTimeAsync(0); });
    expect(fixture.fetch.mock.calls.filter(([, init]) => init.method === "POST")).toHaveLength(2);
    expect(main().getByText(/4,321 条记录/)).toBeInTheDocument();
  });

  it("T01 切本月后同步使用本月查询并显示新值", async () => {
    mount("/dashboard?period=week");
    await main().findAllByTitle("1,234 token");
    fireEvent.click(screen.getByRole("tab", { name: "本月" }));
    await waitFor(() => expect(screen.getByRole("tab", { name: "本月" })).toHaveAttribute("aria-selected", "true"));
    await waitFor(() => expect(document.querySelector("[aria-busy='true']")).toBeNull());
    const start = fixture.fetch.mock.calls.length;
    fireEvent.click(syncButton());
    await main().findAllByTitle("4,321 token");
    const summaries = fixture.fetch.mock.calls.slice(start).map(([u]) => new URL(u))
      .filter(u => u.pathname.endsWith("/summary"));
    expect(summaries.some(u => u.searchParams.get("from") === "2026-10-01")).toBe(true);
    expect(summaries.some(u => u.searchParams.get("from") === "2026-10-19")).toBe(false);
  });

  it.each(["/dashboard?view=detail&period=month", "/sessions", "/sources", "/settings"])
    ("T02 %s 从侧栏同步刷新实际页面", async path => {
      mount(path);
      await waitFor(() => expect(fixture.fetch.mock.calls.length).toBeGreaterThan(2));
      fireEvent.click(syncButton());
      if (path === "/sessions") await main().findByText("new-first");
      else if (path === "/sources") await main().findByText(/4,321 条记录/);
      else await waitFor(() => expect(main().getAllByText(/4[,.]321/).length).toBeGreaterThan(0));
    });

  it("T04 同步清除旧分页并从第一页重新开始", async () => {
    mount("/sessions?tool=codex&project=D%3A%2Ffixture");
    await main().findByText("old-first");
    fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
    await main().findByText("old-second");
    fireEvent.click(syncButton());
    await main().findByText("new-first");
    expect(main().queryByText("old-second")).toBeNull();
    expect(main().queryByText("new-second")).toBeNull();
    const listCalls = fixture.fetch.mock.calls.map(([u]) => new URL(u)).filter(u => u.pathname.endsWith("/sessions"));
    expect(listCalls.at(-1).searchParams.get("cursor")).toBeNull();
    expect(listCalls.at(-1).searchParams.get("source")).toBe("codex");
    fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
    await main().findByText("new-second");
  });

  it("T10 POST 失败不能由旧 ok 掩盖，可以重试", async () => {
    fixture.state.intercept = u => u.pathname.endsWith("/sync") ? json({ error: { code: "internal", message: "本次采集失败" } }, 500) : undefined;
    mount("/sessions");
    await main().findByText("old-first");
    fireEvent.click(syncButton());
    await screen.findByText(/本次采集失败/);
    fixture.state.intercept = null;
    fireEvent.click(syncButton());
    await main().findByText("new-first");
  });

  it("T11 工具页与侧栏共享在途互斥", async () => {
    const gate = deferred();
    fixture.state.intercept = u => u.pathname.endsWith("/sync") ? gate.promise : undefined;
    mount("/sources");
    await main().findByText(/1,234 条记录/);
    fireEvent.click(syncButton());
    const pageButton = main().getByRole("button", { name: /同步/ });
    fireEvent.click(pageButton);
    await waitFor(() => expect(fixture.fetch.mock.calls.filter(([u]) => new URL(u).pathname.endsWith("/sync"))).toHaveLength(1));
    await act(async () => gate.resolve(json({ inserted: 1, fileCount: 1, durationMs: 1 })));
  });

  it("T03 详细筛选同步保留全部当前参数并拒绝旧筛选迟到", async () => {
    const old = deferred();
    const base = "/dashboard?view=detail&period=month&tool=codex&model=gpt-6&dim=model&bucket=2026-10-20";
    fixture.state.intercept = u => u.pathname.endsWith("/summary") && u.searchParams.get("project") === "old" ? old.promise : undefined;
    mount(`${base}&project=old`, <TestNav to={`${base}&project=new`} />);
    await waitFor(() => expect(fixture.fetch.mock.calls.some(([u]) => new URL(u).searchParams.get("project") === "old")).toBe(true));
    fireEvent.click(screen.getByRole("button", { name: "切换测试筛选" }));
    await main().findAllByText(/1,234/);
    const start = fixture.fetch.mock.calls.length;
    fireEvent.click(syncButton());
    await main().findAllByText(/4,321/);
    const calls = fixture.fetch.mock.calls.slice(start).map(([u]) => new URL(u));
    for (const u of calls.filter(u => u.pathname.endsWith("/summary") || u.pathname.endsWith("/matrix") || u.searchParams.get("by") === "source_model" && u.searchParams.has("project"))) {
      expect(u.searchParams.get("source")).toBe("codex");
      expect(u.searchParams.get("model")).toBe("gpt-6");
      expect(u.searchParams.get("project")).toBe("new");
    }
    expect(calls.some(u => u.pathname.endsWith("/summary") && u.searchParams.get("from") === "2026-10-20")).toBe(true);
    await act(async () => old.resolve(json({ totals: { gross_tokens: 99999 } })));
    expect(main().queryByText(/99,999/)).toBeNull();
  });

  it("T05 URL 前进和后退不复用旧 cursor/history", async () => {
    mount("/sessions?tool=codex", <TestNav to="/sessions?tool=claude&project=next" />);
    await main().findByText("old-first");
    fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
    await main().findByText("old-second");
    fireEvent.click(screen.getByRole("button", { name: "切换测试筛选" }));
    await main().findByText("old-first");
    expect(main().queryByText("old-second")).toBeNull();
    let last = fixture.fetch.mock.calls.map(([u]) => new URL(u)).filter(u => u.pathname.endsWith("/sessions")).at(-1);
    expect(last.searchParams.get("source")).toBe("claude");
    expect(last.searchParams.get("cursor")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "返回测试筛选" }));
    await waitFor(() => {
      last = fixture.fetch.mock.calls.map(([u]) => new URL(u)).filter(u => u.pathname.endsWith("/sessions")).at(-1);
      expect(last.searchParams.get("source")).toBe("codex");
    });
    expect(last.searchParams.get("cursor")).toBeNull();
  });

  it("T08 同周期同步等全部新版数据到齐才替换快照，刷新失败可重试", async () => {
    mount("/dashboard?period=month");
    await main().findAllByTitle("1,234 token");
    const gate = deferred();
    fixture.state.intercept = u => fixture.state.generation && u.pathname.endsWith("/breakdown") && u.searchParams.get("by") === "source_model" ? gate.promise : undefined;
    fireEvent.click(syncButton());
    await waitFor(() => expect(fixture.state.generation).toBe(1));
    const hero = main().getByText("这个月用量").parentElement;
    expect(within(hero).queryByTitle("4,321 token")).toBeNull();
    expect(within(hero).getByTitle("1,234 token")).toBeInTheDocument();
    await act(async () => gate.resolve(json({ error: { code: "read_failed", message: "新排行读取失败" } }, 500)));
    await main().findByText("新排行读取失败");
    fixture.state.intercept = null;
    fireEvent.click(main().getByRole("button", { name: "重试" }));
    await main().findAllByTitle("4,321 token");
    expect(fixture.fetch.mock.calls.filter(([u]) => new URL(u).pathname.endsWith("/sync"))).toHaveLength(1);
  });

  it.each([["/sources", "source"], ["/settings", "source_model"], ["/dashboard?view=detail", "project"], ["/sessions", "project"]])
    ("T09 %s 派生查询失败可见并仅 GET 重试", async (path, by) => {
      fixture.state.intercept = u => u.pathname.endsWith("/breakdown") && u.searchParams.get("by") === by ? json({ error: { code: "read_failed", message: "派生用量读取失败" } }, 500) : undefined;
      mount(path);
      await main().findByText("派生用量读取失败");
      fixture.state.intercept = null;
      fireEvent.click(main().getByRole("button", { name: "重试" }));
      await waitFor(() => expect(main().queryByText("派生用量读取失败")).toBeNull());
      expect(fixture.fetch.mock.calls.every(([, init]) => init.method === "GET")).toBe(true);
    });

  it("T12 冲突在侧栏与工具页可见，终态完成后刷新两边", async () => {
    mount("/sources", <Monitor />);
    await main().findByText(/1,234 条记录/);
    fixture.state.intercept = u => u.pathname.endsWith("/sync") ? json({ error: { code: "sync_in_progress", message: "已有同步在执行" } }, 409) : undefined;
    fireEvent.click(syncButton());
    await main().findByText("已有同步在执行，正在等待完成");
    expect(screen.getAllByText("已有同步在执行，正在等待完成").length).toBe(2);
    fixture.state.generation = 1;
    fixture.state.lastRun = run("ok", 4);
    await act(async () => { await syncState.retryStatus(); });
    await main().findByText(/4,321 条记录/);
    expect(fixture.fetch.mock.calls.filter(([u]) => new URL(u).pathname.endsWith("/sync"))).toHaveLength(1);
  });

  it("T14 定时运行从未见 running 的完成也让实际会话页刷新", async () => {
    vi.useRealTimers();
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2026, 9, 21, 15));
    mount("/sessions", <Monitor />);
    await act(async () => { await vi.advanceTimersByTimeAsync(0); });
    expect(main().getByText("old-first")).toBeInTheDocument();
    fixture.state.generation = 1;
    fixture.state.lastRun = run("ok", 7);
    await act(async () => { await vi.advanceTimersByTimeAsync(SYNC_IDLE_MS); });
    expect(main().getByText("new-first")).toBeInTheDocument();
  });

  it("T02 首页年度用量、最近会话与展开详情随版本刷新", async () => {
    mount("/dashboard?period=month", <TestNav to="/sessions?source=codex&session=first" />);
    await main().findByText("old-first");
    const start = fixture.fetch.mock.calls.length;
    fireEvent.click(syncButton());
    await main().findByText("new-first");
    const calls = fixture.fetch.mock.calls.slice(start).map(([u]) => new URL(u));
    expect(calls.some(u => u.pathname.endsWith("/timeseries") && u.searchParams.get("from") === "2025-10-22")).toBe(true);
    expect(calls.some(u => u.pathname.endsWith("/breakdown") && u.searchParams.get("from") === "2025-10-22")).toBe(true);
    expect(calls.some(u => u.pathname.endsWith("/sessions") && u.searchParams.get("limit") === "5")).toBe(true);
    fireEvent.click(screen.getByRole("button", { name: "切换测试筛选" }));
    const dialog = await screen.findByRole("dialog");
    await within(dialog).findByTitle("4,321 token");
    fixture.state.intercept = u => u.pathname.endsWith("/sessions/detail") ? json({ ...fixture.body(u), session: { ...fixture.item("first"), gross_tokens: 8765 } }) : undefined;
    fireEvent.click(syncButton());
    await within(dialog).findByTitle("8,765 token");
  });

  it("T04 旧第二页在同步之后迟到也不能拼回新第一页", async () => {
    const oldPage = deferred();
    fixture.state.intercept = u => u.pathname.endsWith("/sessions") && u.searchParams.has("cursor") && !fixture.state.generation ? oldPage.promise : undefined;
    mount("/sessions");
    await main().findByText("old-first");
    fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
    await waitFor(() => expect(fixture.fetch.mock.calls.some(([u]) => new URL(u).searchParams.has("cursor"))).toBe(true));
    fireEvent.click(syncButton());
    await main().findByText("new-first");
    await act(async () => oldPage.resolve(json({ items: [{ ...fixture.item("second"), project_key: "D:/fixture/old-second" }], next_cursor: null })));
    expect(main().queryByText("old-second")).toBeNull();
    expect(main().getByText("new-first")).toBeInTheDocument();
  });

  it("T13 状态检查失败可见，重新检查不重发 POST", async () => {
    let conflict = false;
    fixture.state.intercept = u => {
      if (u.pathname.endsWith("/sync")) { conflict = true; return json({ error: { code: "sync_in_progress", message: "已有同步在执行" } }, 409); }
      if (conflict && u.pathname.endsWith("/sources")) return Promise.reject(new Error("status offline"));
    };
    mount("/sources", <Monitor />);
    await main().findByText(/1,234 条记录/);
    fireEvent.click(syncButton());
    await main().findByText(/无法确认同步状态/);
    fixture.state.intercept = null;
    fixture.state.generation = 1;
    fixture.state.lastRun = run("ok", 9);
    fireEvent.click(syncButton());
    await main().findByText(/4,321 条记录/);
    expect(fixture.fetch.mock.calls.filter(([u]) => new URL(u).pathname.endsWith("/sync"))).toHaveLength(1);
  });

  it("T09 侧栏账本读取失败可见，能单独重试读取", async () => {
    fixture.state.intercept = u => u.pathname.endsWith("/breakdown") && u.searchParams.get("by") === "source" ? json({ error: { code: "read_failed", message: "侧栏用量读取失败" } }, 500) : undefined;
    mount("/sessions");
    await screen.findByText(/侧栏用量读取失败/);
    fixture.state.intercept = null;
    fireEvent.click(screen.getByRole("button", { name: "重试读取" }));
    await waitFor(() => expect(screen.queryByText(/侧栏用量读取失败/)).toBeNull());
    expect(fixture.fetch.mock.calls.every(([, init]) => init.method === "GET")).toBe(true);
  });

  it("T09 年度工具读取失败可见并能重试", async () => {
    fixture.state.intercept = u => u.pathname.endsWith("/breakdown") && u.searchParams.get("from") === "2025-10-22" ? json({ error: { code: "read_failed", message: "年度工具读取失败" } }, 500) : undefined;
    mount("/dashboard?period=month");
    await main().findByText("年度工具读取失败");
    fixture.state.intercept = null;
    fireEvent.click(main().getByRole("button", { name: "重试" }));
    await waitFor(() => expect(main().queryByText("年度工具读取失败")).toBeNull());
  });

  it("T08 展开详情保留旧内容时明确标出正在刷新", async () => {
    mount("/sessions?source=codex&session=first");
    const dialog = await screen.findByRole("dialog");
    await within(dialog).findByTitle("1,234 token");
    const gate = deferred();
    fixture.state.intercept = u => fixture.state.generation && u.pathname.endsWith("/sessions/detail") ? gate.promise : undefined;
    fireEvent.click(syncButton());
    await within(dialog).findByRole("progressbar", { name: "正在加载" });
    await act(async () => gate.resolve(json(fixture.body(new URL("/api/v1/sessions/detail?session_id=first", location.origin)))));
    await within(dialog).findByTitle("4,321 token");
  });
});
