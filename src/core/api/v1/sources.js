import { existsSync } from 'node:fs';
import { adapters } from '../../adapters/index.js';
import { discoverAll } from '../../discovery.js';
import { snapshotMeta } from './common.js';

/**
 * 每个来源的证据等级，与 specs/adapters.md 的第三节表格一致。
 * A = 用本机真实样本对照过；B = 只有合成样本。没在表里的按 B 处理。
 */
const EVIDENCE = {
  claude: 'A',
  codex: 'A',
  qwen: 'A',
  pi: 'A',
  dsh: 'A',
  kimi: 'A',
  mimo: 'B',
  minimax: 'B',
  zcode: 'B',
  codebuddy: 'B',
  commandcode: 'B',
  anythingllm: 'B'
};

/**
 * 每个来源的口径限制，与 specs/adapters.md 的「已知限制」列一致。
 * 这些是使用者需要知道的事实，不是免责声明。
 *
 * 每条是 [口径原文, 给使用者看的说明, 影响]。原文出现在 `limits`，说明出现在 `notes`；
 * 改口径时两者一起改。`affects` 表示数字会因此有偏差或缺一块，`handled` 表示已经处理、不影响总量。
 */
const SOURCE_LIMITS = {
  claude: [['分支或续接复制的消息只计一次', '同一条消息被分支或续接复制进另一个会话时只计一次，算在原始会话里。', 'handled']],
  codex: [
    ['cached ⊂ input，已在适配层扣减', 'Codex 报的输入里包含缓存的部分，这里已经拆开，不会重复算。', 'handled'],
    ['同一 payload 并存三种累计表示，只取 usage', '同一份用量在日志里写了三遍，只取其中一份。', 'handled']
  ],
  qwen: [
    ['输入含缓存，已扣 cachedTokens', '输入里包含缓存的部分，已经拆开。', 'handled'],
    ['thoughtsTokens 是否已含在输出里，按 totalTokens 判断', '模型「思考」用的 token 按客户端自报的总数判断是否已经算在输出里，不会重复算。', 'handled'],
    ['条目 id 是条目身份，不是会话身份', '会话按日志里的会话编号归并，不按单条记录。', 'handled']
  ],
  dsh: [
    ['累计型：一个会话只有一条快照', '只记录每个会话的总数：看不到会话里每次请求的用量；会话跨天时，没法拆到每一天。', 'affects'],
    ['模型缺失时不计价', '日志里没写模型时，这条用量不估算金额。', 'affects']
  ],
  grok: [['只有 turn_completed 带用量', '只有一轮对话完整结束时才写用量，中途打断的那一轮不计。', 'affects']],
  aider: [['commit_hash 不作会话标识：一次提交不等于一场对话', '一次提交不等于一次对话，所以不按提交划分会话。', 'handled']],
  pi: [['会话头与用量不在同一行', '会话信息和用量写在不同的行，已经对上。', 'handled']],
  hermes: [
    ['累计型：一个会话一条快照', '只记录每个会话的总数，看不到每次请求。', 'affects'],
    ['两张表结构不同，优先细粒度表', '新旧两种日志都能读，优先用更细的那种。', 'handled']
  ],
  cline: [
    ['当前 Cline 与 Roo Code 的用量格式尚未接入', '读取的字段没有找到客户端写入的依据；新版 Cline 与 Roo Code 的用量存在别处，很可能一条都读不到。', 'affects'],
    ['模型可能只在 ui_messages.json 里', '模型名有时只写在另一个文件里，已经一起读。', 'handled']
  ],
  gemini: [
    ['输入含缓存，已扣', '输入里包含缓存的部分，已经拆开。', 'handled'],
    ['目录下混有非用量 JSON', '日志目录里混着别的文件，会自动跳过。', 'handled'],
    ['会话 id 与条目 id 的语义未确认', '会话的划分方式还没完全确认，会话数可能偏多或偏少。', 'affects']
  ],
  cursor: [
    ['CSV 头部分列', '导出的表格表头格式不固定，已经兼容。', 'handled'],
    ['SQLite 是内部结构，版本变化风险高', '读的是 Cursor 自己的内部数据库，Cursor 升级后可能暂时读不到。', 'affects']
  ],
  opencode: [
    ['输出已并入 reasoning', '模型「思考」用的 token 算进了输出。', 'handled'],
    ['v1 / v2 表结构不同', '新旧两种版本的日志都能读。', 'handled']
  ],
  kilo: [
    ['旧版 JSON 任务目录未接入', '只读取新版数据库，旧版扩展的 JSON 任务记录暂未接入。', 'affects'],
    ['只计 session_message，输出并入 reasoning', '逐次消息只算一份，模型「思考」用的 token 算进输出。', 'handled'],
    ['开发 channel 数据库需显式 KILO_DB', '默认只发现 kilo.db，其他开发版本数据库需指定路径。', 'affects']
  ],
  openhands: [
    ['SDK 自定义脚本、ACP 与服务端／容器／远程 runtime 未接入', '仅支持 OpenHands CLI 原生会话，其他运行方式暂未接入。', 'affects'],
    ['时间取相同 response_id 的最早事件；无时区时间按采集机本地时区解释', '按响应事件时间归属日期；从其他时区搬来的日志可能归错日期。', 'affects'],
    ['只计能在本会话事件里关联到的逐次用量；子会话从自己的记录读取，父副本不计', 'task、delegate 和 agent hook 的用量算在各自的子会话里，父会话中的副本不会重复算。', 'handled'],
    ['未关联的 task:、delegate:、agent-hook: 条目计 subagent_copies，其余计 bad_times', '无法关联事件时间的用量不计入；已知子会话副本单独计数。', 'affects'],
    ['只计 token_usages；prompt 扣缓存读写，completion 不再加 reasoning', '逐次记录只算一次，缓存和模型思考不会重复计算。', 'handled']
  ],
  goose: [
    ['累计型：只报累计总量', '只记录每个会话的总数，看不到每次请求。', 'affects'],
    ['accumulated_* 与 *_tokens 两套字段', '日志里有两套用量字段，只取其中一套，不会重复算。', 'handled'],
    ['total 超出 input + output 的余量不入账', '日志里总数大于输入加输出的那部分含义不明，没有计入。', 'affects']
  ],
  zed: [
    ['累计型：按 thread 覆盖', '只记录每个对话的总数，看不到每次请求。', 'affects'],
    ['payload 可能是 zstd BLOB', '压缩存储的对话也能读。', 'handled'],
    ['imported 线程未单独识别', '从别处导入的对话没有单独识别，和原对话同时存在时可能重复计。', 'affects'],
    ['输入是否含缓存未确认，未扣减', '输入里是否包含缓存还没确认，暂未拆开；如果包含，缓存部分会按输入再算一次。', 'affects']
  ],
  continue: [
    ['单文件多轮，逐轮取用量', '一个文件里有多轮对话，逐轮读取。', 'handled'],
    ['输入是否含缓存未确认，未扣减', '输入里是否包含缓存还没确认，暂未拆开；如果包含，缓存部分会按输入再算一次。', 'affects']
  ],
  trae: [['JSONL 行里 id 的语义未确认，保留原有回退', '记录编号的含义还没完全确认，个别记录可能被合并或拆开。', 'affects']],
  copilot: [
    ['输出已并入 reasoning', '模型「思考」用的 token 算进了输出。', 'handled'],
    ['同一会话优先明细，汇总库仅补充无明细的会话', '同一会话有逐次用量时只取逐次用量；其余会话取总数。', 'handled']
  ],
  openclaw: [['归档与活跃日志中内容身份相同的事件只计一次', '同一份消息副本只计一次；时间、编号和正文都相同的消息无法进一步区分。', 'affects']],
  mimo: [
    ['删会话会级联删除消息，账本保留已采集用量', 'MiMo Code 删除会话后，已经采集的用量仍计入总数。', 'handled'],
    ['显式启用 channel 库时，同目录备份库可能共享消息 id', '只有设置 MIMOCODE_DISABLE_CHANNEL_DB=false/0 才读取 mimocode-*.db；同目录备份库可能与正式库共享消息 id，用量不同时可能采用较旧的一份。', 'affects'],
    ['MiMo Desktop 路径来自第三方，未核实', '桌面版的日志位置尚未由官方源码或真实样本确认，可能读不到。', 'affects']
  ],
  kimi: [
    ['目录层级不统一', '不同版本的日志目录层级不一样，都会去找。', 'handled'],
    ['wire 只计 usage.record，subagent.completed 的汇总不另计', '子任务的用量只按它自己的记录算一次，不会和主任务里的汇总重复。', 'handled']
  ],
  minimax: [['rewind 与删会话会删除用量行，账本保留已采集用量', 'MiniMax Code 回退对话或删除会话后，已经采集的用量仍计入总数。', 'handled']],
  codebuddy: [
    ['路径与格式来自第三方逆向解析器', '按第三方解析器读取 CLI 的 projects 和桌面版会话索引，待真实样本核实。', 'affects'],
    ['输入含缓存读，已扣；prompt_cache_miss_tokens 为未缓存输入', '缓存读取已拆开，未命中缓存的输入不会当作缓存写入。', 'handled'],
    ['CLI 无已验证消息 ID，身份依赖文件路径与物理行号', 'CLI 日志移动或重排后可能重复计数；桌面请求有 ID 时按请求去重。', 'affects']
  ],
  commandcode: [
    ['只读 command-code 1.88.2 的 v3 transcript，不读伴生文件', '仅接入带逐条用量的 v3 会话格式，旧版格式尚未接入。', 'affects'],
    ['输入含缓存读写，均已扣除', '输入与缓存分开计算，同一条请求重复采集不会增加用量。', 'handled']
  ],
  anythingllm: [
    ['prompt/completion 可能是估算值，也可能被 provider 返回值覆盖', '客户端可能用本地估算的 token 数；无法逐条区分估算与实际返回值。', 'affects'],
    ['缓存无可靠细分，缓存读写存 NULL', '日志未提供统一的缓存拆分，缓存部分无法独立计价。', 'affects'],
    ['include=false 仍计入；删 workspace 后保留已采集用量', '隐藏或删除聊天记录不会撤销已经发生并采集的用量。', 'handled'],
    ['STORAGE_DIR 不覆盖 Prisma SQLite URL，仅自动发现本机桌面库', '服务端数据库和容器内的数据库不在自动发现范围内。', 'affects']
  ],
  zcode: [
    ['客户端只保留 30 天用量', '首次采集时，只能读到 ZCode 最近 30 天仍保留的用量。', 'affects'],
    ['多库同一请求 id 的用量不同时可能采到旧值', '默认库与自定义或迁移后的库并存且请求 id 相同时，账本按副本规则只采一份；若在请求进行中复制库，导致同一 id 的 token 不同，可能采到较旧的一份。上游 model_usage 行在请求完成时写定，正常使用中两份库对同一 id 的值一致。', 'affects'],
    ['剪枝不撤销已采集用量', 'ZCode 清理旧记录后，已经采集的用量仍计入总数。', 'handled']
  ]
};

/**
 * 每个来源的记录里，出处日志仍在磁盘上的条数。每个文件只查一次。
 *
 * @param {Array<{ source: string, source_file: string|null, records: number }>} files
 * @param {(path: string) => boolean} exists
 * @returns {Map<string, number>}
 */
function reviewableBySource(files, exists) {
  const counts = new Map();
  for (const f of files) {
    const kept = f.source_file !== null && exists(f.source_file);
    counts.set(f.source, (counts.get(f.source) || 0) + (kept ? f.records : 0));
  }
  return counts;
}

/**
 * @param {import('../../db/read.js').LedgerQueries} queries
 * @param {{ now?: Date, exists?: (path: string) => boolean }} [options] 测试用：固定当前时刻、替换文件存在判断
 * @returns {Object}
 */
export function buildSources(queries, { now = new Date(), exists = existsSync } = {}) {
  const rows = queries.sourceStatus();
  const checks = queries.sourceChecks({ now: now.toISOString() });
  const reviewable = reviewableBySource(queries.sourceFiles(), exists);
  const known = new Set(Object.keys(EVIDENCE));
  const sources = rows.map((r) => {
    const limits = SOURCE_LIMITS[r.source] || [];
    const kept = reviewable.get(r.source) || 0;
    return {
      source: r.source,
      evidence: EVIDENCE[r.source] || 'B',
      status: r.records > 0 ? 'ok' : 'no_data',
      first_observed_at: r.first_observed_at,
      last_observed_at: r.last_observed_at,
      records: r.records,
      // 从账本里实际存的记录类型得出，不另外维护一份「哪些工具是累计型」的清单
      record_mode: r.cumulative_records === 0 ? 'event' : r.cumulative_records === r.records ? 'cumulative' : 'mixed',
      // 日志已删的记录照常计入总数，只是不能再对照原始日志复核
      retention: { reviewable: kept, logs_gone: r.records - kept },
      checks: checks.get(r.source),
      limits: limits.map(([raw]) => raw),
      notes: limits.map(([, text, impact]) => ({ text, impact }))
    };
  });

  // 未在本机出现过的来源也要列出来，避免「看不到就是没有」
  const run = queries.lastRun();
  return {
    sources,
    last_run: run
      ? {
          status: run.status,
          started_at: run.started_at ? new Date(run.started_at * 1000).toISOString() : null,
          finished_at: run.finished_at ? new Date(run.finished_at * 1000).toISOString() : null,
          attempted: run.attempted,
          inserted: run.inserted,
          updated: run.updated,
          unchanged: run.unchanged,
          rejected: run.rejected,
          counts: run.counts,
          anomaly_count: run.anomalies.length,
          anomalies: run.anomalies.slice(0, 5)
        }
      : null,
    snapshot: snapshotMeta({}, { known_sources: known.size })
  };
}

/** 引导页扫盘的缓存时长。新装的工具最多延迟这么久才出现在发现列表里。 */
const DISCOVERY_TTL_MS = 60_000;

/**
 * @param {() => {[source: string]: string[]}} discover
 * @returns {{ sources: Array<{source: string, files: number}>, supported: number }}
 */
function computeDiscovery(discover) {
  const found = discover();
  const sources = Object.entries(found)
    .map(([source, files]) => ({ source, files: files.length }))
    .filter((item) => item.files > 0)
    .sort((a, b) => b.files - a.files);
  return { sources, supported: Object.keys(adapters).length };
}

/**
 * 每个服务实例独立缓存发现结果，对外只返回文件数量。
 * @param {() => Object<string, string[]>} [discover]
 * @returns {(options?: { fresh?: boolean }) => Object}
 */
export function createDiscoveryService(discover = discoverAll) {
  let cache = null;
  return function buildDiscovery(options = {}) {
    const now = Date.now();
    if (!options.fresh && cache && now - cache.at < DISCOVERY_TTL_MS) {
      return cache.value;
    }
    const value = computeDiscovery(discover);
    cache = { at: now, value };
    return value;
  };
}
