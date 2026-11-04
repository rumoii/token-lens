#!/usr/bin/env node
/**
 * 生成 dashboard/public 下的图标：陶土底圆角磁贴，里面是 lib/brand-mark.js 的镜片标记。
 *
 * 形状只在 brand-mark.js 里定义；这里决定底色、圆角和每个文件的尺寸。
 * PNG 用 dashboard 已有的 Playwright 渲染，favicon.ico 由这些 PNG 打包（PNG 内嵌的 ICO）。
 *
 * 用法：
 *   node scripts/icons/build-icons.mjs
 * 浏览器默认用 Playwright 自带的 Chromium，没有下载过时改用本机 Edge：
 *   LENS_ICON_BROWSER=msedge node scripts/icons/build-icons.mjs
 */

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { writeFileSync } from 'node:fs';

import { isStroked, MARK_SMALL_MAX, markShapes } from '../../dashboard/src/lib/brand-mark.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const publicDir = join(root, 'dashboard', 'public');

/* 和 tokens.css 的 --lens-clay 一致；图标在页面之外显示，用不了 CSS 变量 */
const CLAY = '#d97757';
/* 半透明写成 opacity 属性，不用 rgb(… / a)：系统缩略图之类的旧 SVG 解析器不认后者 */
const COLORS = { ring: ['#ffffff', 1], glint: ['#ffffff', 0.62], bar: ['#ffffff', 0.62], accent: ['#ffffff', 1] };
const RADIUS = 0.24;
/* 磁贴里的标记缩到 90%，给圆角留边 */
const INSET = 0.9;

const kebab = (key) => key.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);

/** square：iOS 自己会裁圆角，主屏图标要满铺的方块。 */
function tileSvg(px, { square = false } = {}) {
  const shapes = markShapes({ small: px <= MARK_SMALL_MAX })
    .map(({ type, role, attrs }) => {
      const [color, alpha] = COLORS[role];
      const kind = isStroked(role) ? 'stroke' : 'fill';
      const paint = `${kind}="${color}"` + (alpha < 1 ? ` ${kind}-opacity="${alpha}"` : '');
      const rest = Object.entries(attrs).map(([k, v]) => `${kebab(k)}="${v}"`).join(' ');
      return `<${type} ${rest} ${paint}/>`;
    })
    .join('');
  const rx = square ? 0 : +(32 * RADIUS).toFixed(2);
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" width="${px}" height="${px}">` +
    `<rect width="32" height="32" rx="${rx}" fill="${CLAY}"/>` +
    `<g transform="translate(16 16) scale(${INSET}) translate(-16 -16)">${shapes}</g></svg>`
  );
}

/** PNG 内嵌的 ICO：6 字节文件头，每张图 16 字节目录项，后面直接接 PNG。 */
function packIco(pngs) {
  const header = Buffer.alloc(6 + 16 * pngs.length);
  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(pngs.length, 4);
  let offset = header.length;
  pngs.forEach(({ px, data }, i) => {
    const at = 6 + 16 * i;
    header.writeUInt8(px >= 256 ? 0 : px, at);
    header.writeUInt8(px >= 256 ? 0 : px, at + 1);
    header.writeUInt16LE(1, at + 4);
    header.writeUInt16LE(32, at + 6);
    header.writeUInt32LE(data.length, at + 8);
    header.writeUInt32LE(offset, at + 12);
    offset += data.length;
  });
  return Buffer.concat([header, ...pngs.map((p) => p.data)]);
}

const require = createRequire(join(root, 'dashboard', 'package.json'));
const { chromium } = require('playwright');
const browser = await chromium.launch(process.env.LENS_ICON_BROWSER ? { channel: process.env.LENS_ICON_BROWSER } : {});
const page = await browser.newPage({ deviceScaleFactor: 1 });

async function render(svg, px) {
  await page.setViewportSize({ width: px, height: px });
  await page.setContent(`<style>html,body{margin:0;background:transparent}svg{display:block}</style>${svg}`);
  return page.screenshot({ omitBackground: true, clip: { x: 0, y: 0, width: px, height: px } });
}

const outputs = [
  ['favicon-16.png', 16],
  ['favicon-32.png', 32],
  ['apple-touch-icon.png', 180, { square: true }],
  ['icon-192.png', 192],
  ['app-icon.png', 200],
  ['icon-512.png', 512]
];

try {
  writeFileSync(join(publicDir, 'favicon.svg'), tileSvg(32) + '\n');
  for (const [name, px, opts] of outputs) {
    writeFileSync(join(publicDir, name), await render(tileSvg(px, opts), px));
  }
  const ico = [];
  for (const px of [16, 32, 48]) ico.push({ px, data: await render(tileSvg(px), px) });
  writeFileSync(join(publicDir, 'favicon.ico'), packIco(ico));
} finally {
  await browser.close();
}

console.log(`icons → ${publicDir}`);
