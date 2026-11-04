import { test } from 'node:test';
import assert from 'node:assert/strict';

import { createDiscoveryService } from '../../src/core/api/v1/sources.js';

/**
 * 不调用真实 `discoverAll()`：`discovery.js` 在模块加载时就读取用户主目录，
 * 真跑会扫到本机真实日志。这里注入假的发现函数，结果是确定的。
 */
const fakeDiscover = () => ({
  claude: ['/fake/a.jsonl', '/fake/b.jsonl'],
  codex: ['/fake/c.jsonl'],
  qwen: []
});

test('发现结果只列有文件的来源，按文件数降序', () => {
  const { sources } = createDiscoveryService(fakeDiscover)();
  assert.deepEqual(sources, [
    { source: 'claude', files: 2 },
    { source: 'codex', files: 1 }
  ]);
});

test('supported 是适配器注册表的工具总数', () => {
  const { supported } = createDiscoveryService(fakeDiscover)();
  assert.equal(supported, 27);
});

test('响应里不含任何文件路径', () => {
  const result = createDiscoveryService(fakeDiscover)();
  assert.ok(!JSON.stringify(result).includes('/fake/'), '路径不得出现在响应里');
});

test('一分钟内复用扫盘结果，fresh 时重扫', () => {
  let calls = 0;
  const counting = () => {
    calls += 1;
    return { claude: Array.from({ length: calls }, (_, i) => `/fake/${i}.jsonl`) };
  };
  const buildDiscovery = createDiscoveryService(counting);
  assert.deepEqual(buildDiscovery().sources, [{ source: 'claude', files: 1 }]);
  assert.deepEqual(buildDiscovery().sources, [{ source: 'claude', files: 1 }], '缓存内不重扫');
  assert.equal(calls, 1);
  assert.deepEqual(buildDiscovery({ fresh: true }).sources, [{ source: 'claude', files: 2 }]);
  assert.equal(calls, 2, '重新检测必须真的重扫');
});

test('发现缓存属于服务实例，同一个发现函数也不会共享缓存', () => {
  let calls = 0;
  const discover = () => ({ claude: Array(++calls).fill('/fake/file') });
  const first = createDiscoveryService(discover);
  const second = createDiscoveryService(discover);
  assert.equal(first().sources[0].files, 1);
  assert.equal(second().sources[0].files, 2);
  assert.equal(first().sources[0].files, 1);
  assert.equal(calls, 2);
});

test('发现缓存满一分钟后过期，失败结果不进入缓存', (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: 1_000 });
  let calls = 0;
  const discover = createDiscoveryService(() => {
    calls += 1;
    if (calls === 2) throw new Error('discovery failed');
    return { codex: Array(calls).fill('/fake/file') };
  });
  assert.equal(discover().sources[0].files, 1);
  t.mock.timers.setTime(60_999);
  assert.equal(discover().sources[0].files, 1);
  t.mock.timers.setTime(61_000);
  assert.throws(() => discover(), /discovery failed/);
  assert.equal(discover().sources[0].files, 3);
});
