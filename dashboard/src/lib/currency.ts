import { safeGetItem, safeSetItem } from './safe-browser';

export const CURRENCY_USD = 'USD';
export const CURRENCY_CNY = 'CNY';
export type CurrencyCode = 'USD' | 'CNY';
export type RateMap = Record<CurrencyCode, number>;
export type ExchangeRatesState = {
  rates: RateMap;
  source: 'default' | 'fetched';
  fetchedAt: number | null;
};
export const SUPPORTED_CURRENCY_CODES = [CURRENCY_USD, CURRENCY_CNY] as const;
export const DEFAULT_RATES: Readonly<RateMap> = Object.freeze({ USD: 1, CNY: 6.7 });
const keys = {
  currency: 'token-lens-currency', rates: 'token-lens-exchange-rates',
  source: 'token-lens-exchange-rate-source', time: 'token-lens-exchange-rate-fetched-at'
};

export function isValidRate(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0;
}

export function normalizeCurrency(value: unknown): CurrencyCode {
  return typeof value === 'string' && value.trim().toUpperCase() === CURRENCY_CNY ? CURRENCY_CNY : CURRENCY_USD;
}

export function getCurrencySymbol(code: unknown): string {
  return normalizeCurrency(code) === CURRENCY_CNY ? '¥' : '$';
}

export function getInitialCurrency(): CurrencyCode {
  return normalizeCurrency(safeGetItem(keys.currency));
}

export function persistCurrency(value: unknown): boolean {
  return safeSetItem(keys.currency, normalizeCurrency(value));
}

export function getInitialExchangeRates(): ExchangeRatesState {
  const fallback: ExchangeRatesState = { rates: { ...DEFAULT_RATES }, source: 'default', fetchedAt: null };
  try {
    const stored = JSON.parse(safeGetItem(keys.rates) ?? 'null');
    if (!stored || typeof stored !== 'object' || Array.isArray(stored)) return fallback;
    const cny = typeof stored.CNY === 'string' ? Number(stored.CNY) : stored.CNY;
    if (!isValidRate(cny)) return fallback;
    const time = Number(safeGetItem(keys.time));
    return {
      rates: { USD: 1, CNY: cny },
      source: safeGetItem(keys.source) === 'fetched' ? 'fetched' : 'default',
      fetchedAt: isValidRate(time) ? time : null
    };
  } catch {
    return fallback;
  }
}

export function persistExchangeRates(state: ExchangeRatesState): boolean {
  if (!state || !isValidRate(state.rates?.CNY)) return false;
  const entries = [
    [keys.rates, JSON.stringify({ USD: 1, CNY: state.rates.CNY })],
    [keys.source, state.source === 'fetched' ? 'fetched' : 'default'],
    [keys.time, isValidRate(state.fetchedAt) ? String(state.fetchedAt) : '']
  ];
  return entries.map(([key, value]) => safeSetItem(key, value)).every(Boolean);
}

export function getRateFor(rates: Partial<RateMap> | null | undefined, code: unknown): number {
  return normalizeCurrency(code) === CURRENCY_USD ? 1 : isValidRate(rates?.CNY) ? rates.CNY : DEFAULT_RATES.CNY;
}

export function getSupportedCurrencies() {
  return SUPPORTED_CURRENCY_CODES.map(code => ({
    code, symbol: getCurrencySymbol(code), labelKey: `settings.appearance.currency.opt.${code.toLowerCase()}`
  }));
}

export function applyCurrency(usdValue: number, code: unknown, rates: Partial<RateMap> | null | undefined) {
  return { value: usdValue * getRateFor(rates, code), symbol: getCurrencySymbol(code) };
}
