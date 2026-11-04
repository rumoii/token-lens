import React, { useCallback } from "react";
import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { api } from "../../lib/v1";
import { syncState } from "../../lib/sync-state.js";
import { AsyncBlock, useResource, useToolColors } from "./shared.jsx";
import { deferred, json, ledgerFixture } from "../../test/ledger-fixture.js";

function Probe({ filter = "A", endpoint = "summary", onRender }) {
  const loader = useCallback(() => endpoint === "summary" ? api.summary({ source: filter }) : api.health(), [filter, endpoint]);
  const resource = useResource(loader, [loader], { ledger: endpoint !== "health" });
  const { key, ...block } = resource;
  onRender?.(resource.data?.marker);
  return <><output>{JSON.stringify({ value: resource.data?.marker, fresh: resource.fresh })}</output>
    <button onClick={resource.reload}>重新读取</button>
    <AsyncBlock {...block} onRetry={resource.reload}>{null}</AsyncBlock></>;
}
beforeEach(() => { vi.stubGlobal("fetch", ledgerFixture().fetch); });
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

it("T07 函数依赖变化与 A→B→A 迟到成功/失败只接受最新请求", async () => {
  const gates = [deferred(), deferred(), deferred()];
  let index = 0;
  vi.stubGlobal("fetch", vi.fn(() => gates[index++].promise));
  const view = render(<Probe filter="A" />);
  view.rerender(<Probe filter="B" />);
  await act(async () => gates[1].resolve(json({ marker: "B" })));
  await waitFor(() => expect(screen.getByRole("status").textContent).toContain('"fresh":true'));
  view.rerender(<Probe filter="A" />);
  expect(screen.getByRole("status").textContent).toContain('"fresh":false');
  expect(index).toBe(3);
  await act(async () => gates[2].resolve(json({ marker: "latest-A" })));
  await act(async () => gates[0].resolve(json({ marker: "old-A" })));
  expect(screen.getByRole("status").textContent).not.toContain("old-A");
  expect(screen.getByRole("status").textContent).toContain("latest-A");
});

it("T07 同步版本变动后旧成功和失败不能提交", async () => {
  const old = deferred();
  const fixture = ledgerFixture();
  let first = true;
  fixture.state.intercept = u => u.pathname.endsWith("/summary") ? (first ? (first = false, old.promise) : json({ marker: "new" })) : undefined;
  vi.stubGlobal("fetch", fixture.fetch);
  render(<Probe />);
  await act(async () => { await syncState.startSync(); });
  await waitFor(() => expect(screen.getByRole("status").textContent).toContain("new"));
  await act(async () => old.reject(new Error("old failure")));
  expect(screen.queryByText(/old failure/)).toBeNull();
  expect(screen.getByRole("status").textContent).toContain("new");
});

it("T09 GET 失败重试当前参数，不发 POST", async () => {
  const fetch = vi.fn().mockResolvedValueOnce(json({ error: { code: "read_failed", message: "读失败" } }, 500))
    .mockResolvedValueOnce(json({ marker: "recovered" }));
  vi.stubGlobal("fetch", fetch);
  render(<Probe filter="B" />);
  await screen.findByText("读失败");
  await act(async () => screen.getByRole("button", { name: "重试" }).click());
  expect(screen.getByRole("status").textContent).toContain("recovered");
  expect(fetch.mock.calls.every(([u, init]) => new URL(u).searchParams.get("source") === "B" && init.method === "GET")).toBe(true);
});

it("T16 卸载一个读者不取消另一个读者共享的 GET", async () => {
  const gate = deferred();
  const fetch = vi.fn(() => gate.promise);
  vi.stubGlobal("fetch", fetch);
  const a = render(<Probe />), b = render(<Probe />);
  a.unmount();
  await act(async () => gate.resolve(json({ marker: "shared" })));
  expect(fetch).toHaveBeenCalledTimes(1);
  expect(screen.getByRole("status").textContent).toContain("shared");
  b.unmount();
});

it("T17 health 不订阅账本版本也不联网更新外部状态", async () => {
  const fixture = ledgerFixture();
  vi.stubGlobal("fetch", fixture.fetch);
  render(<Probe endpoint="health" />);
  await waitFor(() => expect(fixture.fetch).toHaveBeenCalledTimes(1));
  await act(async () => { await syncState.startSync(); });
  expect(fixture.fetch.mock.calls.filter(([u]) => new URL(u).pathname.endsWith("/health"))).toHaveLength(1);
  expect(fixture.fetch.mock.calls.every(([u]) => new URL(u).origin === window.location.origin)).toBe(true);
});

it("T02 新来源的工具颜色顺序随版本刷新", async () => {
  function Colors() { const { order } = useToolColors(); return <output>{order.join(",")}</output>; }
  const fixture = ledgerFixture();
  fixture.state.intercept = u => u.pathname.endsWith("/sources") && fixture.state.generation ? json({ ...fixture.body(u),
    sources: [...fixture.body(u).sources, { source: "claude", records: 1, first_observed_at: "2026-10-02T00:00:00Z" }] }) : undefined;
  vi.stubGlobal("fetch", fixture.fetch);
  render(<Colors />);
  await waitFor(() => expect(screen.getByRole("status").textContent).toBe("codex"));
  await act(async () => { await syncState.startSync(); });
  expect(screen.getByRole("status").textContent).toBe("codex,claude");
});

it("T07 版本通知后但 React effect 运行前的旧成功不能写入画面", async () => {
  const fixture = ledgerFixture();
  const old = deferred(), fresh = deferred();
  let calls = 0;
  fixture.state.intercept = u => u.pathname.endsWith("/summary") ? (calls++ === 0 ? old.promise : fresh.promise) : undefined;
  vi.stubGlobal("fetch", fixture.fetch);
  const seen = [];
  const version = syncState.getSnapshot().version;
  const unsubscribe = syncState.subscribe(() => {
    if (syncState.getSnapshot().version > version) old.resolve(json({ marker: "obsolete" }));
  });
  try {
    render(<Probe onRender={value => seen.push(value)} />);
    await act(async () => {
      await syncState.startSync();
      for (let i = 0; i < 20; i++) await Promise.resolve();
    });
    expect(seen).not.toContain("obsolete");
    await act(async () => fresh.resolve(json({ marker: "current" })));
    expect(screen.getByRole("status").textContent).toContain("current");
  } finally { unsubscribe(); }
});

it("T07 连续 reload 新请求先完成后，旧失败不能清空结果", async () => {
  const old = deferred(), fresh = deferred();
  const fetch = vi.fn().mockResolvedValueOnce(json({ marker: "initial" })).mockReturnValueOnce(old.promise).mockReturnValueOnce(fresh.promise);
  vi.stubGlobal("fetch", fetch);
  render(<Probe />);
  await waitFor(() => expect(screen.getByRole("status").textContent).toContain("initial"));
  await act(async () => screen.getByRole("button", { name: "重新读取" }).click());
  await act(async () => screen.getByRole("button", { name: "重新读取" }).click());
  expect(fetch).toHaveBeenCalledTimes(3);
  await act(async () => fresh.resolve(json({ marker: "latest" })));
  await act(async () => old.reject(new Error("late failure")));
  expect(screen.getByRole("status").textContent).toContain("latest");
  expect(screen.queryByText("late failure")).toBeNull();
});
