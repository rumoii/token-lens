// 图表里工具的颜色。品牌色只留给 logo 磁贴；柱子、分段条、模型条用 tokens.css 的 --lens-cat-*。
// 工具按第一次出现的先后依次占第 1、2、3… 号色，之后不再变：哪个工具用得多不会让颜色对调。
// 堆叠顺序也按这个顺序，这样相邻的两色正是校验过的那几对。

export const CATEGORY_SLOTS = 8;
export const OTHER_COLOR = "var(--lens-cat-other)";

type SourceRow = { source: string; first_observed_at: string | null; records: number };

/** 有记录的来源，按最早一条记录的时间排；时间相同或缺失时按 id，保证结果稳定。 */
export function toolOrder(sources: SourceRow[]): string[] {
  return sources
    .filter((s) => s.records > 0)
    .slice()
    .sort((a, b) => {
      const ta = a.first_observed_at ?? "￿";
      const tb = b.first_observed_at ?? "￿";
      return ta < tb ? -1 : ta > tb ? 1 : a.source.localeCompare(b.source);
    })
    .map((s) => s.source);
}

/** 前 8 个依次占槽位，其余共用中性的「其他」色。 */
export function assignToolColors(order: string[]): Map<string, string> {
  const map = new Map<string, string>();
  order.forEach((id, i) => map.set(id, i < CATEGORY_SLOTS ? `var(--lens-cat-${i + 1})` : OTHER_COLOR));
  return map;
}

/** 按固定顺序排列一组工具；不在顺序里的（比如刚出现、/sources 还没刷新）排在最后，按 id。 */
export function sortByToolOrder(ids: string[], order: string[]): string[] {
  const rank = new Map(order.map((id, i) => [id, i]));
  return ids
    .slice()
    .sort((a, b) => (rank.get(a) ?? Infinity) - (rank.get(b) ?? Infinity) || a.localeCompare(b));
}
