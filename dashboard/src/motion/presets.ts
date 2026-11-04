/**
 * 动效物理预设。数值取自 Claude Design System（open-claude-ui, MIT, 作者 Caho1）
 * 逆向出的二阶阻尼谐振子参数（stiffness / damping / mass），实现与命名是本仓库自己的。
 *
 * 与 `styles/tokens.css` 的 cubic-bezier 常量分工：纯 CSS 过渡用那里的近似曲线；
 * 需要真实过冲与咬合的控件（如分段指示器）用这里的弹簧，由 `motion` 驱动。
 */

export type Spring = {
  type: "spring";
  stiffness: number;
  damping: number;
  mass: number;
};

/** 明显过冲（阻尼比约 0.61）：分段指示器、开关等需要「咬合」手感的位移。 */
export const SPRING_BOUNCY: Spring = { type: "spring", stiffness: 600, damping: 30, mass: 1 };

/** 轻微过冲（阻尼比约 0.78）：快而稳的位移与状态切换。 */
export const SPRING_SNAPPY: Spring = { type: "spring", stiffness: 320, damping: 28, mass: 1 };

/** 柔和回落：弹窗、抽屉、卡片入场。 */
export const SPRING_GENTLE: Spring = { type: "spring", stiffness: 380, damping: 18, mass: 1 };

/** 重物急停（小质量、高阻尼）：拖拽释放、吸附定位。 */
export const SPRING_HEAVY_SNAP: Spring = { type: "spring", stiffness: 1200, damping: 80, mass: 0.1 };
