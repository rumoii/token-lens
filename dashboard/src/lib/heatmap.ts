/**
 * 日历热力图的几何：把日序列铺成「周 × 星期」的格子矩阵。
 *
 * 与图表几何分开，因为这里的坐标是格子索引，不是像素。
 */

export type DayPoint = { day: string; value: number };

export type Cell = {
  /** ISO 日期；范围外的补位格为 null */
  day: string | null;
  value: number;
  /** 0-4 的分档，用于取色 */
  level: number;
  /** 是否在本周之前（跨月补位） */
  outside: boolean;
};

const DAY_MS = 86_400_000;

/** @param {Date|string} value */
function toUtcDate(value: string): Date {
  const [y, m, d] = value.slice(0, 10).split("-").map(Number);
  return new Date(Date.UTC(y, (m || 1) - 1, d || 1));
}

/** @param {Date} date */
export function isoDay(date: Date): string {
  return date.toISOString().slice(0, 10);
}

/**
 * 分档：0 表示无用量，1-4 按最大值的四分位。
 *
 * 用对数分档，否则长尾会把大部分日子压成同一档。
 *
 * @param {number} value
 * @param {number} max
 */
export function levelOf(value: number, max: number): number {
  if (!Number.isFinite(value) || value <= 0) return 0;
  if (!Number.isFinite(max) || max <= 0) return 0;
  const ratio = Math.log1p(value) / Math.log1p(max);
  if (ratio <= 0.25) return 1;
  if (ratio <= 0.5) return 2;
  if (ratio <= 0.75) return 3;
  return 4;
}

/**
 * 铺格子。第一列从起始日所在周的周一开始，最后一列覆盖到结束日。
 *
 * @param points 已按日期排序的日序列
 * @param options 可选显式起止（否则取序列首尾）
 * @returns {{ weeks: Cell[][], max: number, total: number }}
 */
export function buildHeatmap(
  points: DayPoint[],
  options: { from?: string; to?: string; weekStartsOn?: 0 | 1 } = {}
): { weeks: Cell[][]; max: number; total: number } {
  const weekStartsOn = options.weekStartsOn ?? 1;

  if (points.length === 0 && !options.from) {
    return { weeks: [], max: 0, total: 0 };
  }

  const byDay = new Map(points.map((p) => [p.day.slice(0, 10), p.value]));
  const total = points.reduce((sum, p) => sum + p.value, 0);
  const max = points.reduce((peak, p) => Math.max(peak, p.value), 0);
  const empty = { weeks: [], max, total };

  const first = options.from ?? points[0]?.day;
  const last = options.to ?? points[points.length - 1]?.day;
  if (!first || !last) return empty;

  const start = toUtcDate(first);
  const end = toUtcDate(last);

  // 退到本周第一天，保证每列对齐同一星期
  const offset = (start.getUTCDay() - weekStartsOn + 7) % 7;
  const cursor = new Date(start.getTime() - offset * DAY_MS);

  const weeks: Cell[][] = [];
  let column: Cell[] = [];

  while (cursor.getTime() <= end.getTime() || column.length > 0) {
    const day = isoDay(cursor);
    const inRange = cursor.getTime() >= start.getTime() && cursor.getTime() <= end.getTime();
    const value = inRange ? byDay.get(day) ?? 0 : 0;

    column.push({
      day: inRange ? day : null,
      value,
      level: levelOf(value, max),
      outside: !inRange
    });

    if (column.length === 7) {
      weeks.push(column);
      column = [];
      if (cursor.getTime() > end.getTime()) break;
    } else if (cursor.getTime() > end.getTime()) {
      // 收尾：补满最后一列再停
      while (column.length < 7) {
        column.push({ day: null, value: 0, level: 0, outside: true });
      }
      weeks.push(column);
      break;
    }

    cursor.setUTCDate(cursor.getUTCDate() + 1);
  }

  return { weeks, max, total };
}

/**
 * 把毫秒跨度说成人话。空值返回 null，由调用方决定显示什么。
 *
 * @param {number|null|undefined} ms
 */
export function formatSpan(ms: number | null | undefined): string | null {
  if (ms === null || ms === undefined || !Number.isFinite(ms) || ms <= 0) return null;
  const hours = ms / 3_600_000;
  if (hours < 1) return `${Math.round(ms / 60_000)} 分`;
  if (hours < 48) return `${hours.toFixed(1)} 小时`;
  return `${(hours / 24).toFixed(1)} 天`;
}
