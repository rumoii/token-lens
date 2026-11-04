import { describe, expect, it } from 'vitest';
import { formatChineseNumber as chinese, formatCompactNumber as compact, formatUsdCurrency as money, toDisplayNumber as full } from './format';

describe('numeric display contracts', () => {
  it('keeps missing, zero, exact integers and arbitrary text distinct', () => {
    expect([full(null), full(undefined), full(0)]).toEqual(['-', '-', '0']);
    const exact = 874123456789012345678901n;
    expect(full(exact)).toBe(exact.toLocaleString());
    expect(full(' 000874123456789012345678901 ')).toBe(exact.toLocaleString());
    expect(full(' -1530.4 ')).toBe('-1530.4');
    expect(full(NaN)).toBe(NaN.toLocaleString());
    expect(full(Infinity)).toBe(Infinity.toLocaleString());
    expect(full({ toString: () => ' note ' })).toBe('note');
  });

  it('formats every international level and promotes rounded boundaries', () => {
    for (const [input, expected] of [[730, '730'], [28765, '28.8K'], [-6204000, '-6.2M'], [4.78e9, '4.8B'], [3.14e12, '3.1T'], [999950, '1M'], [999950000, '1B'], [999950000000, '1T']] as const) {
      expect(compact(input)).toBe(expected);
    }
    expect(compact('  ')).toBe('0');
    expect(compact(-0)).toBe('0');
    expect(compact(12345, { decimals: -Infinity })).toBe('12K');
    expect(compact(12345, { decimals: NaN })).toBe('12K');
    expect(compact(12345, { decimals: Infinity })).toBe('12.345K');
    expect(compact(1234567, { decimals: 2.9 })).toBe('1.23M');
    const options = { thousandSuffix: 'kilo', millionSuffix: 'mega', billionSuffix: 'giga', trillionSuffix: 'tera' };
    expect([1e3, 1e6, 1e9, 1e12].map(n => compact(n, options))).toEqual(['1kilo', '1mega', '1giga', '1tera']);
    expect(compact(Number.MAX_VALUE)).toContain('T');
  });

  it('uses Chinese precision, integer rounding, promotions and signed small zero', () => {
    const cases: [number, string][] = [[9999.4, '9,999'], [9999.5, '1万'], [28640, '2.9万'], [73460000, '7346万'], [563000000, '5.6亿'], [99999999, '1亿'], [999999999999, '1万亿'], [-0.2, '-0'], [-0, '0'], [1.234e12, '1.2万亿']];
    for (const [input, expected] of cases) {
      expect(chinese(input, { decimals: 6 })).toBe(expected);
      expect(chinese(input, { decimals: 0 })).toBe(expected);
    }
    expect(chinese(Number.MAX_VALUE)).toContain('万亿');
  });

  it('rejects nonfinite compact values without treating them as zero', () => {
    for (const value of [undefined, null, NaN, Infinity, 'twelve']) {
      expect(compact(value)).toBe('-');
      expect(chinese(value)).toBe('-');
    }
  });

  it('truncates money after six-place rounding and applies only valid CNY conversion', () => {
    expect(money(-26.875)).toBe('-$26.87');
    expect(money(8.764321, { decimals: 4 })).toBe('$8.7643');
    expect(money(2.9999999)).toBe('$3.00');
    expect(money(12, { currency: 'CNY', rate: 7.43 })).toBe('¥89.16');
    expect(money(3, { currency: 'EUR', rate: 10 })).toBe('$3.00');
    expect(money(3, { currency: 'USD', rate: 10 })).toBe('$3.00');
    for (const rate of [0, -1, NaN, Infinity]) expect(money(3, { currency: 'CNY', rate })).toBe('¥3.00');
    expect(money(5n, { decimals: Infinity })).toBe('$5.000000');
    expect(money(5, { decimals: NaN })).toBe('$5');
    expect(money(-1e25)).toBe('$-1e+25');
    expect(money(Number.MAX_VALUE, { currency: 'CNY', rate: 10 })).toContain('Infinity');
    expect([money(null), money('  '), money('oops'), money(NaN)]).toEqual(['-', '-', 'oops', 'NaN']);
  });
});
