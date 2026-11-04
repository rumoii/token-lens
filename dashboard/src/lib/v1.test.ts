import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError, api, readApiToken, request, invalidateReadRequests } from "./v1";
function deferred() {
  let resolve!: (value: Response) => void;
  const promise = new Promise<Response>(yes => { resolve = yes; });
  return { promise, resolve };
}

function metaWithToken(token: string) {
  document.head.innerHTML = `<meta name="lens-api-token" content="${token}">`;
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("v1 client", () => {
  beforeEach(() => {
    invalidateReadRequests();
    document.head.innerHTML = "";
  });

  it("T06 失效切断旧 Promise，旧 finally 不会删除新版同 URL 的去重项", async () => {
    const old = deferred(), fresh = deferred();
    const fetch = vi.fn().mockReturnValueOnce(old.promise).mockReturnValueOnce(fresh.promise);
    vi.stubGlobal("fetch", fetch);
    const a = api.summary();
    invalidateReadRequests();
    const b = api.summary();
    expect(fetch).toHaveBeenCalledTimes(2);
    old.resolve(jsonResponse({ marker: "old" }));
    await a;
    const duplicate = api.summary();
    expect(fetch).toHaveBeenCalledTimes(2);
    fresh.resolve(jsonResponse({ marker: "fresh" }));
    expect(await b).toEqual({ marker: "fresh" });
    expect(await duplicate).toEqual({ marker: "fresh" });
  });

  it("T06 失败释放去重项，允许同参数再次读取", async () => {
    const fetch = vi.fn().mockRejectedValueOnce(new Error("offline")).mockResolvedValueOnce(jsonResponse({ ok: true }));
    vi.stubGlobal("fetch", fetch);
    await expect(api.summary()).rejects.toThrow("offline");
    expect(await api.summary()).toEqual({ ok: true });
    expect(fetch).toHaveBeenCalledTimes(2);
  });

  it("T13 独立状态检查不复用或取消页面 sources", async () => {
    const gate = deferred();
    const fetch = vi.fn().mockReturnValueOnce(gate.promise).mockResolvedValueOnce(jsonResponse({ fresh: true }));
    vi.stubGlobal("fetch", fetch);
    const page = api.sources();
    const controller = new AbortController();
    expect(await request("/sources", { signal: controller.signal })).toEqual({ fresh: true });
    controller.abort();
    gate.resolve(jsonResponse({ page: true }));
    expect(await page).toEqual({ page: true });
    expect(fetch).toHaveBeenCalledTimes(2);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("从注入的 meta 读取令牌", () => {
    expect(readApiToken()).toBeNull();
    metaWithToken("abc123");
    expect(readApiToken()).toBe("abc123");
  });

  it("带令牌请求，并丢弃空参数", async () => {
    metaWithToken("abc123");
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ ok: true }));
    vi.stubGlobal("fetch", fetchMock);

    await api.summary({ from: "2026-10-01", to: "", source: null });

    const [url, init] = fetchMock.mock.calls[0];
    const parsed = new URL(String(url));
    expect(parsed.pathname).toBe("/api/v1/usage/summary");
    expect(parsed.searchParams.get("from")).toBe("2026-10-01");
    expect(parsed.searchParams.get("to")).toBeNull();
    expect(parsed.searchParams.get("source")).toBeNull();
    expect(parsed.searchParams.get("tz")).toBeTruthy(); // 读请求自动带浏览器时区
    expect(init.headers.Authorization).toBe("Bearer abc123");
    expect(init.method).toBe("GET");
  });

  it("写请求不带时区参数", async () => {
    metaWithToken("abc123");
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ ok: true }));
    vi.stubGlobal("fetch", fetchMock);

    await api.sync();

    const parsed = new URL(String(fetchMock.mock.calls[0][0]));
    expect(parsed.pathname).toBe("/api/v1/sync");
    expect(parsed.searchParams.get("tz")).toBeNull();
  });

  it("401 抛 ApiError，不返回空数据", async () => {
    metaWithToken("wrong");
    vi.stubGlobal(
      "fetch",
      vi.fn().mockImplementation(() =>
        Promise.resolve(
          jsonResponse({ error: { code: "unauthorized", message: "缺少或错误的 bearer 令牌" } }, 401),
        ),
      ),
    );

    const error = await api.summary().catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ApiError);
    expect(error).toMatchObject({ status: 401, code: "unauthorized" });
    expect((error as ApiError).message).toContain("bearer");
  });

  it("未知值保持 null，不折成 0", async () => {
    metaWithToken("abc123");
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        jsonResponse({
          totals: {
            gross_tokens: 0,
            input_tokens: null,
            output_tokens: null,
            cache_read_tokens: null,
            cache_write_tokens: null,
            cost_usd: null,
            unpriced_records: 1,
            record_count: 1,
          },
        }),
      ),
    );

    const summary = await api.summary();
    expect(summary.totals.input_tokens).toBeNull();
    expect(summary.totals.cost_usd).toBeNull();
    expect(summary.totals.unpriced_records).toBe(1);
  });

  it("非 JSON 错误体也给出状态码", async () => {
    metaWithToken("abc123");
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(new Response("<html>boom</html>", { status: 500 })),
    );

    await expect(request("/health")).rejects.toMatchObject({ status: 500, code: "http_error" });
  });

  it("没有令牌时不伪造 Authorization", async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ ok: true }));
    vi.stubGlobal("fetch", fetchMock);

    await api.health();

    expect(fetchMock.mock.calls[0][1].headers.Authorization).toBeUndefined();
  });

  it("写请求使用 POST 且不带请求体", async () => {
    metaWithToken("abc123");
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ attempted: 0 }));
    vi.stubGlobal("fetch", fetchMock);

    await api.sync();

    const [, init] = fetchMock.mock.calls[0];
    expect(init.method).toBe("POST");
    expect(init.body).toBeUndefined();
  });
});
