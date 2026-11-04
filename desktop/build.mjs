import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { closeSync, existsSync, lstatSync, mkdirSync, openSync, readFileSync, readdirSync, statSync, writeSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { packageMac } from './macos.mjs';
import { assembleExe } from './package.mjs';

const desktop = dirname(fileURLToPath(import.meta.url));
const root = resolve(desktop, '..');
const dist = process.env.TOKEN_LENS_DIST_DIR;
if (!dist || !existsSync(join(dist, 'index.html'))) throw new Error('Set TOKEN_LENS_DIST_DIR to an existing dashboard/dist with index.html.');
const mac = process.platform === 'darwin';
const exe = mac ? '' : '.exe';
const node = process.env.TOKEN_LENS_NODE_EXE || `node${exe}`;
const versionCheck = spawnSync(node, ['--version'], { encoding: 'utf8', windowsHide: true });
if (versionCheck.error || versionCheck.status !== 0 || !/^v24\./.test(versionCheck.stdout.trim())) throw new Error(`TOKEN_LENS_NODE_EXE (or PATH node${exe}) must be official Node v24.`);
// process.execPath comes from the selected Node, including the PATH case.
const nodePath = spawnSync(node, ['-p', 'process.execPath'], { encoding: 'utf8', windowsHide: true });
if (nodePath.error || nodePath.status !== 0) throw new Error(`Cannot resolve node${exe}.`);
const version = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')).version;
if (!/^[\da-zA-Z.-]+$/.test(version)) throw new Error('Invalid package version.');
function run(command, args) {
  const child = spawnSync(command, args, { cwd: desktop, stdio: 'inherit', windowsHide: true });
  if (child.error) throw child.error;
  if (child.status !== 0) throw new Error(`${command} exited ${child.status}`);
}
run('cargo', ['build', '--release', '--offline', '--locked']);
const metadata = spawnSync('cargo', ['metadata', '--no-deps', '--format-version', '1', '--offline', '--locked'], { cwd: desktop, encoding: 'utf8', windowsHide: true });
if (metadata.error || metadata.status !== 0) throw new Error('Cannot resolve Cargo target directory.');
const targetRoot = JSON.parse(metadata.stdout).target_directory;
const target = join(targetRoot, 'release');
const files = [];
function add(path, name, group) {
  const info = lstatSync(path);
  if (info.isSymbolicLink()) throw new Error(`Refusing linked input: ${path}`);
  if (info.isDirectory()) {
    for (const entry of readdirSync(path).sort()) add(join(path, entry), `${name}/${entry}`, group);
  } else if (info.isFile()) {
    files.push({ path, name, group, size: info.size });
  } else throw new Error(`Not a regular file: ${path}`);
}
add(join(target, `token-lens${exe}`), `token-lens${exe}`, 'shell');
add(nodePath.stdout.trim(), `node${exe}`, 'node');
add(join(root, 'src/core'), 'src/core', 'core');
add(join(root, 'bin'), 'bin', 'core');
add(resolve(dist), 'dashboard/dist', 'dashboard');
add(join(root, 'package.json'), 'package.json', 'metadata');
add(join(root, 'LICENSE'), 'LICENSE', 'metadata');
// 官方 tarball 是 bin/node 加上一级的 LICENSE；Windows zip 两者同级。
const nodeLicense = join(dirname(nodePath.stdout.trim()), mac ? '../LICENSE' : 'LICENSE');
if (existsSync(nodeLicense)) add(nodeLicense, 'NODE-LICENSE', 'metadata');
if (mac) {
  packageMac({ root, desktop, staging: join(targetRoot, 'bundle', 'macos'), files, version, node, nodePath: nodePath.stdout.trim(), nodeVersion: versionCheck.stdout.trim() });
} else {
  const directory = join(targetRoot, 'bundle');
  mkdirSync(directory, { recursive: true });
  const archive = join(directory, 'payload.bin');
  const fd = openSync(archive, 'w');
  try {
    writeSync(fd, Buffer.from('TLPL0001'));
    const count = Buffer.alloc(4); count.writeUInt32LE(files.length); writeSync(fd, count);
    for (const file of files) {
      const name = Buffer.from(file.name);
      const header = Buffer.alloc(12);
      header.writeUInt32LE(name.length);
      header.writeBigUInt64LE(BigInt(file.size), 4);
      writeSync(fd, header); writeSync(fd, name); writeSync(fd, readFileSync(file.path));
    }
  } finally { closeSync(fd); }
  const compressedFile = join(directory, 'payload.lzma');
  console.log(`Compressing ${statSync(archive).size} bytes with pure Rust LZMA (64MiB dictionary, nice_len 273)…`);
  run(join(target, 'pack.exe'), [archive, compressedFile]);
  const compressed = readFileSync(compressedFile);
  const sha256 = createHash('sha256').update(compressed).digest('hex');
  const manifest = { version: `${version}-${sha256.slice(0, 12)}`, sha256, compressed_size: compressed.length, unpacked_size: statSync(archive).size };
  const shell = readFileSync(join(target, 'token-lens.exe'));
  const sizes = {};
  for (const file of files) sizes[file.group] = (sizes[file.group] || 0) + file.size;
  const executable = assembleExe(shell, compressed, manifest);
  console.log(JSON.stringify({ node_version: versionCheck.stdout.trim(), input_bytes: sizes, archive_bytes: manifest.unpacked_size, compressed_bytes: compressed.length, shell_bytes: shell.length, manifest_and_footer_bytes: executable.length - shell.length - compressed.length, exe_bytes: executable.length, limit_bytes: 30_000_000, manifest }, null, 2));
  mkdirSync(join(desktop, 'dist'), { recursive: true });
  const output = join(desktop, 'dist', `token-lens-${manifest.version}.exe`);
  const out = openSync(output, 'w');
  try { writeSync(out, executable); }
  finally { closeSync(out); }
  console.log(`Built ${output}`);
}
