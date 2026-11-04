import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { createSyncState, SYNC_IDLE_MS, SYNC_POLL_MS, SYNC_WAIT_MS, SYNC_REQUEST_MS } from "./sync-state.js";
import { deferred, json, ledgerFixture, run } from "../test/ledger-fixture.js";

let store, fixture, stop;
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-10-21T00:00:00Z"));
  store = createSyncState();
  fixture = ledgerFixture();
  vi.stubGlobal("fetch", fixture.fetch);
  vi.spyOn(document, "visibilityState", "get").mockReturnValue("visible");
});
afterEach(() => { stop?.(); stop = null; vi.restoreAllMocks(); vi.useRealTimers(); vi.unstubAllGlobals(); });

it("T11 POST 互斥，所有订阅者收到同一结果，观察不会重复发布该完成", async () => {
  const gate = deferred();
  fixture.state.intercept = u => u.pathname.endsWith("/sync") ? gate.promise : undefined;
  stop = store.startMonitor(); await flush();
  const a = store.startSync(), b = store.startSync();
  expect(a).toBe(b);
  expect(store.getSnapshot().phase).toBe("running");
  const result = { inserted: 2 };
  fixture.state.lastRun = run("ok", 2);
  gate.resolve(json(result));
  await a; await flush();
  expect(store.getSnapshot()).toMatchObject({ phase: "success", result, version: 1 });
  await vi.advanceTimersByTimeAsync(SYNC_IDLE_MS);
  expect(store.getSnapshot().version).toBe(1);
});

it("T12 409 明示冲突，等到新的终态才失效，其他 409 是错误", async () => {
  stop = store.startMonitor(); await flush();
  fixture.state.intercept = u => u.pathname.endsWith("/sync") ? json({ error: { code: "sync_in_progress", message: "已有同步在执行" } }, 409) : undefined;
  await expect(store.startSync()).rejects.toMatchObject({ status: 409 }); await flush();
  expect(store.getSnapshot()).toMatchObject({ phase: "conflict", version: 0 });
  fixture.state.lastRun = run("running", 2);
  await vi.advanceTimersByTimeAsync(SYNC_POLL_MS);
  expect(store.getSnapshot().phase).toBe("conflict");
  fixture.state.lastRun = run("ok", 2);
  await vi.advanceTimersByTimeAsync(SYNC_POLL_MS);
  expect(store.getSnapshot()).toMatchObject({ phase: "success", version: 1 });
  fixture.state.intercept = u => u.pathname.endsWith("/sync") ? json({ error: { code: "different_conflict", message: "其他冲突" } }, 409) : undefined;
  await expect(store.startSync()).rejects.toMatchObject({ code: "different_conflict" });
  expect(store.getSnapshot()).toMatchObject({ phase: "error", version: 2 });
});

it("T13 状态 GET 即使不响应 abort 也有截止，迟到结果不能覆盖重试", async () => {
  const old = deferred();
  fixture.state.intercept = () => old.promise;
  stop = store.startMonitor();
  await vi.advanceTimersByTimeAsync(SYNC_REQUEST_MS);
  expect(store.getSnapshot().phase).toBe("error");
  expect(store.getSnapshot().error.message).toContain("请求超时");
  fixture.state.intercept = null;
  await store.retryStatus();
  fixture.state.lastRun = run("ok", 2);
  await vi.advanceTimersByTimeAsync(SYNC_IDLE_MS);
  expect(store.getSnapshot()).toMatchObject({ phase: "success", version: 1 });
  old.resolve(json({ last_run: run("failed", 3) })); await flush();
  expect(store.getSnapshot().phase).toBe("success");
});

it("T13 崩溃遗留 running 等待有上限，重新检查可恢复", async () => {
  fixture.state.lastRun = run("running");
  stop = store.startMonitor(); await flush();
  await vi.advanceTimersByTimeAsync(SYNC_WAIT_MS);
  expect(store.getSnapshot()).toMatchObject({ phase: "timed_out", version: 0 });
  expect(vi.getTimerCount()).toBe(0);
  fixture.state.lastRun = run("ok", 2);
  await store.retryStatus();
  expect(store.getSnapshot()).toMatchObject({ phase: "success", version: 1 });
});

it("T14 五分钟检查发现未见过 running 的定时终态，重复不刷新，后续运行继续观察", async () => {
  expect(SYNC_IDLE_MS).toBe(300000);
  stop = store.startMonitor(); await flush();
  fixture.state.lastRun = run("ok", 2);
  await vi.advanceTimersByTimeAsync(SYNC_IDLE_MS);
  expect(store.getSnapshot().version).toBe(1);
  await vi.advanceTimersByTimeAsync(SYNC_IDLE_MS);
  expect(store.getSnapshot().version).toBe(1);
  fixture.state.lastRun = run("running", 3);
  await vi.advanceTimersByTimeAsync(SYNC_IDLE_MS);
  expect(store.getSnapshot().phase).toBe("running");
  fixture.state.lastRun = run("failed", 3);
  await vi.advanceTimersByTimeAsync(SYNC_POLL_MS);
  expect(store.getSnapshot()).toMatchObject({ phase: "error", version: 2 });
});

it.each(["failed", "abandoned"])("T14 %s 终态之后仍可观察下一次定时采集", async status => {
  fixture.state.lastRun = run(status);
  stop = store.startMonitor(); await flush();
  expect(store.getSnapshot()).toMatchObject({ phase: "error", version: 0 });
  fixture.state.lastRun = run("ok", 2);
  await vi.advanceTimersByTimeAsync(SYNC_IDLE_MS);
  expect(store.getSnapshot()).toMatchObject({ phase: "success", version: 1 });
});

it("T16 隐藏恢复/重复所有者只保留一个观察器，清理幂等且迟到不能再排 timer", async () => {
  const gate = deferred();
  fixture.state.intercept = () => gate.promise;
  stop = store.startMonitor();
  const second = store.startMonitor();
  expect(fixture.fetch).toHaveBeenCalledTimes(1);
  second(); second();
  stop(); stop();
  expect(vi.getTimerCount()).toBe(0);
  gate.resolve(json({ last_run: run("running") })); await flush();
  expect(vi.getTimerCount()).toBe(0);
  fixture.state.intercept = null;
  stop = store.startMonitor(); await flush();
  vi.spyOn(document, "visibilityState", "get").mockReturnValue("hidden");
  document.dispatchEvent(new Event("visibilitychange"));
  const count = fixture.fetch.mock.calls.length;
  await vi.advanceTimersByTimeAsync(SYNC_IDLE_MS);
  expect(fixture.fetch).toHaveBeenCalledTimes(count);
  vi.spyOn(document, "visibilityState", "get").mockReturnValue("visible");
  document.dispatchEvent(new Event("visibilitychange"));
  window.dispatchEvent(new Event("focus")); await flush();
  expect(fixture.fetch).toHaveBeenCalledTimes(count + 1);
});

it("T17 自动观察仅本地 sources GET，不会 POST 或调用 discovery/外部服务", async () => {
  stop = store.startMonitor(); await flush();
  await vi.advanceTimersByTimeAsync(SYNC_IDLE_MS * 2);
  expect(fixture.fetch.mock.calls.length).toBe(3);
  expect(fixture.fetch.mock.calls.every(([u, init]) => new URL(u).pathname === "/api/v1/sources" && init.method === "GET")).toBe(true);
});

it("T11 已观察到 running 时，调用同步不能当作本窗口成功", async () => {
  fixture.state.lastRun = run("running");
  stop = store.startMonitor(); await flush();
  await expect(store.startSync()).rejects.toMatchObject({ status: 409, code: "sync_in_progress" });
  expect(store.getSnapshot().version).toBe(0);
  expect(fixture.fetch.mock.calls.every(([, init]) => init.method === "GET")).toBe(true);
});

it("B2-6 T16 根卸载重挂载保留在途 POST 去重，并接上结果", async () => {
  stop = store.startMonitor(); await flush();
  const gate = deferred();
  fixture.state.intercept = u => u.pathname.endsWith("/sync") ? gate.promise : undefined;
  const old = store.startSync(); await flush();
  stop();
  stop = store.startMonitor(); await flush();
  const rejoined = store.startSync(); await flush();
  expect(rejoined).toBe(old);
  expect(fixture.fetch.mock.calls.filter(([, init]) => init.method === "POST")).toHaveLength(1);
  fixture.state.lastRun = run("ok", 9, { inserted: 999 });
  gate.resolve(json({ inserted: 999 })); await old; await flush();
  expect(store.getSnapshot()).toMatchObject({ phase: "success", result: { inserted: 999 }, version: 1 });
});

it("B2-1 异常完成是成功终态，可继续 POST，重复观察不再刷新", async () => {
  stop = store.startMonitor(); await flush();
  fixture.state.lastRun = run("completed_with_anomalies", 2, { anomalies: ["read_failed: fixture"] });
  await vi.advanceTimersByTimeAsync(SYNC_IDLE_MS);
  expect(store.getSnapshot()).toMatchObject({ phase: "success", errorKind: null, version: 1,
    warning: "read_failed: fixture" });
  await vi.advanceTimersByTimeAsync(SYNC_IDLE_MS);
  expect(store.getSnapshot().version).toBe(1);
  await store.startSync(); await flush();
  expect(fixture.fetch.mock.calls.filter(([, init]) => init.method === "POST")).toHaveLength(1);
});

it("B2-1 本窗口异常完成的确认 GET 保留成功与警告", async () => {
  stop = store.startMonitor(); await flush();
  fixture.state.lastRun = run("completed_with_anomalies", 2, { anomalies: ["vanished: fixture"] });
  fixture.state.intercept = u => u.pathname.endsWith("/sync")
    ? json({ attempted: 2, inserted: 2, updated: 0, unchanged: 0, rejected: 0, anomalies: ["vanished: fixture"] }) : undefined;
  await store.startSync(); await flush();
  expect(store.getSnapshot()).toMatchObject({ phase: "success", version: 1, errorKind: null, warning: "vanished: fixture" });
});

it("B2-1 未来未知终态显示诊断且不锁死 POST", async () => {
  fixture.state.lastRun = run("future_terminal");
  stop = store.startMonitor(); await flush();
  expect(store.getSnapshot()).toMatchObject({ phase: "error", errorKind: "sync" });
  expect(store.getSnapshot().error.message).toContain("future_terminal");
  fixture.state.intercept = null;
  await store.startSync(); await flush();
  expect(store.getSnapshot().phase).toBe("success");
});

it.each(["ok", "failed", "completed_with_anomalies"])("B2-2 确认 GET 读到另一轮 %s 时必须再次刷新", async status => {
  stop = store.startMonitor(); await flush();
  fixture.state.lastRun = run(status, 3);
  fixture.state.intercept = u => u.pathname.endsWith("/sync") ? json({ inserted: 2 }) : undefined;
  await store.startSync(); await flush();
  expect(store.getSnapshot().version).toBe(2);
  expect(store.getSnapshot().lastRun).toEqual(fixture.state.lastRun);
  await vi.advanceTimersByTimeAsync(SYNC_IDLE_MS);
  expect(store.getSnapshot().version).toBe(2);
});

it("B2-2 另一轮计数相同但完成时间晚于 POST，也不能吞掉刷新", async () => {
  stop = store.startMonitor(); await flush();
  const confirmation = deferred();
  fixture.state.intercept = u => u.pathname.endsWith("/sync") ? json({ inserted: 2 }) : confirmation.promise;
  await store.startSync(); await flush();
  await vi.advanceTimersByTimeAsync(2000);
  fixture.state.lastRun = run("ok", 2);
  confirmation.resolve(json({ last_run: fixture.state.lastRun })); await flush();
  expect(store.getSnapshot().version).toBe(2);
});

it("B2-2 回执不足以对应终态时保守刷新，即使指纹等于基线", async () => {
  stop = store.startMonitor(); await flush();
  fixture.state.intercept = u => u.pathname.endsWith("/sync") ? json({}) : undefined;
  await store.startSync(); await flush();
  expect(store.getSnapshot().version).toBe(2);
  await vi.advanceTimersByTimeAsync(SYNC_IDLE_MS);
  expect(store.getSnapshot().version).toBe(2);
});

it("B2-3 隐藏期间本窗口完成，恢复时登记同一终态而不重复刷新", async () => {
  stop = store.startMonitor(); await flush();
  const gate = deferred();
  fixture.state.intercept = u => u.pathname.endsWith("/sync") ? gate.promise : undefined;
  const work = store.startSync(); await flush();
  vi.spyOn(document, "visibilityState", "get").mockReturnValue("hidden");
  document.dispatchEvent(new Event("visibilitychange"));
  fixture.state.lastRun = run("ok", 2);
  gate.resolve(json({ inserted: 2 })); await work; await flush();
  expect(store.getSnapshot().version).toBe(1);
  vi.spyOn(document, "visibilityState", "get").mockReturnValue("visible");
  document.dispatchEvent(new Event("visibilitychange")); await flush();
  expect(store.getSnapshot()).toMatchObject({ phase: "success", version: 1, lastRun: fixture.state.lastRun });
  await vi.advanceTimersByTimeAsync(SYNC_IDLE_MS);
  expect(store.getSnapshot().version).toBe(1);
});

it("B2-4 首次检查未完成即 409，首个终态可以确认结束", async () => {
  const initial = deferred();
  fixture.state.intercept = (u, init) => {
    if (u.pathname.endsWith("/sync")) return json({ error: { code: "sync_in_progress", message: "busy" } }, 409);
    if (!init.signal.aborted && fixture.fetch.mock.calls.length === 1) return initial.promise;
  };
  stop = store.startMonitor();
  await expect(store.startSync()).rejects.toMatchObject({ status: 409 }); await flush();
  expect(store.getSnapshot()).toMatchObject({ phase: "success", version: 1 });
  initial.resolve(json({ last_run: run("failed", 9) })); await flush();
  expect(store.getSnapshot().phase).toBe("success");
  fixture.state.intercept = null;
  await store.startSync(); await flush();
  expect(fixture.fetch.mock.calls.filter(([, init]) => init.method === "POST")).toHaveLength(2);
});

it("B2-4 等待超时后的同步动作允许重新 POST", async () => {
  stop = store.startMonitor(); await flush();
  fixture.state.intercept = u => u.pathname.endsWith("/sync") ? json({ error: { code: "sync_in_progress" } }, 409) : undefined;
  await expect(store.startSync()).rejects.toMatchObject({ status: 409 }); await flush();
  await vi.advanceTimersByTimeAsync(SYNC_WAIT_MS);
  expect(store.getSnapshot()).toMatchObject({ phase: "timed_out", errorKind: "sync" });
  fixture.state.intercept = null;
  await store.startSync(); await flush();
  expect(fixture.fetch.mock.calls.filter(([, init]) => init.method === "POST")).toHaveLength(2);
  expect(store.getSnapshot().phase).toBe("success");
});

it("B2-7 focus 检查恢复后重新安排五分钟观察，保留本次同步错误", async () => {
  stop = store.startMonitor(); await flush();
  fixture.state.intercept = () => Promise.reject(new Error("offline"));
  window.dispatchEvent(new Event("focus")); await flush();
  expect(vi.getTimerCount()).toBe(0);
  fixture.state.intercept = null;
  window.dispatchEvent(new Event("focus")); await flush();
  expect(store.getSnapshot().error.message).toContain("offline");
  expect(vi.getTimerCount()).toBe(1);
  fixture.state.lastRun = run("ok", 2);
  await vi.advanceTimersByTimeAsync(SYNC_IDLE_MS);
  expect(store.getSnapshot()).toMatchObject({ phase: "success", version: 1 });
});

it("T10 网络失败保留本次错误，只由用户重试 POST", async () => {
  stop = store.startMonitor(); await flush();
  fixture.state.intercept = u => u.pathname.endsWith("/sync") ? Promise.reject(new Error("offline")) : undefined;
  await expect(store.startSync()).rejects.toThrow("offline");
  expect(store.getSnapshot()).toMatchObject({ phase: "error", errorKind: "sync", version: 1 });
  await vi.advanceTimersByTimeAsync(SYNC_IDLE_MS);
  expect(store.getSnapshot().error.message).toBe("offline");
  expect(fixture.fetch.mock.calls.filter(([, init]) => init.method === "POST")).toHaveLength(1);
  fixture.state.intercept = null;
  await store.startSync(); await flush();
  expect(store.getSnapshot()).toMatchObject({ phase: "success", version: 2 });
});

it("T13 总等待截止包含最后一个慢状态请求", async () => {
  fixture.state.lastRun = run("running");
  stop = store.startMonitor(); await flush();
  await vi.advanceTimersByTimeAsync(SYNC_WAIT_MS - SYNC_POLL_MS * 2);
  const late = deferred();
  fixture.state.intercept = () => late.promise;
  await vi.advanceTimersByTimeAsync(SYNC_POLL_MS * 2);
  expect(store.getSnapshot().phase).toBe("timed_out");
  late.resolve(json({ last_run: run("ok", 2) })); await flush();
  expect(store.getSnapshot()).toMatchObject({ phase: "timed_out", version: 0 });
});
