import React from "react";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { OnboardingPage } from "./OnboardingPage.jsx";
import { syncState } from "../../lib/sync-state.js";
import { json, ledgerFixture, run } from "../../test/ledger-fixture.js";

function Monitor() { React.useEffect(() => syncState.startMonitor(), []); return null; }
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

it("B2-5 引导页展示 409 后的状态检查错误，重试只 GET", async () => {
  const fixture = ledgerFixture();
  let failStatus = false;
  fixture.state.intercept = (u, init) => {
    if (u.pathname.endsWith("/discovery")) return json({ sources: [{ source: "codex", files: 1 }], supported: 1 });
    if (u.pathname.endsWith("/sync")) {
      failStatus = true;
      return json({ error: { code: "sync_in_progress", message: "已有同步在执行" } }, 409);
    }
    if (u.pathname.endsWith("/sources") && init.signal && failStatus) return Promise.reject(new Error("fixture status offline"));
  };
  vi.stubGlobal("fetch", fixture.fetch);
  render(<><Monitor /><OnboardingPage onEnter={() => {}} /></>);
  fireEvent.click(await screen.findByRole("button", { name: "开始统计" }));
  await waitFor(() => expect(syncState.getSnapshot().errorKind).toBe("status"));
  await screen.findByText(/无法确认同步状态：fixture status offline/);
  const count = fixture.fetch.mock.calls.length;
  fireEvent.click(screen.getByRole("button", { name: "重试" }));
  await waitFor(() => expect(fixture.fetch.mock.calls.length).toBeGreaterThan(count));
  expect(fixture.fetch.mock.calls.filter(([, init]) => init.method === "POST")).toHaveLength(1);
  failStatus = false;
  fixture.state.generation = 1;
  fixture.state.lastRun = run("completed_with_anomalies", 2, { anomalies: ["vanished: onboarding fixture"] });
  fireEvent.click(screen.getByRole("button", { name: "重试" }));
  await screen.findByTitle("4,321 token");
  expect(screen.getByText(/同步完成，有异常警告：vanished: onboarding fixture/)).toBeInTheDocument();
  expect(fixture.fetch.mock.calls.filter(([, init]) => init.method === "POST")).toHaveLength(1);
});
