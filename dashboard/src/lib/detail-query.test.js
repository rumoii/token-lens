import { describe, expect, it } from "vitest";
import { bucketRange, detailSearch, nextDim, readDetail } from "./detail-query.js";

describe("detail-query", () => {
  it("读写往返；空筛选和默认拆法不进地址", () => {
    const text = detailSearch("period=month", { tool: "dsh", model: "", dim: "date" });
    expect(text).toBe("period=month&view=detail&tool=dsh");
    expect(readDetail(`?${text}`)).toMatchObject({ view: "detail", tool: "dsh", model: "", dim: "date" });
  });

  it("不认识的拆法退回按时间", () => {
    expect(readDetail("?view=detail&dim=weird").dim).toBe("date");
    expect(readDetail("?dim=model").view).toBe("overview");
  });

  it("下钻后换一个拆法", () => {
    expect(nextDim("tool")).toBe("model");
    expect(nextDim("bucket")).toBe("tool");
  });

  it("时间桶换成日期范围；小时桶不支持", () => {
    expect(bucketRange("2026-10-19")).toEqual({ from: "2026-10-19", to: "2026-10-19" });
    expect(bucketRange("2026-02")).toEqual({ from: "2026-02-01", to: "2026-02-28" });
    expect(bucketRange("2026-10-19T08:00:00")).toBeNull();
  });

  it("月桶与当前周期取交集，保留首尾边界", () => {
    const range = { from: "2026-08-15", to: "2026-11-04" };
    expect(bucketRange("2026-08", range)).toEqual({ from: "2026-08-15", to: "2026-08-31" });
    expect(bucketRange("2026-11", range)).toEqual({ from: "2026-11-01", to: "2026-11-04" });
    expect(bucketRange("2026-09", range)).toEqual({ from: "2026-09-01", to: "2026-09-30" });
    expect(bucketRange("2026-07", range)).toBeNull();
    expect(bucketRange("2026-08", { from: null, to: null })).toEqual({ from: "2026-08-01", to: "2026-08-31" });
  });

  it.each(["garbage", "2026-13", "2026-00", "2026-02-30"])("非法 bucket %s 当作未选中", (bucket) => {
    expect(bucketRange(bucket)).toBeNull();
    expect(readDetail(`?view=detail&bucket=${bucket}`).bucket).toBe("");
  });

  it("保留已有小时桶的读取语义", () => {
    expect(readDetail("?bucket=2026-10-19T08:00:00").bucket).toBe("2026-10-19T08:00:00");
    expect(bucketRange("2024-02-29")).toEqual({ from: "2024-02-29", to: "2024-02-29" });
  });
});
