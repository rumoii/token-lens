import React from "react";
import { buildHeatmap } from "../../lib/heatmap";

const LEVEL_STYLE = [
  { background: "var(--lens-fill-hover)" },
  { background: "var(--lens-clay-20)" },
  { background: "var(--lens-clay-35)" },
  { background: "var(--lens-clay-55)" },
  { background: "var(--lens-clay)" }
];

const WEEKDAYS = ["一", "二", "三", "四", "五", "六", "日"];
const CELL = 13;
const GAP = 3;

/**
 * 日历热力图。列是周、行是星期，格子按对数分档取色。
 *
 * 没有用量的日子是最浅一档，不是留白——留白会看不出范围。
 * 格子固定 13px、星期标签按行高对齐，不用 justify-between 拉开，
 * 否则卡片一高标签就散到看不见。
 *
 * @param {{
 *   points: Array<{ day: string, value: number }>,
 *   from?: string,
 *   to?: string,
 *   formatValue: (value: number) => string,
 *   ariaLabel: string
 * }} props
 */
export function Heatmap({ points, from, to, formatValue, ariaLabel }) {
  const [hover, setHover] = React.useState(null);
  const { weeks, max, total } = buildHeatmap(points, { from, to });

  if (weeks.length === 0) {
    return <p className="py-6 text-center text-caption text-ink-muted">这个范围内没有可按日归属的用量。</p>;
  }

  const rowStyle = { height: CELL, gap: GAP };

  return (
    <div className="flex h-full min-h-0 flex-col justify-center">
      <div className="flex gap-2">
        <div className="flex flex-col text-[9px] leading-none text-ink-muted" style={{ gap: GAP }}>
          {WEEKDAYS.map((label, index) => (
            <span
              key={label}
              className="flex items-center justify-end"
              style={{ height: CELL, width: 10 }}
            >
              {index % 2 === 0 ? label : ""}
            </span>
          ))}
        </div>

        <div className="min-w-0 flex-1 overflow-x-auto">
          <div className="flex" style={{ gap: GAP }}>
            {weeks.map((week, weekIndex) => (
              <div key={weekIndex} className="flex flex-col" style={{ gap: GAP }}>
                {week.map((cell, dayIndex) => {
                  const active = hover?.week === weekIndex && hover?.day === dayIndex;
                  return (
                    <div
                      key={dayIndex}
                      onMouseEnter={() => cell.day && setHover({ week: weekIndex, day: dayIndex, cell })}
                      onMouseLeave={() => setHover(null)}
                      title={cell.day ? `${cell.day} · ${formatValue(cell.value)}` : undefined}
                      style={
                        cell.outside
                          ? { height: CELL, width: CELL }
                          : { height: CELL, width: CELL, ...LEVEL_STYLE[cell.level] }
                      }
                      className={`rounded-[2px] transition-shadow duration-fast ease-lens ${
                        active ? "ring-1 ring-clay ring-offset-1 ring-offset-[var(--lens-surface-2)]" : ""
                      }`}
                      aria-hidden={!cell.day}
                    />
                  );
                })}
              </div>
            ))}
          </div>
        </div>
      </div>

      <div className="mt-2 flex items-center justify-between gap-2 text-[10px] leading-4 text-ink-muted">
        <span className="truncate">
          {hover?.cell
            ? `${hover.cell.day} · ${formatValue(hover.cell.value)}`
            : `共 ${formatValue(total)} · 峰值 ${formatValue(max)}`}
        </span>
        <span className="flex shrink-0 items-center gap-1">
          少
          {LEVEL_STYLE.map((style, index) => (
            <span key={index} className="h-2 w-2 rounded-[2px]" style={style} />
          ))}
          多
        </span>
      </div>

      <p className="sr-only">{ariaLabel}</p>
    </div>
  );
}

