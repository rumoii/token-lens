/** @type {import("tailwindcss").Config} */
const defaultTheme = require("tailwindcss/defaultTheme");

/**
 * 令牌在 `src/styles/tokens.css`。这里只把 CSS 变量接到 Tailwind，
 * 让类名和变量是同一个来源，改色只改一处。
 */
module.exports = {
  darkMode: "class",
  content: ["./index.html", "./src/**/*.{js,jsx,ts,tsx}"],
  theme: {
    extend: {
      colors: {
        surface: {
          0: "var(--lens-surface-0)",
          1: "var(--lens-surface-1)",
          2: "var(--lens-surface-2)",
          3: "var(--lens-surface-3)"
        },
        ink: {
          DEFAULT: "var(--lens-text)",
          secondary: "var(--lens-text-secondary)",
          muted: "var(--lens-text-muted)",
          faint: "var(--lens-text-faint)",
          inverse: "var(--lens-text-inverse)"
        },
        clay: {
          DEFAULT: "var(--lens-clay)",
          hover: "var(--lens-clay-hover)",
          wash: "var(--lens-clay-wash)",
          ink: "var(--lens-clay-ink)"
        },
        fill: {
          hover: "var(--lens-fill-hover)",
          active: "var(--lens-fill-active)"
        },
        line: {
          DEFAULT: "var(--lens-line)",
          soft: "var(--lens-line-soft)",
          strong: "var(--lens-line-strong)",
          heavy: "var(--lens-line-heavy)"
        },
        signal: {
          ok: "var(--lens-ok)",
          warn: "var(--lens-warn)",
          danger: "var(--lens-danger)"
        }
      },
      fontFamily: {
        sans: ["'Geist'", ...defaultTheme.fontFamily.sans, "'PingFang SC'", "'Microsoft YaHei'"],
        mono: ["'Geist Mono'", "'SF Mono'", "ui-monospace", "Menlo", "Consolas", "monospace"],
        serif: ["var(--lens-font-serif)"]
      },
      fontSize: {
        micro: ["11px", { lineHeight: "1.3", letterSpacing: "0.02em" }],
        caption: ["12px", { lineHeight: "1.4" }],
        body: ["14px", { lineHeight: "1.55" }],
        lede: ["16px", { lineHeight: "1.5" }],
        title: ["20px", { lineHeight: "1.3", letterSpacing: "-0.01em" }],
        display: ["32px", { lineHeight: "1.1", letterSpacing: "-0.02em" }],
        hero: ["44px", { lineHeight: "1", letterSpacing: "-0.03em" }]
      },
      borderRadius: {
        xs: "var(--lens-radius-xs)",
        sm: "var(--lens-radius-sm)",
        md: "var(--lens-radius-md)",
        lg: "var(--lens-radius-lg)",
        panel: "var(--lens-radius-panel)",
        xl: "var(--lens-radius-xl)",
        "2xl": "var(--lens-radius-2xl)",
        pill: "var(--lens-radius-pill)"
      },
      boxShadow: {
        sm: "var(--lens-shadow-sm)",
        md: "var(--lens-shadow-md)",
        panel: "var(--lens-shadow-panel)",
        popover: "var(--lens-shadow-popover)",
        card: "var(--lens-shadow-card)",
        hover: "var(--lens-shadow-hover)",
        pop: "var(--lens-shadow-pop)",
        thumb: "var(--lens-shadow-thumb)"
      },
      transitionTimingFunction: {
        lens: "var(--lens-ease)"
      },
      transitionDuration: {
        fast: "120ms",
        lens: "160ms"
      },
      maxWidth: {
        reading: "72rem"
      },
      spacing: {
        sidebar: "18rem"
      }
    }
  },
  plugins: []
};
