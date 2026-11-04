import { test } from 'node:test';
import assert from 'node:assert/strict';

import { findPrice, classifyPrice } from '../../src/core/pricing/catalog.js';

test('精确名与登记别名标为 exact', () => {
  assert.equal(findPrice('claude-opus-5-5').matchedBy, 'exact');
  assert.equal(findPrice('claude-opus-5.5').matchedBy, 'exact', '目录里登记的别名');
  assert.equal(findPrice('CLAUDE-OPUS-5-5').matchedBy, 'exact', '大小写不影响');
});

test('同一模型的其它写法标为 normalized', () => {
  const cases = [
    'claude-opus-5-5-high',
    'claude-opus-5-5-thinking',
    'openrouter/anthropic/claude-opus-5-5',
    'Claude Opus 5.5 (Preview)'
  ];

  for (const name of cases) {
    const price = findPrice(name);
    assert.ok(price, `${name} 应当命中`);
    assert.equal(price.id, 'claude-opus-5-5', `${name} 应当落到 claude-opus-5-5`);
    assert.equal(price.matchedBy, 'normalized', `${name} 应当是归一化命中`);
  }
});

test('价位不同的相近模型不会互相命中', () => {
  assert.equal(findPrice('gpt-6-sol').id, 'gpt-6-sol');
  assert.equal(findPrice('gpt-6.1-sol').id, 'gpt-6.1-sol');
  assert.notEqual(
    findPrice('gpt-6-sol').perMTok.output,
    0,
    '两个条目各自有价，不能被合并'
  );

  assert.equal(findPrice('gemini-3.8-flash').id, 'gemini-3.8-flash');
  assert.equal(findPrice('gemini-3.8-flash-n').id, 'gemini-3.8-flash-n');
});

test('查不到就是未定价，不猜', () => {
  for (const name of ['qwen:uncensored-4b', 'some-unknown-model', '', null, undefined]) {
    assert.equal(findPrice(name), null, `${String(name)} 不该有价`);
  }

  const cls = classifyPrice('some-unknown-model');
  assert.equal(cls.state, 'unknown');
  assert.equal(cls.matchedBy, null);
});

test('状态与查价走同一条匹配链，不会出现「有价但未定价」', () => {
  const name = 'claude-opus-5-5-high';
  assert.ok(findPrice(name), '归一化能查到价');

  const cls = classifyPrice(name);
  assert.equal(cls.id, 'claude-opus-5-5');
  assert.notEqual(cls.state, 'unknown', '查得到价就不能显示未定价');
  assert.equal(cls.matchedBy, 'normalized');
});

test('归一化命中不改变价格与可信度', () => {
  const plain = findPrice('claude-opus-5-5');
  const suffixed = findPrice('claude-opus-5-5-high');

  assert.deepEqual(suffixed.perMTok, plain.perMTok, '单价必须一致');
  assert.equal(suffixed.tier, plain.tier, '可信度等级不因写法而降级');
  assert.equal(suffixed.billing, plain.billing);
});
