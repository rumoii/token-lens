// macOS 桌面冒烟：只读挂载 dmg，用临时 HOME 与数据目录启动壳，检查就绪、单实例、退出与强杀后内核不残留、端口被占时显示失败而不挂起。
// 用法：node desktop/smoke-macos.mjs <dmg>。需要图形会话：GitHub 的 macOS runner 自带；远程机器在已登录用户的会话里用 launchctl asuser 运行。
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import net from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

const image = process.argv[2];
if (process.platform !== 'darwin' || !image || !existsSync(image)) throw new Error('Usage on macOS: node desktop/smoke-macos.mjs <dmg>');
const PORT = 3456;
const root = mkdtempSync(join(tmpdir(), 'token-lens-smoke-'));
const mount = join(root, 'volume');
const data = join(root, 'data');
const env = { ...process.env, HOME: join(root, 'home'), TOKEN_LENS_DATA_DIR: data };
delete env.DB_PATH;
mkdirSync(env.HOME);

const alive = pid => {
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; }
};
const children = pid => spawnSync('pgrep', ['-P', String(pid)], { encoding: 'utf8' }).stdout.split('\n').filter(Boolean).map(Number);
const listening = () => new Promise(resolve => {
  const socket = net.connect(PORT, '127.0.0.1');
  socket.once('connect', () => { socket.destroy(); resolve(true); });
  socket.once('error', () => resolve(false));
});
async function ready() {
  try {
    const response = await fetch(`http://127.0.0.1:${PORT}/`);
    return response.status === 200 && (await response.text()).includes('lens-api-token');
  } catch { return false; }
}
async function waitFor(check, ms, label) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (await check()) return;
    await sleep(200);
  }
  throw new Error(`Timed out after ${ms}ms: ${label}`);
}
const shells = [];
const kernels = [];
function launch() {
  const shell = spawn(join(mount, 'Token Lens.app/Contents/MacOS/token-lens'), [], { env, stdio: 'ignore' });
  shells.push(shell);
  return shell;
}
const exited = shell => shell.exitCode !== null || shell.signalCode !== null;
async function started(shell) {
  await waitFor(ready, 60_000, 'kernel serves index.html');
  const found = children(shell.pid);
  kernels.push(...found);
  if (found.length !== 1) throw new Error(`Expected one kernel child, found ${found.length}`);
  const args = execFileSync('ps', ['-o', 'args=', '-p', String(found[0])], { encoding: 'utf8' });
  if (!args.includes('--exit-on-stdin-end') || !args.includes(data)) throw new Error(`Unexpected kernel command: ${args}`);
  return found[0];
}
async function gone(kernel, label) {
  await waitFor(() => !alive(kernel), 5_000, `${label}: kernel exits`);
  await waitFor(async () => !(await listening()), 5_000, `${label}: port ${PORT} released`);
  console.log(`ok ${label}: kernel gone, port released`);
}

let detached = false;
try {
  if (await listening()) throw new Error(`Port ${PORT} is already in use; stop other Token Lens instances first.`);
  execFileSync('hdiutil', ['attach', '-nobrowse', '-readonly', '-noautoopen', '-mountpoint', mount, image], { stdio: 'ignore' });

  const first = launch();
  let kernel = await started(first);
  console.log('ok start: one kernel serves the dashboard');

  const second = launch();
  await waitFor(() => exited(second), 10_000, 'second instance exits');
  if (second.exitCode !== 0) throw new Error(`Second instance exited ${second.exitCode ?? second.signalCode}`);
  if (children(first.pid).join() !== String(kernel)) throw new Error('Second instance touched the kernel');
  console.log('ok single instance: second launch exits, kernel unchanged');

  first.kill('SIGKILL');
  await gone(kernel, 'shell killed');

  // ⌘Q 与菜单「退出」走 NSApplication terminate:，壳在 LoopDestroyed 里释放内核守卫。
  const third = launch();
  kernel = await started(third);
  execFileSync('osascript', ['-l', 'JavaScript', '-e', `ObjC.import('AppKit'); $.NSRunningApplication.runningApplicationWithProcessIdentifier(${third.pid}).terminate`], { stdio: 'ignore' });
  await waitFor(() => exited(third), 10_000, 'shell quits');
  await gone(kernel, 'quit');

  const blocker = net.createServer();
  await new Promise((resolve, reject) => blocker.once('error', reject).listen(PORT, '127.0.0.1', resolve));
  try {
    const fourth = launch();
    const log = join(data, 'logs', 'kernel.log');
    await waitFor(() => existsSync(log) && readFileSync(log, 'utf8').includes(`端口 ${PORT} 已被占用`), 30_000, 'kernel reports the occupied port');
    await waitFor(() => children(fourth.pid).length === 0, 5_000, 'failed kernel exits');
    await sleep(1_000);
    if (exited(fourth)) throw new Error('Shell exited instead of showing the failure page');
    console.log('ok port occupied: kernel exits, shell stays open on the failure page');
    fourth.kill('SIGKILL');
  } finally { blocker.close(); }
} finally {
  for (const shell of shells) if (!exited(shell)) shell.kill('SIGKILL');
  for (const kernel of kernels) if (alive(kernel)) process.kill(kernel, 'SIGKILL');
  detached = spawnSync('hdiutil', ['detach', mount, '-force'], { stdio: 'ignore' }).status === 0 || !existsSync(join(mount, 'Token Lens.app'));
  // 只删本次 mkdtemp 建的目录；卷没卸下时保留，避免递归进挂载点。
  if (detached) rmSync(root, { recursive: true, force: true });
  else console.error(`Volume still mounted; left ${root} in place.`);
}
