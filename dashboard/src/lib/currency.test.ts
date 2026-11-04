import { beforeEach, describe, expect, it, vi } from 'vitest';
import { applyCurrency, DEFAULT_RATES, getCurrencySymbol, getInitialCurrency, getInitialExchangeRates, getRateFor, getSupportedCurrencies, isValidRate, normalizeCurrency, persistCurrency, persistExchangeRates } from './currency';

const store = (value: string) => localStorage.setItem('token-lens-exchange-rates', value);
beforeEach(() => localStorage.clear());
describe('local USD/CNY state', () => {
  it('restricts choices and falls back from removed currency preferences', () => {
    expect(getSupportedCurrencies().map(item => item.code)).toEqual(['USD', 'CNY']);
    for (const old of ['EUR', 'JPY', 'GBP', 'HKD', '', 'nonsense']) {
      localStorage.setItem('token-lens-currency', old);
      expect(getInitialCurrency()).toBe('USD');
    }
    expect(normalizeCurrency(' cny ')).toBe('CNY');
    expect(getCurrencySymbol('usd')).toBe('$');
    expect(getCurrencySymbol(' CNY')).toBe('¥');
    expect(persistCurrency('cny')).toBe(true);
    expect(getInitialCurrency()).toBe('CNY');
  });
  it('accepts only positive finite numeric runtime rates', () => {
    for (const invalid of ['7.8', 0, -3, NaN, Infinity, null]) expect(isValidRate(invalid)).toBe(false);
    expect(isValidRate(7.8)).toBe(true);
    expect(getRateFor({ USD: 400, CNY: 7.8 }, 'USD')).toBe(1);
    expect(getRateFor({ CNY: 0 }, 'CNY')).toBe(6.7);
    expect(applyCurrency(13, 'CNY', { CNY: 8 })).toEqual({ value: 104, symbol: '¥' });
    expect(applyCurrency(13, 'EUR', null)).toEqual({ value: 13, symbol: '$' });
  });
  it('recovers malformed cache and strips removed fields from saved values', () => {
    for (const value of ['{', 'null', '[]', '{}', '{"EUR":4}', '{"CNY":0}', '{"CNY":false}']) {
      store(value);
      expect(getInitialExchangeRates()).toEqual({ rates: DEFAULT_RATES, source: 'default', fetchedAt: null });
    }
    store('{"CNY":"7.82","USD":70,"EUR":9}');
    localStorage.setItem('token-lens-exchange-rate-source', 'obsolete');
    localStorage.setItem('token-lens-exchange-rate-fetched-at', 'not-a-time');
    expect(getInitialExchangeRates()).toEqual({ rates: { USD: 1, CNY: 7.82 }, source: 'default', fetchedAt: null });
    expect(persistExchangeRates({ rates: { USD: 1, CNY: 7.9 }, source: 'fetched', fetchedAt: 456789 })).toBe(true);
    expect(JSON.parse(localStorage.getItem('token-lens-exchange-rates')!)).toEqual({ USD: 1, CNY: 7.9 });
    expect(getInitialExchangeRates().fetchedAt).toBe(456789);
    expect(persistExchangeRates({ rates: { USD: 1, CNY: -9 }, source: 'default', fetchedAt: null })).toBe(false);
  });
  it('survives read denial, write denial and incomplete metadata writes without networking', () => {
    const network = vi.fn();
    vi.stubGlobal('fetch', network);
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('denied'); });
    expect(getInitialCurrency()).toBe('USD');
    expect(getInitialExchangeRates().rates.CNY).toBe(6.7);
    vi.restoreAllMocks();
    const original = Storage.prototype.setItem;
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(function (this: Storage, key, value) {
      if (key.includes('source')) throw new Error('quota');
      original.call(this, key, value);
    });
    expect(persistExchangeRates({ rates: { USD: 1, CNY: 8.2 }, source: 'fetched', fetchedAt: 1234 })).toBe(false);
    expect(getInitialExchangeRates()).toEqual({ rates: { USD: 1, CNY: 8.2 }, source: 'default', fetchedAt: 1234 });
    expect(network).toHaveBeenCalledTimes(0);
  });
});
