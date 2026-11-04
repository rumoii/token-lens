import React, { useState } from "react";
import { toolOf } from "../../lib/tools";

const SIZES = [16, 20, 24, 28, 32, 40];

/**
 * 工具磁贴：有 logo 时白底圆角磁贴（深色 logo 用深底），logo 缺失或加载失败
 * 时退回品牌色底 + 白色首字母。装饰性图片，alt 留空，名称放 title。
 *
 * @param {{ id: string, size?: 16 | 20 | 24 | 28 | 32 | 40 }} props
 */
export function ToolTile({ id, size = 24 }) {
  const tool = toolOf(id);
  const [failed, setFailed] = useState(false);
  const s = SIZES.includes(size) ? size : 24;
  const showLogo = Boolean(tool.logo) && !failed;

  return (
    <span
      title={tool.name}
      style={{
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        width: s,
        height: s,
        flexShrink: 0,
        verticalAlign: "middle",
        borderRadius: s * 0.28,
        overflow: "hidden",
        background: showLogo
          ? tool.darkGlyph
            ? "var(--lens-tile-dark)"
            : "var(--lens-tile)"
          : tool.color,
        boxShadow: showLogo
          ? `inset 0 0 0 1px var(${tool.darkGlyph ? "--lens-tile-dark-ring" : "--lens-tile-ring"})`
          : "none"
      }}
    >
      {showLogo ? (
        <img
          src={`/brand-logos/${tool.logo}`}
          alt=""
          onError={() => setFailed(true)}
          style={{ width: "68%", height: "68%", objectFit: "contain" }}
        />
      ) : (
        <span
          style={{
            color: "var(--lens-tile-ink)",
            fontWeight: 600,
            fontSize: s * 0.46,
            letterSpacing: "-0.02em",
            lineHeight: 1
          }}
        >
          {tool.letter}
        </span>
      )}
    </span>
  );
}
