import { test } from 'node:test';
import assert from 'node:assert/strict';
import { assembleExe } from '../../desktop/package.mjs';

test('桌面构建：30MB 边界接受，超过一个字节必须拒绝', () => {
  // 空 manifest 占两个字节，固定尾部占 12 字节。
  const payload = Buffer.alloc(30_000_000 - 14);
  assert.equal(assembleExe(Buffer.alloc(0), payload, {}).length, 30_000_000);
  assert.throws(() => assembleExe(Buffer.alloc(1), payload, {}), /exceeds 30MB: 30000001/);
});

test('桌面构建：尾部可定位元信息，壳和压缩载荷字节原样保留', () => {
  const shell = Buffer.from('shell');
  const payload = Buffer.from([0, 1, 255]);
  const manifest = { version: '1.0.0-abc', compressed_size: payload.length };
  const exe = assembleExe(shell, payload, manifest);
  assert.deepEqual(exe.subarray(0, 8), Buffer.concat([shell, payload]));
  assert.equal(exe.subarray(-8).toString(), 'TLENS001');
  const size = exe.readUInt32LE(exe.length - 12);
  assert.deepEqual(JSON.parse(exe.subarray(exe.length - 12 - size, -12)), manifest);
});
