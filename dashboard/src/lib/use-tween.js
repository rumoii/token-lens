import { useEffect, useRef, useState } from "react";
import { useReducedMotion } from "motion/react";

const easeOut = (t) => 1 - (1 - t) ** 3;

/**
 * 数字过渡：第一次从 0 滚到目标值（enterMs，先等 delayMs），之后目标变了就从当前显示值滚到新值（morphMs）。
 * 系统开了「减少动态效果」时直接返回目标值。时长按 0.7× 速度折算过。
 */
export function useTween(target, { enterMs = 860, morphMs = 570, delayMs = 230 } = {}) {
  const reduce = useReducedMotion();
  const [shown, setShown] = useState(reduce ? target : 0);
  const shownRef = useRef(shown);
  const first = useRef(true);
  useEffect(() => {
    if (reduce || !Number.isFinite(target)) {
      shownRef.current = target;
      setShown(target);
      return undefined;
    }
    const from = shownRef.current;
    const dur = first.current ? enterMs : morphMs;
    const wait = first.current ? delayMs : 0;
    first.current = false;
    let raf = 0;
    const start = performance.now() + wait;
    const step = (now) => {
      const p = Math.min(1, Math.max(0, (now - start) / dur));
      const v = from + (target - from) * easeOut(p);
      shownRef.current = v;
      setShown(v);
      if (p < 1) raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
  }, [target, reduce, enterMs, morphMs, delayMs]);
  return shown;
}
