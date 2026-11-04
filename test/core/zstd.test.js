import { test } from 'node:test';
import assert from 'node:assert/strict';
import { zstdCompressSync } from 'node:zlib';
import { decompressZstdFrames, decompressZstdText } from '../../src/core/adapters/_zstd.js';

test('decompressZstdFrames: 单帧', () => {
  const payload = Buffer.from('{"a":1}\n');
  assert.equal(decompressZstdText(zstdCompressSync(payload)), '{"a":1}\n');
});

test('decompressZstdFrames: 多帧拼接必须全部解出（node:zlib 原生只解第一帧）', () => {
  const first = Buffer.from('{"a":1}\n');
  const second = Buffer.from('{"b":2}\n');
  const third = Buffer.from('{"c":3}\n');
  const joined = Buffer.concat([
    zstdCompressSync(first),
    zstdCompressSync(second),
    zstdCompressSync(third)
  ]);
  assert.equal(decompressZstdText(joined), '{"a":1}\n{"b":2}\n{"c":3}\n');
});

test('decompressZstdFrames: 跳过 skippable 帧', () => {
  const payload = zstdCompressSync(Buffer.from('x'));
  const skippable = Buffer.alloc(8 + 4);
  skippable.writeUInt32LE(0x184d2a50, 0);
  skippable.writeUInt32LE(4, 4);
  const out = decompressZstdFrames(Buffer.concat([skippable, payload]));
  assert.equal(out.toString(), 'x');
});

test('decompressZstdFrames: 空输入返回空', () => {
  assert.equal(decompressZstdFrames(Buffer.alloc(0)).length, 0);
});

test('decompressZstdFrames: 截断数据必须抛错而不是返回半份', () => {
  const full = zstdCompressSync(Buffer.from('{"a":1}\n'.repeat(50)));
  const truncated = full.subarray(0, full.length - 5);
  assert.throws(() => decompressZstdFrames(truncated));
});

test('decompressZstdFrames: 非 zstd 输入抛错', () => {
  assert.throws(() => decompressZstdFrames(Buffer.from('not zstd at all')));
});
