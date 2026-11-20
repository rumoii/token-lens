typedef ToolInfo = ({String name, String? logo, String letter, bool darkGlyph});
const tools = <String, ToolInfo>{
  'claude': (
    name: 'Claude Code',
    logo: 'claude-code.png',
    letter: 'C',
    darkGlyph: false,
  ),
  'codex': (name: 'Codex', logo: 'codex.png', letter: 'C', darkGlyph: false),
  'qwen': (name: 'Qwen Code', logo: 'qwen.png', letter: 'Q', darkGlyph: false),
  'dsh': (name: 'DSH', logo: 'deepseek.png', letter: 'D', darkGlyph: false),
  'grok': (name: 'Grok CLI', logo: 'grok.png', letter: 'G', darkGlyph: false),
  'anythingllm': (
    name: 'AnythingLLM',
    logo: null,
    letter: 'A',
    darkGlyph: false,
  ),
  'commandcode': (
    name: 'Command Code',
    logo: 'commandcode.png',
    letter: 'C',
    darkGlyph: false,
  ),
  'aider': (name: 'Aider', logo: null, letter: 'A', darkGlyph: false),
  'pi': (name: 'Pi', logo: 'pi.png', letter: 'P', darkGlyph: true),
  'hermes': (name: 'Hermes', logo: 'hermes.png', letter: 'H', darkGlyph: false),
  'cline': (name: 'Cline', logo: 'cline.png', letter: 'C', darkGlyph: false),
  'gemini': (
    name: 'Gemini CLI',
    logo: 'gemini.png',
    letter: 'G',
    darkGlyph: false,
  ),
  'antigravity': (
    name: 'Antigravity',
    logo: 'antigravity.png',
    letter: 'A',
    darkGlyph: false,
  ),
  'cursor': (name: 'Cursor', logo: 'cursor.png', letter: 'C', darkGlyph: false),
  'opencode': (
    name: 'OpenCode',
    logo: 'opencode.png',
    letter: 'O',
    darkGlyph: false,
  ),
  'kilo': (name: 'Kilo Code', logo: 'kilo.png', letter: 'K', darkGlyph: false),
  'openhands': (
    name: 'OpenHands CLI',
    logo: 'openhands.png',
    letter: 'O',
    darkGlyph: false,
  ),
  'goose': (name: 'Goose', logo: 'goose.png', letter: 'G', darkGlyph: false),
  'zed': (name: 'Zed', logo: null, letter: 'Z', darkGlyph: false),
  'continue': (name: 'Continue', logo: null, letter: 'C', darkGlyph: false),
  'trae': (name: 'Trae', logo: 'trae.png', letter: 'T', darkGlyph: false),
  'copilot': (
    name: 'Copilot',
    logo: 'copilot.png',
    letter: 'C',
    darkGlyph: false,
  ),
  'openclaw': (
    name: 'OpenClaw',
    logo: 'openclaw.png',
    letter: 'O',
    darkGlyph: false,
  ),
  'mimo': (name: 'MiMo Code', logo: 'mimo.png', letter: 'M', darkGlyph: false),
  'kimi': (name: 'Kimi', logo: 'kimi.png', letter: 'K', darkGlyph: false),
  'minimax': (
    name: 'MiniMax Code',
    logo: 'minimax.png',
    letter: 'M',
    darkGlyph: false,
  ),
  'zcode': (name: 'ZCode', logo: 'zcode.png', letter: 'Z', darkGlyph: false),
  'codebuddy': (
    name: 'CodeBuddy',
    logo: 'codebuddy.png',
    letter: 'C',
    darkGlyph: false,
  ),
};
ToolInfo toolOf(String id) =>
    tools[id] ??
    (
      name: id,
      logo: null,
      letter: id.isEmpty ? '?' : id[0].toUpperCase(),
      darkGlyph: false,
    );
