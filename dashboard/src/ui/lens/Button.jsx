import React from "react";

const SIZES = {
  xs: "h-6 px-2 text-micro rounded-md",
  sm: "h-7 px-2.5 text-caption rounded-lg",
  md: "h-8 px-3.5 text-body rounded-lg",
  lg: "h-10 px-5 text-lede rounded-panel"
};

const VARIANTS = {
  primary:
    "bg-clay text-ink-inverse hover:bg-clay-hover active:scale-[0.98] shadow-sm",
  // 单闭合边框：secondary 不带外环，靠半透明填充分层，放进面板里不会套娃。
  secondary:
    "bg-[var(--lens-fill-hover)] text-ink hover:bg-[var(--lens-fill-active)] active:scale-[0.98]",
  ghost:
    "bg-transparent text-ink-secondary hover:bg-[var(--lens-fill-hover)] hover:text-ink active:bg-[var(--lens-fill-active)]"
};

/**
 * 按钮。四档高度对应不同密度，变体只有三种，不提供任意颜色。
 * secondary 遵守单闭合边框：不带边框/外环，靠填充分层。
 *
 * @param {{
 *   children: React.ReactNode,
 *   variant?: 'primary'|'secondary'|'ghost',
 *   size?: keyof typeof SIZES,
 *   className?: string,
 *   as?: React.ElementType,
 *   disabled?: boolean
 * }} props
 */
export function Button({
  children,
  variant = "secondary",
  size = "md",
  className = "",
  as: Component = "button",
  disabled = false,
  ...rest
}) {
  const base =
    "inline-flex select-none items-center justify-center gap-1.5 font-medium transition-all duration-fast ease-lens disabled:cursor-not-allowed disabled:opacity-45 disabled:active:scale-100";
  return (
    <Component
      className={`${base} ${SIZES[size] || SIZES.md} ${VARIANTS[variant] || VARIANTS.secondary} ${className}`}
      disabled={Component === "button" ? disabled : undefined}
      {...rest}
    >
      {children}
    </Component>
  );
}
