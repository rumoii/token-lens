// 明细视图的地址：/dashboard?view=detail 加周期和筛选。首页下钻、侧栏、导航都从这里拼链接，
// 明细视图从这里读，两边对同一组参数名不会各写各的。

export const DETAIL_DIMS = ["date", "tool", "model", "project"];
const FILTER_KEYS = ["tool", "model", "project", "bucket"];

/**
 * @param {string} search
 * @returns {{ view: "overview"|"detail", tool: string, model: string, project: string, bucket: string, dim: string }}
 */
export function readDetail(search) {
  const q = new URLSearchParams(search || "");
  const dim = q.get("dim");
  const bucket = q.get("bucket") || "";
  return {
    view: q.get("view") === "detail" ? "detail" : "overview",
    tool: q.get("tool") || "",
    model: q.get("model") || "",
    project: q.get("project") || "",
    bucket: bucketRange(bucket) || /^\d{4}-\d{2}-\d{2}T\d{2}:00:00$/.test(bucket) ? bucket : "",
    dim: DETAIL_DIMS.includes(dim) ? dim : "date"
  };
}

/**
 * 明细视图的查询串（不带 ?）。空的筛选和默认的拆法不写进地址。
 *
 * @param {string} periodText `periodQuery()` 的结果
 * @param {{ tool?: string, model?: string, project?: string, bucket?: string, dim?: string }} [detail]
 * @returns {string}
 */
export function detailSearch(periodText, detail = {}) {
  const q = new URLSearchParams(periodText || "");
  q.set("view", "detail");
  for (const key of FILTER_KEYS) if (detail[key]) q.set(key, detail[key]);
  if (detail.dim && detail.dim !== "date") q.set("dim", detail.dim);
  return q.toString();
}

/**
 * 首页模块下钻时换一个拆法：点了工具就按模型看，点了模型或项目就按时间看，点了某一天就按工具看。
 *
 * @param {"tool"|"model"|"project"|"bucket"} key
 * @returns {string}
 */
export function nextDim(key) {
  return { tool: "model", model: "date", project: "date", bucket: "tool" }[key];
}

/**
 * 一个时间桶对应的日期范围，与给定周期取交集。小时桶不支持按天过滤，返回 null。
 *
 * @param {string} bucket "2026-10-19" 或 "2026-10"
 * @param {{ from: string|null, to: string|null }} [range]
 * @returns {{ from: string, to: string }|null}
 */
export function bucketRange(bucket, range) {
  const m = /^(\d{4})-(\d{2})(?:-(\d{2}))?$/.exec(bucket);
  if (!m || Number(m[2]) < 1 || Number(m[2]) > 12) return null;
  const end = new Date(`${m[1]}-${m[2]}-01T00:00:00`);
  end.setMonth(end.getMonth() + 1, 0);
  const last = end.getDate();
  if (m[3] && (Number(m[3]) < 1 || Number(m[3]) > last)) return null;
  const from = m[3] ? bucket : `${bucket}-01`;
  const to = m[3] ? bucket : `${bucket}-${String(last).padStart(2, "0")}`;
  const clipped = {
    from: range?.from && range.from > from ? range.from : from,
    to: range?.to && range.to < to ? range.to : to
  };
  return clipped.from <= clipped.to ? clipped : null;
}
