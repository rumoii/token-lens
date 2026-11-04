import { useCallback, useState } from "react";

/**
 * 表格行的方向键漫游焦点（roving tabindex）。
 *
 * 一屏里只有当前行是 Tab 停靠点，↑↓ 在行间移动，Home/End 跳首尾。
 * 挂载方式：`<tbody {...rowGroupProps}>`，每个 `<tr {...rowProps(i)}>`。
 *
 * @param {number} count 渲染出的行数
 */
export function useRovingRows(count) {
  const [index, setIndex] = useState(0);
  const safeIndex = Math.min(index, Math.max(0, count - 1));

  const onKeyDown = useCallback(
    (event) => {
      let next = null;
      if (event.key === "ArrowDown") next = safeIndex + 1;
      else if (event.key === "ArrowUp") next = safeIndex - 1;
      else if (event.key === "Home") next = 0;
      else if (event.key === "End") next = count - 1;
      if (next === null) return;

      event.preventDefault();
      const rows = event.currentTarget.querySelectorAll("tr");
      const target = Math.max(0, Math.min(next, rows.length - 1));
      setIndex(target);
      if (rows[target]) rows[target].focus();
    },
    [safeIndex, count]
  );

  const rowProps = useCallback(
    (i) => ({
      tabIndex: i === safeIndex ? 0 : -1,
      onFocus: () => setIndex(i)
    }),
    [safeIndex]
  );

  return { rowGroupProps: { onKeyDown }, rowProps };
}
