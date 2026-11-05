#!/usr/bin/env node

import { resolveDataDir } from './paths.js';

const USAGE = 'Usage: lens [collect|summary|reprice|serve] [--data-dir <dir>] [--port <port>] [--strict-port] [--desktop-logs] [--exit-on-stdin-end] [--help|-h]';

/**
 * 解析命令行参数。
 *
 * @param {string[]} argv
 * @returns {{ command: string, dataDir: string|null, port: number|null, strictPort: boolean, desktopLogs: boolean, exitOnStdinEnd: boolean }}
 */
function parseArgs(argv) {
  let dataDir = null;
  let port = null;
  let command = null;
  let strictPort = false;
  let desktopLogs = false;
  let exitOnStdinEnd = false;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--data-dir' || arg.startsWith('--data-dir=') || arg === '--port' || arg.startsWith('--port=')) {
      const name = arg.startsWith('--data-dir') ? '--data-dir' : '--port';
      const inline = arg.startsWith(`${name}=`);
      const value = inline ? arg.slice(name.length + 1) : argv[++i];
      if (value === undefined || value === '' || (!inline && value.startsWith('-'))) {
        throw new Error(`${name} requires a non-empty value`);
      }
      if (name === '--data-dir') {
        dataDir = value;
      } else {
        if (!/^\d+$/.test(value) || Number(value) < 1 || Number(value) > 65535) {
          throw new Error('--port must be an integer from 1 to 65535');
        }
        port = Number(value);
      }
    } else if (arg === '--strict-port') {
      strictPort = true;
    } else if (arg === '--desktop-logs') {
      desktopLogs = true;
    } else if (arg === '--exit-on-stdin-end') {
      exitOnStdinEnd = true;
    } else if (arg.startsWith('-')) {
      throw new Error(`Unknown option: ${arg}`);
    } else if (command === null) {
      command = arg;
    } else {
      throw new Error(`Unexpected argument: ${arg}`);
    }
  }

  if (command !== null && !['collect', 'summary', 'reprice', 'serve'].includes(command)) {
    throw new Error(`Unknown command: ${command}`);
  }
  return { command: command ?? 'collect', dataDir, port, strictPort, desktopLogs, exitOnStdinEnd };
}

function formatNumber(n) {
  return Number(n || 0).toLocaleString('en-US');
}

function formatCost(usd) {
  return `$${Number(usd || 0).toFixed(4)}`;
}

async function handleCollect() {
  const { runIngestion, isSyncBusyError } = await import('./ingest.js');
  console.log('🔍 Discovering AI tool logs and running collection...');
  let result;
  try {
    result = await runIngestion({ verbose: true });
  } catch (err) {
    if (isSyncBusyError(err)) {
      console.error('❌ 采集冲突：已有同步或采集任务在执行中，本次采集已中止。');
      process.exit(1);
    }
    throw err;
  }

  console.log(`\n✅ Collection Complete (${(result.durationMs / 1000).toFixed(2)}s)`);
  console.log(`   Scanned files   : ${result.fileCount}`);
  console.log(`   Parsed records  : ${formatNumber(result.attempted)}`);
  console.log(`   New records     : ${formatNumber(result.inserted)}`);

  await handleSummary();
}

async function handleSummary() {
  const { Ledger } = await import('./db/ledger.js');
  const { formatMicros } = await import('./pricing/engine.js');
  const ledger = new Ledger(resolveDataDir().ledgerPath);
  const totals = ledger.read.totals();
  const sources = ledger.read.sourceStatus();
  ledger.close();

  console.log('\n📊 Token Lens Usage Summary');
  console.log('─'.repeat(70));
  console.log(
    `Records: ${formatNumber(totals.record_count)} | ` +
    `Gross: ${formatNumber(totals.gross_tokens)} | ` +
    `Cost: $${formatMicros(totals.cost_micros ?? 0, 4)}`
  );
  console.log('─'.repeat(70));

  if (sources.length === 0) {
    console.log('No usage records stored yet.');
    return;
  }

  console.log('Source     | Records   | Last observed');
  console.log('───────────┼───────────┼─────────────────────────');
  for (const s of sources) {
    console.log(`${s.source.padEnd(10, ' ')} | ${formatNumber(s.records).padStart(9, ' ')} | ${s.last_observed_at}`);
  }
}

async function handleReprice() {
  const { Ledger } = await import('./db/ledger.js');
  const { costOf, PRICE_VERSION } = await import('./pricing/engine.js');
  const ledger = new Ledger(resolveDataDir().ledgerPath);
  const changed = ledger.write.reprice(costOf, PRICE_VERSION);
  ledger.close();
  console.log(`已按价格版本 ${PRICE_VERSION} 重算 ${changed} 条记录的金额`);
}

// 启动补采在监听之后跑：页面先用已有数据打开，界面按 last_run 的 running 状态显示「正在同步」。
// 撞上别的采集只跳过这一次，不退出服务。
async function collectAfterStart() {
  const { runIngestion, isSyncBusyError } = await import('./ingest.js');
  try {
    const result = await runIngestion({ dataDir: resolveDataDir().dataDir });
    console.log(`[启动同步] 完成：新增 ${formatNumber(result.inserted)} 条（${(result.durationMs / 1000).toFixed(2)}s）`);
  } catch (err) {
    if (isSyncBusyError(err)) {
      console.log('[启动同步] 跳过：已有同步或采集任务在执行中');
      return;
    }
    console.error('[启动同步] 失败', err.message);
  }
}

async function handleServe(port, strictPort, exitOnStdinEnd) {
  // 首次启动（账本为空）不自动采集：先让引导页做发现，由用户点「开始统计」入库；
  // 已有数据的账本在启动后补上新的用量。
  const { Ledger } = await import('./db/ledger.js');
  const ledger = new Ledger(resolveDataDir().ledgerPath);
  let hasRecords = false;
  try {
    hasRecords = ledger.read.totals({}).record_count > 0;
  } finally {
    ledger.close();
  }

  const { startServer } = await import('./server.js');
  const service = await startServer(port ?? undefined, { strictPort });
  console.log(`TOKEN_LENS_READY ${JSON.stringify({ port: service.port, data_dir: resolveDataDir().dataDir, pid: process.pid })}`);
  if (exitOnStdinEnd) {
    // macOS 壳一直持有 stdin 写端；壳不论怎样退出，管道都会关闭，内核随之退出（对应 Windows 的 Job Object）。
    process.stdin.on('end', () => process.exit(0));
    process.stdin.resume();
  }
  if (hasRecords) collectAfterStart();
}

async function main() {
  const argv = process.argv.slice(2);
  if (argv.includes('--help') || argv.includes('-h')) {
    console.log(USAGE);
    return;
  }
  let options;
  try {
    options = parseArgs(argv);
  } catch (err) {
    console.error(`Argument error: ${err.message}`);
    console.error(USAGE);
    process.exitCode = 2;
    return;
  }
  const { command, dataDir, port, strictPort, desktopLogs, exitOnStdinEnd } = options;

  // 数据目录只有一个权威来源：把命令行参数落成环境变量，后续模块统一走 paths.js。
  if (dataDir) {
    process.env.TOKEN_LENS_DATA_DIR = dataDir;
  }

  // 只做解析，不做落盘；真正的 mkdir 在需要开库时发生。
  const paths = resolveDataDir();
  if (command === 'serve' && desktopLogs) {
    const { enableDesktopLogs } = await import('./desktop-logs.js');
    enableDesktopLogs(paths.dataDir);
  }
  console.log(`📁 数据目录: ${paths.dataDir} (来源: ${paths.source})`);

  if (command === 'collect') {
    await handleCollect();
  } else if (command === 'summary') {
    await handleSummary();
  } else if (command === 'reprice') {
    await handleReprice();
  } else if (command === 'serve') {
    await handleServe(port, strictPort, exitOnStdinEnd);
  }
}

main().catch((err) => {
  console.error('Execution error:', err);
  process.exit(1);
});

