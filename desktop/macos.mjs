// macOS 打包：组装 Token Lens.app、ad-hoc 签名、打成 dmg。只用系统自带的 otool、sips、iconutil、codesign、hdiutil。
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, copyFileSync, mkdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

export const BUNDLE_ID = 'io.github.rumoii.token-lens';
// 同一输入实测在 30,302,613 与 32,131,379 字节间跳（Node v24.22.1，hdiutil 输出不固定），按较大值上浮约 15%；与 specs/desktop.md 一致。
export const DMG_LIMIT_BYTES = 37_000_000;
// 官方 Node v24 的 LC_BUILD_VERSION minos 是 13.5，再低的系统起不来内核。
const MIN_MACOS = '13.5';

function run(command, args) {
  const child = spawnSync(command, args, { stdio: 'inherit' });
  if (child.error) throw child.error;
  if (child.status !== 0) throw new Error(`${command} exited ${child.status}`);
}

function capture(command, args) {
  const child = spawnSync(command, args, { encoding: 'utf8' });
  if (child.error || child.status !== 0) throw new Error(`${command} failed: ${child.error?.message ?? child.stderr}`);
  return child.stdout;
}

// Homebrew 等构建会链接 /opt/homebrew 下的动态库，拷进 .app 后在别的机器上起不来。
function checkNode(node, nodePath) {
  const arch = capture(node, ['-p', 'process.arch']).trim();
  if (arch !== 'arm64') throw new Error(`Node must be darwin-arm64, got ${arch}.`);
  const libraries = capture('otool', ['-L', nodePath]).split('\n').slice(1).map(line => line.trim().split(' ')[0]).filter(Boolean);
  const foreign = libraries.filter(library => !library.startsWith('/usr/lib/') && !library.startsWith('/System/'));
  if (foreign.length) throw new Error(`Node links non-system libraries (use the official nodejs.org build): ${foreign.join(', ')}`);
}

function infoPlist(version) {
  const entries = {
    CFBundleDevelopmentRegion: 'zh_CN',
    CFBundleDisplayName: 'Token Lens',
    CFBundleExecutable: 'token-lens',
    CFBundleIconFile: 'AppIcon',
    CFBundleIdentifier: BUNDLE_ID,
    CFBundleInfoDictionaryVersion: '6.0',
    CFBundleName: 'Token Lens',
    CFBundlePackageType: 'APPL',
    CFBundleShortVersionString: version,
    CFBundleVersion: version,
    LSApplicationCategoryType: 'public.app-category.developer-tools',
    LSMinimumSystemVersion: MIN_MACOS,
  };
  const body = Object.entries(entries).map(([key, value]) => `  <key>${key}</key>\n  <string>${value}</string>`).join('\n');
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
${body}
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
`;
}

function buildIcon(source, iconset, output) {
  mkdirSync(iconset);
  for (const size of [16, 32, 128, 256, 512]) {
    for (const scale of [1, 2]) {
      const px = size * scale;
      if (px > 512) continue;
      const name = scale === 1 ? `icon_${size}x${size}.png` : `icon_${size}x${size}@2x.png`;
      capture('sips', ['-z', String(px), String(px), source, '--out', join(iconset, name)]);
    }
  }
  run('iconutil', ['-c', 'icns', iconset, '-o', output]);
}

export function packageMac({ root, desktop, staging, files, version, node, nodePath, nodeVersion }) {
  checkNode(node, nodePath);
  // staging 是 Cargo 目标目录下本脚本专用的生成目录，每次整体重建。
  rmSync(staging, { recursive: true, force: true });
  const volume = join(staging, 'volume');
  const app = join(volume, 'Token Lens.app');
  const contents = join(app, 'Contents');
  const hash = createHash('sha256');
  for (const file of files) {
    const executable = file.group === 'shell' || file.group === 'node';
    const target = executable ? join(contents, 'MacOS', file.name) : join(contents, 'Resources/app', file.name);
    mkdirSync(join(target, '..'), { recursive: true });
    copyFileSync(file.path, target);
    chmodSync(target, executable ? 0o755 : 0o644);
    hash.update(`${file.name}\0${file.size}\0`).update(readFileSync(file.path));
  }
  const identity = `${version}-${hash.digest('hex').slice(0, 12)}`;
  writeFileSync(join(contents, 'Info.plist'), infoPlist(version));
  buildIcon(join(root, 'dashboard/public/icon-512.png'), join(staging, 'AppIcon.iconset'), join(contents, 'Resources/AppIcon.icns'));
  // 不加 --deep：node 保留官方签名与 JIT entitlements，只对壳和包本身做 ad-hoc 签名。
  run('codesign', ['--force', '--sign', '-', '--identifier', BUNDLE_ID, app]);
  run('codesign', ['--verify', '--strict', '--verbose=2', app]);
  run('codesign', ['--verify', '--strict', join(contents, 'MacOS/node')]);
  symlinkSync('/Applications', join(volume, 'Applications'));
  const image = join(staging, 'token-lens.dmg');
  run('hdiutil', ['create', '-volname', 'Token Lens', '-srcfolder', volume, '-format', 'ULMO', '-ov', image]);
  const size = statSync(image).size;
  const sizes = {};
  for (const file of files) sizes[file.group] = (sizes[file.group] || 0) + file.size;
  console.log(JSON.stringify({ node_version: nodeVersion, input_bytes: sizes, dmg_bytes: size, limit_bytes: DMG_LIMIT_BYTES, version: identity }, null, 2));
  if (size > DMG_LIMIT_BYTES) throw new Error(`Desktop dmg exceeds ${DMG_LIMIT_BYTES} bytes: ${size}`);
  mkdirSync(join(desktop, 'dist'), { recursive: true });
  const output = join(desktop, 'dist', `token-lens-${identity}-macos-arm64.dmg`);
  copyFileSync(image, output);
  console.log(`Built ${output}`);
}
