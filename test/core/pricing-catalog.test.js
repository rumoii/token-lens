import { test } from 'node:test';
import assert from 'node:assert/strict';
import { priceRecord, PRICE_VERSION } from '../../src/core/pricing/engine.js';
import { findPrice, classifyPrice } from '../../src/core/pricing/catalog.js';

const row = (model, overrides = {}) => ({
  model, kind: 'event', observed_at: '2026-10-26T02:00:00Z',
  input_tokens: 10_000, output_tokens: 2_000, cache_read_tokens: 5_000, cache_write_tokens: 1_000,
  ...overrides
});

// 分项期望值独立于目录，单位为 micro-USD；来源见 P1 核验台账。
for (const [model, input, output, cache_read, cache_write] of [
  ['kimi-k3.1-pro', 20_000, 20_000, 1_000, 2_000],
  ['kimi-k3.1-pro-highspeed', 40_000, 40_000, 1_000, 4_000],
  ['kimi-k3', 30_000, 30_000, 1_500, 3_000],
  ['grok-4.7', 20_000, 12_000, 2_500, 0],
  ['gemini-3.8-flash', 7_500, 7_500, 375, 0],
  ['gemini-4-argon', 20_000, 20_000, 500, 0],
  ['gemini-3.1-pro-preview', 20_000, 24_000, 1_000, 0],
  ['claude-opus-4-6', 50_000, 50_000, 2_500, 6_250],
  ['qwen3-coder-flash', 3_000, 3_000, 150, 375],
  ['glm-5.3', 14_000, 8_800, 1_300, 0],
  ['glm-5.3-flash', 1_500, 1_000, 150, 0],
  ['glm-5.3-flashx', 3_700, 2_500, 375, 0],
  ['MiniMax-M3', 3_000, 2_400, 300, 0],
  ['MiniMax-M3.1-Flash', 1_500, 1_200, 75, 0],
  ['mimo-v2.6-pro', 4_350, 1_740, 18, 0],
  ['mimo-v2.6-flash', 1_400, 560, 14, 0],
  ['mimo-v2.6-pro-ultraspeed', 43_500, 17_400, 180, 0]
]) {
  test(`P1 官方目录：${model} 的四类金额与来源`, () => {
    const p = priceRecord(row(model));
    assert.deepEqual(p.parts, { input, output, cache_read, cache_write });
    assert.equal(p.cost_micros, input + output + cache_read + cache_write);
    assert.equal(p.price_source, `verified:${model}`);
    assert.equal(p.price_version, PRICE_VERSION);
    assert.equal(findPrice(model).verifiedAt, '2026-10-26');
    assert.equal(classifyPrice(model).provisional, false);
  });
}

for (const [model, alias, write] of [
  ['kimi-k3.1-pro', 'kimi-code/k3.1-pro', 3_000],
  ['kimi-k3.1-pro-highspeed', 'kimi-code/k3.1-pro-highspeed', 6_000],
  ['kimi-k3', 'kimi-code/k3', 4_500],
  ['claude-opus-4-6', 'claude-opus-4-6-thinking', 8_125]
]) {
  test(`P1 别名与缓存写双档：${alias}`, () => {
    assert.equal(findPrice(alias)?.id, model);
    assert.equal(findPrice(alias)?.matchedBy, 'exact');
    const p = priceRecord(row(alias, { cache_write_5m_tokens: 500, cache_write_1h_tokens: 500 }));
    assert.equal(p.parts.cache_write, write);
    assert.equal(p.price_source, `verified:${model}`);
    assert.deepEqual(p, priceRecord(row(model, { cache_write_5m_tokens: 500, cache_write_1h_tokens: 500 })));
    if (alias.startsWith('kimi-code/')) assert.equal(classifyPrice(alias).billing, 'plan');
  });
}

// 每个阈值的本值与下一个 token；缓存读写也计入提示长度。
for (const [model, prompt, input, output, cache_read, cache_write, mark] of [
  ['grok-4.7', 199_999, 379_998, 12_000, 2_500, 0, ''],
  ['grok-4.7', 200_000, 760_000, 24_000, 5_000, 0, ';tier:199999'],
  ['gemini-3.1-pro-preview', 200_000, 380_000, 24_000, 1_000, 0, ''],
  ['gemini-3.1-pro-preview', 200_001, 760_004, 36_000, 2_000, 0, ';tier:200000'],
  ['qwen3-coder-flash', 32_000, 6_600, 3_000, 150, 1_875, ''],
  ['qwen3-coder-flash', 32_001, 11_000, 5_000, 250, 3_125, ';tier:32000'],
  ['qwen3-coder-flash', 128_000, 59_000, 5_000, 250, 3_125, ';tier:32000'],
  ['qwen3-coder-flash', 128_001, 94_400, 8_000, 400, 5_000, ';tier:128000'],
  ['qwen3-coder-flash', 256_000, 196_800, 8_000, 400, 5_000, ';tier:128000'],
  ['qwen3-coder-flash', 256_001, 393_601, 19_200, 800, 10_000, ';tier:256000'],
  ['MiniMax-M3', 512_000, 150_600, 2_400, 300, 0, ''],
  ['MiniMax-M3', 512_001, 301_200, 4_800, 600, 0, ';tier:512000']
]) {
  test(`P1 上下文阈值：${model} 提示 ${prompt}`, () => {
    const p = priceRecord(row(model, { input_tokens: prompt - 10_000, cache_write_tokens: 5_000 }));
    assert.deepEqual(p.parts, { input, output, cache_read, cache_write });
    assert.equal(p.cost_micros, input + output + cache_read + cache_write);
    assert.equal(p.price_source, `verified:${model}${mark}`);
  });
}

test('P1 未确认的变体保持原聚合条目，不当成官方别名', () => {
  assert.equal(findPrice('gemini-3.8-flash-n').tier, 'aggregate');
  assert.equal(findPrice('gemini-3.8-flash-n').id, 'gemini-3.8-flash-n');
  for (const model of ['kimi-code/k3.1', 'kimi-code/k3-256k', 'qwen3:8b', 'qwen:uncensored-4b']) {
    assert.equal(priceRecord(row(model)).cost_micros, null);
  }
});

// MiniMax 官方旧搜索快照的 M2.7 价格；不同型号的期望值独立写出。
for (const [model, rates, parts, total] of [
  ['MiniMax-M2.7', { input: 0.3, output: 1.2, cacheRead: 0.06, cacheWrite: 0.375 },
    { input: 3_000, output: 2_400, cache_read: 300, cache_write: 375 }, 6_075],
  ['MiniMax-M2.7-highspeed', { input: 0.6, output: 2.4, cacheRead: 0.06, cacheWrite: 0.375 },
    { input: 6_000, output: 4_800, cache_read: 300, cache_write: 375 }, 11_475]
]) {
  test(`MiniMax 旧快照：${model} 的单价、请求金额与模型 ID`, () => {
    const price = findPrice(model);
    assert.ok(price, `${model} 应有官方价格条目`);
    assert.deepEqual(price.perMTok, rates);
    assert.equal(price.sourceUrl, 'https://platform.minimax.io/subscribe/token-plan?tab=api-enterprise');
    assert.equal(price.verifiedAt, '2026-11-01');
    assert.equal(price.tier, 'aggregate');
    assert.equal(classifyPrice(model).provisional, true);
    assert.match(price.conditions, /旧搜索快照/);
    assert.match(price.conditions, /快照日期(?:：\d{4}-\d{2}-\d{2}|未知)/);
    assert.match(price.conditions, /verifiedAt.*复核日期/);
    assert.match(price.conditions, /退役/);
    assert.equal(price.tiers, null);
    assert.equal(price.timeOfDay, null);
    const priced = priceRecord(row(model));
    assert.deepEqual(priced.parts, parts);
    assert.equal(priced.cost_micros, total);
    assert.equal(priced.price_source, `aggregate:${model}`);
    assert.equal(priced.price_version, PRICE_VERSION);
    assert.equal(findPrice(model.toLowerCase())?.id, model);
    assert.equal(findPrice(`minimax/${model}`)?.id, model);
    assert.equal(findPrice(model.replace('.', '-'))?.id, model);
  });
}

test('MiniMax 未核验型号不借用 M2.7 或 M3.1-Flash 的价格', () => {
  for (const model of ['MiniMax-M2.7-turbo', 'MiniMax-M2.7-preview', 'MiniMax-M3.1']) {
    assert.equal(findPrice(model), null);
    assert.equal(priceRecord(row(model)).cost_micros, null);
  }
});
