import { parseClaude } from './claude.js';
import { parseCodex } from './codex.js';
import { parseQwen } from './qwen.js';
import { parseDsh } from './dsh.js';
import { parseGrok } from './grok.js';
import { parseAider } from './aider.js';
import { parsePi } from './pi.js';
import { parseHermes } from './hermes.js';
import { parseCline } from './cline.js';
import { parseGemini } from './gemini.js';
import { parseCursor } from './cursor.js';
import { parseOpencode } from './opencode.js';
import { parseKilo } from './kilo.js';
import { parseOpenhands } from './openhands.js';
import { parseGoose } from './goose.js';
import { parseZed } from './zed.js';
import { parseContinue } from './continue.js';
import { parseTrae } from './trae.js';
import { parseCopilot } from './copilot.js';
import { parseOpenclaw } from './openclaw.js';
import { parseMimo } from './mimo.js';
import { parseKimi } from './kimi.js';
import { parseMinimax } from './minimax.js';
import { parseCodebuddy } from './codebuddy.js';
import { parseZcode } from './zcode.js';
import { parseCommandcode } from './commandcode.js';
import { parseAnythingllm } from './anythingllm.js';

export const adapters = {
  claude: parseClaude,
  codex: parseCodex,
  qwen: parseQwen,
  dsh: parseDsh,
  grok: parseGrok,
  aider: parseAider,
  pi: parsePi,
  hermes: parseHermes,
  cline: parseCline,
  gemini: parseGemini,
  cursor: parseCursor,
  opencode: parseOpencode,
  kilo: parseKilo,
  openhands: parseOpenhands,
  goose: parseGoose,
  zed: parseZed,
  continue: parseContinue,
  trae: parseTrae,
  copilot: parseCopilot,
  openclaw: parseOpenclaw,
  mimo: parseMimo,
  kimi: parseKimi,
  minimax: parseMinimax,
  codebuddy: parseCodebuddy,
  zcode: parseZcode,
  commandcode: parseCommandcode,
  anythingllm: parseAnythingllm
};

/**
 * 各适配器的口径版本。改了某个适配器的取值、身份或时间口径，就把它加一：
 * 账本据此判断旧行是否来自旧口径，允许累计值因修正而下降，并停用旧口径独有的产出。
 * 没列出的按第 1 版处理。
 */
export const PARSER_REV = {
  claude: 3,
  codex: 4,
  qwen: 7,
  dsh: 3,
  grok: 3,
  aider: 5,
  pi: 6,
  hermes: 3,
  cline: 3,
  gemini: 3,
  cursor: 3,
  opencode: 6,
  kilo: 3,
  openhands: 1,
  goose: 5,
  zed: 3,
  continue: 3,
  trae: 4,
  copilot: 4,
  openclaw: 5,
  mimo: 4,
  kimi: 5,
  minimax: 4,
  codebuddy: 4,
  zcode: 1,
  commandcode: 1,
  anythingllm: 1
};

/**
 * @param {string} source
 * @returns {number}
 */
export function parserRevOf(source) {
  return PARSER_REV[source] ?? 1;
}

/**
 * 注册第三方扩展适配器契约。
 *
 * @param {string} source 工具标识名
 * @param {(filePath: string) => AsyncIterable<Object>} parseFn 异步迭代生成器函数
 */
export function registerAdapter(source, parseFn) {
  if (typeof parseFn !== 'function') {
    throw new TypeError('Adapter must provide an async iterable parse function');
  }
  adapters[source] = parseFn;
}
