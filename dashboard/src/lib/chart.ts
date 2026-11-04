/**
 * 图表几何。抽成纯函数，便于单独测，避免把数学塞进 JSX。
 */

export type Point = { x: number; y: number };

/**
 * 把一串数值映射到 SVG 坐标。零值贴底，最大值贴顶（留 6% 余量避免顶格）。
 *
 * @param values 按时间排序的数值
 * @param width 绘图区宽度
 * @param height 绘图区高度
 */
export function scaleSeries(values: number[], width: number, height: number): Point[] {
  if (values.length === 0) return [];
  const max = Math.max(...values, 0) || 1;
  const top = height * 0.06;
  const usable = height - top;
  const lastIndex = Math.max(values.length - 1, 1);

  return values.map((value, index) => ({
    x: values.length === 1 ? width / 2 : (index / lastIndex) * width,
    y: height - (Math.max(value, 0) / max) * usable
  }));
}

/** 折线路径。 */
export function linePath(points: Point[]): string {
  if (points.length === 0) return "";
  return points.map((p, i) => `${i === 0 ? "M" : "L"}${round(p.x)},${round(p.y)}`).join(" ");
}

/** 面积路径：折线 + 底边闭合。 */
export function areaPath(points: Point[], height: number): string {
  if (points.length === 0) return "";
  const line = linePath(points);
  const first = points[0];
  const last = points[points.length - 1];
  return `${line} L${round(last.x)},${round(height)} L${round(first.x)},${round(height)} Z`;
}

/**
 * 堆叠序列：各层按累计值放样，返回每层的上沿坐标（底层在最前）。
 * 同一时刻各层高度之和即总量高度，最大累计值贴顶（同样留 6% 余量）。
 *
 * @param layers 按层序排列的数值序列，每层与时间轴等长
 */
export function stackedPoints(layers: number[][], width: number, height: number): Point[][] {
  const length = layers.reduce((max, layer) => Math.max(max, layer.length), 0);
  if (length === 0) return layers.map(() => []);

  const totals = Array.from({ length }, (_, i) =>
    layers.reduce((sum, layer) => sum + Math.max(layer[i] ?? 0, 0), 0)
  );
  const max = Math.max(...totals, 0) || 1;
  const top = height * 0.06;
  const usable = height - top;
  const lastIndex = Math.max(length - 1, 1);

  let acc = Array.from({ length }, () => 0);
  return layers.map((layer) => {
    acc = acc.map((value, i) => value + Math.max(layer[i] ?? 0, 0));
    return acc.map((value, i) => ({
      x: length === 1 ? width / 2 : (i / lastIndex) * width,
      y: height - (value / max) * usable
    }));
  });
}

/** 两条折线之间的面积：上沿正走，下沿倒走，闭合。 */
export function areaBetweenPath(top: Point[], bottom: Point[]): string {
  if (top.length === 0 || bottom.length !== top.length) return "";
  const backward = [...bottom]
    .reverse()
    .map((p) => `L${round(p.x)},${round(p.y)}`)
    .join(" ");
  return `${linePath(top)} ${backward} Z`;
}

/**
 * 取一个「整」的纵轴上限，用于刻度标注：1/2/5 × 10^n。
 *
 * @param value 数据最大值
 */
export function niceCeiling(value: number): number {
  if (!Number.isFinite(value) || value <= 0) return 0;
  const magnitude = 10 ** Math.floor(Math.log10(value));
  const normalized = value / magnitude;
  const step = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10;
  return step * magnitude;
}

/**
 * 柱宽的百分比：最大值占满，最小可见 2%，避免细到尾数看不见。
 *
 * @param value 当前值
 * @param max 本组最大值
 */
export function barWidthPercent(value: number, max: number): number {
  if (!Number.isFinite(value) || value <= 0) return 0;
  if (!Number.isFinite(max) || max <= 0) return 0;
  return Math.max(2, Math.min(100, (value / max) * 100));
}

/**
 * 环形图分段。
 *
 * 传入各段数值，返回每段的起止角度（度，0 在 12 点方向、顺时针）。
 * 零值段不占角度也不留缝，避免出现 0° 的伪影。
 *
 * @param values 各段数值
 * @param options.gapDeg 相邻段之间的留白角度，默认 2
 */
export function ringSegments(
  values: number[],
  options: { gapDeg?: number } = {}
): Array<{ index: number; startDeg: number; endDeg: number; share: number }> {
  const gapDeg = options.gapDeg ?? 2;
  const positive = values.map((value) => (Number.isFinite(value) && value > 0 ? value : 0));
  const total = positive.reduce((sum, value) => sum + value, 0);
  if (total <= 0) return [];

  const nonZero = positive.filter((value) => value > 0).length;
  const totalGap = nonZero > 1 ? gapDeg * nonZero : 0;

  const segments: Array<{ index: number; startDeg: number; endDeg: number; share: number }> = [];
  let cursor = 0;

  positive.forEach((value, index) => {
    if (value <= 0) return;
    const share = value / total;
    const sweep = share * (360 - totalGap);
    segments.push({ index, startDeg: cursor, endDeg: cursor + sweep, share });
    cursor += sweep + (nonZero > 1 ? gapDeg : 0);
  });

  return segments;
}

/**
 * 把起止角度转成 stroke-dasharray 用的偏移与长度。
 *
 * @param startDeg 起始角度（0 = 12 点方向）
 * @param endDeg 结束角度
 * @param radius 半径（与 circumference 对应）
 */
export function arcDash(startDeg: number, endDeg: number, radius: number): { dash: number; gap: number; offset: number } {
  const circumference = 2 * Math.PI * radius;
  const length = ((endDeg - startDeg) / 360) * circumference;
  return {
    dash: length,
    gap: circumference - length,
    // SVG 圆从 3 点方向开始，减 90° 转到 12 点方向
    offset: -((startDeg - 90) / 360) * circumference
  };
}

function round(n: number): number {
  return Math.round(n * 100) / 100;
}

