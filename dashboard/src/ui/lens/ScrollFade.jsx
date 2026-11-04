import React, { useCallback, useEffect, useRef, useState } from "react";

/**
 * 长表容器：横向还有内容时，在左右边缘渐隐提示，滚到头渐隐自动消失。
 *
 * 只接管横向滚动（当前两处长表都是横向出界），渐隐层不拦截指针、不遮挡焦点。
 *
 * @param {{ children: React.ReactNode, className?: string, bodyClassName?: string }} props
 */
export function ScrollFade({ children, className = "", bodyClassName = "" }) {
  const scroller = useRef(null);
  const [fade, setFade] = useState({ left: false, right: false });

  const measure = useCallback(() => {
    const el = scroller.current;
    if (!el) return;
    const left = el.scrollLeft > 0;
    const right = el.scrollLeft + el.clientWidth < el.scrollWidth - 1;
    setFade((prev) => (prev.left === left && prev.right === right ? prev : { left, right }));
  }, []);

  useEffect(() => {
    measure();
    const el = scroller.current;
    if (!el || typeof ResizeObserver === "undefined") return undefined;
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    for (const child of el.children) observer.observe(child);
    return () => observer.disconnect();
  }, [measure, children]);

  return (
    <div className={`relative ${className}`}>
      <div ref={scroller} onScroll={measure} className={`overflow-x-auto ${bodyClassName}`}>
        {children}
      </div>
      <span
        aria-hidden
        className={`pointer-events-none absolute inset-y-0 left-0 w-6 bg-gradient-to-r from-surface-2 to-transparent transition-opacity duration-fast ease-lens ${
          fade.left ? "opacity-100" : "opacity-0"
        }`}
      />
      <span
        aria-hidden
        className={`pointer-events-none absolute inset-y-0 right-0 w-6 bg-gradient-to-l from-surface-2 to-transparent transition-opacity duration-fast ease-lens ${
          fade.right ? "opacity-100" : "opacity-0"
        }`}
      />
    </div>
  );
}
