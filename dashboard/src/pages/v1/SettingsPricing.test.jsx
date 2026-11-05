import React from "react";
import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SettingsPage } from "./SettingsPage.jsx";
import { ThemeProvider } from "../../ui/foundation/ThemeProvider.jsx";
import { TokenFormatContext } from "../../ui/foundation/TokenFormatProvider.jsx";

const BASE = { input: 2, output: 10, cache_read: 0.1, cache_write_5m: 2.5, cache_write_1h: null };
const HIGH = { input: 4, output: 15, cache_read: 0.2, cache_write_5m: 5, cache_write_1h: null };
const TOD = {
  utc_offset_minutes: 480,
  peak: [{ days: [1, 2, 3, 4, 5], from: 540, to: 720 }, { days: [1, 2, 3, 4, 5], from: 840, to: 1080 }],
  off_peak_prices: { input: 0.15, output: 0.6, cache_read: 0.003, cache_write_5m: null, cache_write_1h: null },
  holidays_count: 33,
  holidays_through: "2027-10-07"
};

function model(fields = {}) {
  const item = {
    model: "gpt-6.1-sol", state: "verified", billing: "metered", source_url: null, note: null,
    prices: BASE, tiers: null, time_of_day: null, price_marks: { "": 1 }, ...fields
  };
  return { ...item, records: Object.values(item.price_marks).reduce((sum, count) => sum + count, 0) };
}

function showModels(models, narrow, groups = []) {
  vi.stubGlobal("matchMedia", vi.fn(query => ({
    matches: query === "(max-width: 767px)" && narrow, media: query,
    addEventListener: vi.fn(), removeEventListener: vi.fn()
  })));
  vi.stubGlobal("fetch", vi.fn(async url => {
    const path = new URL(String(url)).pathname;
    let body;
    if (path === "/api/v1/pricing") {
      body = {
        price_version: "fixture", verified_at: null, currency: "USD", provisional: false, models,
        counts: { verified: models.filter(m => m.state === "verified").length,
          aggregate: 0, unknown: models.filter(m => m.state === "unknown").length,
          local: models.filter(m => m.state === "local").length }
      };
    } else if (path === "/api/v1/usage/breakdown") body = { groups };
    else if (path === "/api/v1/health") body = { ok: true, version: "test", port: 3456, data_dir: "/fixture" };
    else throw new Error(`Unexpected API request: ${path}`);
    return new Response(JSON.stringify(body), { headers: { "Content-Type": "application/json" } });
  }));
  return render(<ThemeProvider><TokenFormatContext.Provider value={{ unitSystem: "english" }}><SettingsPage /></TokenFormatContext.Provider></ThemeProvider>);
}

function modelRow(name, narrow) {
  return name.closest(narrow ? "li" : "tr");
}

describe.each([["桌面", false], ["窄屏", true]])("设置页条件价格 · %s", (_layout, narrow) => {
  beforeEach(() => {
    document.head.innerHTML = '<meta name="lens-api-token" content="fixture">';
  });
  afterEach(() => { vi.unstubAllGlobals(); });

  it("本地模型显示本地和零价；同名混合用量保留远端价格并列出本地条数", async () => {
    const zero = { input: 0, output: 0, cache_read: 0, cache_write_5m: 0, cache_write_1h: 0 };
    showModels([
      model({ model: "local-model", state: "local", billing: "local", prices: zero,
        local_records: 1, local_providers: { ollama: 1 } }),
      model({ model: "mixed-model", local_records: 1, local_providers: { lmstudio: 1 }, price_marks: { "": 2 } })
    ], narrow);
    const local = await screen.findByText("local-model");
    const localRow = within(modelRow(local, narrow));
    expect(localRow.getByText("本地")).toBeInTheDocument();
    expect(localRow.getByText("输入 $0 · 输出 $0")).toBeInTheDocument();
    expect(localRow.queryByText("查不到价格")).not.toBeInTheDocument();
    expect(localRow.queryByText("没有公开价")).not.toBeInTheDocument();
    const mixed = within(modelRow(screen.getByText("mixed-model"), narrow));
    expect(mixed.getByText("输入 $2 · 输出 $10")).toBeInTheDocument();
    expect(mixed.getByText("其中 1 条本地 · 金额按 0 计")).toBeInTheDocument();
    await userEvent.click(local);
    expect(screen.getAllByText("$0")).toHaveLength(5);
  });

  it("模型行只显示模型名和计价标记，不列出用过它的工具", async () => {
    showModels([model(), model({ model: "plan-model", billing: "plan" })], narrow, [
      { source: "codex", model: "gpt-6.1-sol", gross_tokens: 120 },
      { source: "pi", model: "gpt-6.1-sol", gross_tokens: 80 }
    ]);
    const row = within(modelRow(await screen.findByText("gpt-6.1-sol"), narrow));
    expect(row.queryByText(/Codex|Pi/)).not.toBeInTheDocument();
    expect(row.queryByTitle(/Codex|Pi/)).not.toBeInTheDocument();
    expect(row.getByText(narrow ? "累计 200" : "200")).toBeInTheDocument();
    expect(within(modelRow(screen.getByText("plan-model"), narrow)).getByText("套餐")).toBeInTheDocument();
  });

  it("模型累计用量遵循英文单位", async () => {
    showModels([model()], narrow, [{ source: "codex", model: "gpt-6.1-sol", gross_tokens: 1200000 }]);
    const row = within(modelRow(await screen.findByText("gpt-6.1-sol"), narrow));
    expect(row.getByText(narrow ? "累计 1.2M" : "1.2M")).toBeInTheDocument();
  });

  it("分档摘要常驻，展开所有档位、缺失单价与全部计价标记", async () => {
    showModels([model({
      tiers: [{ above: 272000, prices: HIGH }, { above: 512000, prices: { ...HIGH, input: 8, output: 30 } }],
      price_marks: { "tier:272000": 1037, "tier:512000": 3, "tier:unknown": 13293, "tier:cumulative": 2, "": 22 }
    })], narrow);
    const name = await screen.findByText("gpt-6.1-sol");
    const row = within(modelRow(name, narrow));
    expect(row.getByText(/单次提示 > 272,000 token/)).toHaveTextContent("1,037 条按长上下文计");
    expect(row.getByText(/单次提示 > 512,000 token/)).toHaveTextContent("3 条按长上下文计");
    expect(row.getByText(/13,293 条提示长度不完整/)).toBeInTheDocument();
    expect(screen.queryByRole("table", { name: "gpt-6.1-sol 条件价格" })).not.toBeInTheDocument();

    await userEvent.click(name);
    const table = screen.getByRole("table", { name: "gpt-6.1-sol 条件价格" });
    const highRow = within(table).getByRole("rowheader", { name: "提示 > 272,000 token" }).closest("tr");
    expect(within(highRow).getAllByRole("cell").map(cell => cell.textContent)).toEqual(["$4", "$15", "$0.2", "$5", "—"]);
    expect(within(table).getByRole("rowheader", { name: "提示 > 512,000 token" })).toBeInTheDocument();
    const baseRow = within(table).getByRole("rowheader", { name: "基础档" }).closest("tr");
    expect(within(baseRow).getAllByRole("cell").map(cell => cell.textContent)).toEqual(["$2", "$10", "$0.1", "$2.5", "—"]);
    expect(screen.getByText("提示长度不完整 · 基础档")).toBeInTheDocument();
    expect(screen.getByText("累计快照 · 基础档")).toBeInTheDocument();
    expect(screen.getByText("未标记")).toBeInTheDocument();
    expect(within(table).getByRole("columnheader", { name: "写缓存（短时）" })).toBeInTheDocument();

    await userEvent.click(name);
    expect(screen.queryByRole("table", { name: "gpt-6.1-sol 条件价格" })).not.toBeInTheDocument();
    expect(row.getByText(/13,293 条提示长度不完整/)).toBeInTheDocument();
  });

  it("峰谷摘要区分低谷、区间加权与周占比，节假日年份来自接口", async () => {
    showModels([model({ model: "deepseek-flash", time_of_day: TOD,
      prices: { input: 0.3, output: 1.2, cache_read: 0.006, cache_write_5m: null, cache_write_1h: null },
      price_marks: { "tod:peak": 5, "tod:offpeak": 36, "tod:blend": 100, "tod:weekly": 37 }
    })], narrow);
    const name = await screen.findByText("deepseek-flash");
    const row = within(modelRow(name, narrow));
    const summary = row.getByText(/36 条低谷/);
    expect(summary).toHaveTextContent("100 条区间加权");
    expect(summary).toHaveTextContent("37 条周占比估算");
    expect(summary).toHaveTextContent("节假日仅登记到 2027 年");
    await userEvent.click(name);
    const table = screen.getByRole("table", { name: "deepseek-flash 条件价格" });
    const offPeak = within(table).getByRole("rowheader", { name: "低谷" }).closest("tr");
    expect(within(offPeak).getAllByRole("cell").map(cell => cell.textContent)).toEqual(["$0.15", "$0.6", "$0.003", "—", "—"]);
    expect(screen.getByText("区间加权")).toBeInTheDocument();
    expect(screen.getByText("周占比估算")).toBeInTheDocument();
    expect(screen.getByText(/北京时间（UTC\+8）/)).toBeInTheDocument();
    expect(screen.getByText(/09:00–12:00/)).toBeInTheDocument();
    expect(screen.getByText(/14:00–18:00/)).toBeInTheDocument();
    expect(screen.getByText(/33 天，最晚 2027-10-07/)).toBeInTheDocument();
  });

  it("无条件变价和未定价模型保留原显示，不出现摘要或条件价表", async () => {
    showModels([
      model({ model: "claude-opus-5-5", prices: { input: 4, output: 20, cache_read: 0.2, cache_write_5m: 5, cache_write_1h: 8 } }),
      model({ model: "unlisted-model", state: "unknown", prices: null })
    ], narrow);
    const opus = await screen.findByText("claude-opus-5-5");
    expect(within(modelRow(opus, narrow)).getByText("输入 $4 · 输出 $20")).toBeInTheDocument();
    expect(screen.getByText("没有公开价")).toBeInTheDocument();
    expect(screen.queryByText(/条按长上下文计|条低谷|提示长度不完整|节假日仅登记到/)).not.toBeInTheDocument();
    await userEvent.click(opus);
    expect(screen.getByText("写缓存（存 5 分钟）")).toBeInTheDocument();
    expect(screen.getByText("$0.2")).toBeInTheDocument();
    expect(screen.queryByRole("table", { name: /条件价格/ })).not.toBeInTheDocument();
    expect(screen.queryByText("未标记")).not.toBeInTheDocument();
    await userEvent.click(screen.getByText("unlisted-model"));
    expect(screen.getAllByText("—").length).toBeGreaterThanOrEqual(5);
  });

  it("空节假日表不猜年份，按接口偏移与时段显示峰谷规则", async () => {
    showModels([model({ model: "timed-model", time_of_day: { ...TOD, utc_offset_minutes: -330,
      peak: [{ days: [0, 6], from: 60, to: 120 }], holidays_count: 0, holidays_through: null },
      price_marks: { "tod:offpeak": 1 }
    })], narrow);
    const name = await screen.findByText("timed-model");
    expect(within(modelRow(name, narrow)).getByText(/尚未登记节假日/)).toBeInTheDocument();
    await userEvent.click(name);
    expect(screen.getByText(/UTC-5:30/)).toBeInTheDocument();
    expect(screen.getByText(/周日、周六 01:00–02:00/)).toBeInTheDocument();
    expect(screen.queryByText(/节假日仅登记到/)).not.toBeInTheDocument();
  });

  it("旧响应缺少新字段或分档为空数组时仍显示基础价格", async () => {
    const legacy = model({ model: "legacy-model" });
    delete legacy.tiers;
    delete legacy.time_of_day;
    delete legacy.price_marks;
    showModels([legacy, model({ model: "empty-tiers", tiers: [] })], narrow);
    const name = await screen.findByText("legacy-model");
    expect(screen.getAllByText("输入 $2 · 输出 $10")).toHaveLength(2);
    expect(screen.queryByText(/条按长上下文计|条低谷/)).not.toBeInTheDocument();
    await userEvent.click(name);
    expect(screen.getByText("新输入")).toBeInTheDocument();
    expect(screen.queryByRole("table", { name: /条件价格/ })).not.toBeInTheDocument();
  });
});
