/**
 * 品牌标记：一枚镜片，左上一道高光，里面是高低不一的柱子。
 *
 * 侧栏的 Mark 和 public/ 下的图标（scripts/icons/build-icons.mjs 生成）都从这里取几何，
 * 改形状只改这一处，再重新生成图标。
 *
 * 坐标在 32×32 画布里。small 用于 32px 及以下：三根更粗的柱子，没有高光，线也更粗，
 * 否则 16px 下柱子会糊成一团。
 *
 * 每个形状带一个 role，由使用方映射成颜色：
 *   ring   镜片的环
 *   glint  高光
 *   bar    普通柱子
 *   accent 最高的那根柱子
 */

const RING_R = 10.5;
const BASELINE = 21.5;

const LARGE = { stroke: 2.2, barWidth: 2.6, accent: 2, bars: [[10.6, 6], [14.4, 10], [18.2, 13], [22, 7]] };
const SMALL = { stroke: 2.53, barWidth: 3.4, accent: 1, bars: [[11.2, 7], [16, 11], [20.8, 5]] };

/** 小于等于这个像素尺寸时用 small 版本。 */
export const MARK_SMALL_MAX = 32;

function arc(r, fromDeg, toDeg) {
  const at = (deg) => {
    const t = (deg * Math.PI) / 180;
    return `${(16 + r * Math.cos(t)).toFixed(2)} ${(16 + r * Math.sin(t)).toFixed(2)}`;
  };
  return `M${at(fromDeg)}A${r} ${r} 0 0 1 ${at(toDeg)}`;
}

/** @returns {Array<{ type: "circle" | "path" | "rect", role: "ring" | "glint" | "bar" | "accent", attrs: Record<string, string | number> }>} */
export function markShapes({ small = false } = {}) {
  const g = small ? SMALL : LARGE;
  const shapes = [
    { type: "circle", role: "ring", attrs: { cx: 16, cy: 16, r: RING_R, fill: "none", strokeWidth: g.stroke } }
  ];
  if (!small) {
    shapes.push({
      type: "path",
      role: "glint",
      attrs: { d: arc(RING_R - 3, 200, 250), fill: "none", strokeWidth: +(g.stroke * 0.7).toFixed(2), strokeLinecap: "round" }
    });
  }
  g.bars.forEach(([x, h], i) => {
    shapes.push({
      type: "rect",
      role: i === g.accent ? "accent" : "bar",
      attrs: { x: +(x - g.barWidth / 2).toFixed(2), y: BASELINE - h, width: g.barWidth, height: h, rx: +(g.barWidth / 2.6).toFixed(2) }
    });
  });
  return shapes;
}

/** 环和高光是描边，柱子是填充。 */
export function isStroked(role) {
  return role === "ring" || role === "glint";
}
