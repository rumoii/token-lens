// 工具元数据：名称、品牌色、logo、首字母兜底。id 与后端 source 名一致。
// 颜色引用 tokens.css 的 --lens-tool-*，浅深同值。
// logo 文件在 dashboard/public/brand-logos/；没有 logo 的工具用品牌色底 + 首字母。

export const TOOLS = {
  claude: { name: "Claude Code", color: "var(--lens-tool-claude)", logo: "claude-code.svg", letter: "C", darkGlyph: false },
  codex: { name: "Codex", color: "var(--lens-tool-codex)", logo: "codex.svg", letter: "C", darkGlyph: false },
  qwen: { name: "Qwen Code", color: "var(--lens-tool-qwen)", logo: null, letter: "Q", darkGlyph: false },
  dsh: { name: "DSH", color: "var(--lens-tool-dsh)", logo: "deepseek.svg", letter: "D", darkGlyph: false },
  grok: { name: "Grok CLI", color: "var(--lens-tool-grok)", logo: "grok.svg", letter: "G", darkGlyph: false },
  aider: { name: "Aider", color: "var(--lens-tool-aider)", logo: null, letter: "A", darkGlyph: false },
  pi: { name: "Pi", color: "var(--lens-tool-pi)", logo: "pi.svg", letter: "P", darkGlyph: true },
  hermes: { name: "Hermes", color: "var(--lens-tool-hermes)", logo: "hermes.svg", letter: "H", darkGlyph: false },
  cline: { name: "Cline", color: "var(--lens-tool-cline)", logo: "cline.svg", letter: "C", darkGlyph: false },
  gemini: { name: "Gemini CLI", color: "var(--lens-tool-gemini)", logo: "gemini.svg", letter: "G", darkGlyph: false },
  cursor: { name: "Cursor", color: "var(--lens-tool-cursor)", logo: "cursor.svg", letter: "C", darkGlyph: false },
  opencode: { name: "OpenCode", color: "var(--lens-tool-opencode)", logo: "opencode.svg", letter: "O", darkGlyph: false },
  kilo: { name: "Kilo Code", color: "var(--lens-tool-kilo)", logo: null, letter: "K", darkGlyph: false },
  openhands: { name: "OpenHands CLI", color: "var(--lens-tool-openhands)", logo: null, letter: "O", darkGlyph: false },
  goose: { name: "Goose", color: "var(--lens-tool-goose)", logo: null, letter: "G", darkGlyph: false },
  zed: { name: "Zed", color: "var(--lens-tool-zed)", logo: null, letter: "Z", darkGlyph: false },
  continue: { name: "Continue", color: "var(--lens-tool-continue)", logo: null, letter: "C", darkGlyph: false },
  trae: { name: "Trae", color: "var(--lens-tool-trae)", logo: null, letter: "T", darkGlyph: false },
  copilot: { name: "Copilot", color: "var(--lens-tool-copilot)", logo: "copilot.svg", letter: "C", darkGlyph: false },
  openclaw: { name: "OpenClaw", color: "var(--lens-tool-openclaw)", logo: "openclaw.svg", letter: "O", darkGlyph: false },
  mimo: { name: "MiMo Code", color: "var(--lens-tool-mimo)", logo: "mimo.svg", letter: "M", darkGlyph: false },
  kimi: { name: "Kimi", color: "var(--lens-tool-kimi)", logo: "kimi.svg", letter: "K", darkGlyph: false },
  minimax: { name: "MiniMax Code", color: "var(--lens-tool-minimax)", logo: null, letter: "M", darkGlyph: false },
  zcode: { name: "ZCode", color: "var(--lens-tool-zcode)", logo: "zcode.svg", letter: "Z", darkGlyph: false },
  codebuddy: { name: "CodeBuddy", color: "var(--lens-tool-codebuddy)", logo: "codebuddy.svg", letter: "C", darkGlyph: false }
};

/** 未知 id 的兜底：中性色 + 首字母，不让渲染崩在 undefined 上。 */
export function toolOf(id) {
  return (
    TOOLS[id] || {
      name: id,
      color: "var(--lens-text-muted)",
      logo: null,
      letter: String(id)[0].toUpperCase(),
      darkGlyph: false
    }
  );
}
