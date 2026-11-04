import { getCurrencySymbol, isValidRate, normalizeCurrency } from './currency';

type CompactOptions = {
  decimals?: number; thousandSuffix?: string; millionSuffix?: string; billionSuffix?: string; trillionSuffix?: string;
};
type MoneyOptions = { decimals?: number; currency?: unknown; rate?: number };
const missing = '-';
const digits = (value: number) => Math.max(0, Math.min(6, Number.isNaN(value) ? 0 : Math.floor(value)));
const fixed = (value: number, places: number) => String(Number(value.toFixed(places)));

export function toDisplayNumber(value: unknown): string {
  if (value == null) return missing;
  const text = String(value).trim();
  try {
    if (typeof value === 'number' || typeof value === 'bigint') return value.toLocaleString();
    return /^\d+$/.test(text) ? BigInt(text).toLocaleString() : text;
  } catch {
    return text;
  }
}

function numeric(value: unknown): number {
  return value == null ? NaN : Number(String(value).trim());
}

export function formatCompactNumber(value: unknown, options: CompactOptions = {}): string {
  const number = numeric(value);
  if (!Number.isFinite(number)) return missing;
  const amount = Math.abs(number);
  if (amount < 1000) return String(number);
  const suffixes = [options.thousandSuffix ?? 'K', options.millionSuffix ?? 'M', options.billionSuffix ?? 'B', options.trillionSuffix ?? 'T'];
  let level = Math.min(3, Math.floor(Math.log10(amount) / 3) - 1);
  const precision = digits(options.decimals ?? 1);
  let coefficient = Number((amount / 1000 ** (level + 1)).toFixed(precision));
  if (coefficient >= 1000 && level < 3) {
    level += 1;
    coefficient = amount / 1000 ** (level + 1);
  }
  return `${number < 0 ? '-' : ''}${fixed(coefficient, precision)}${suffixes[level]}`;
}

export function formatChineseNumber(value: unknown, _options: { decimals?: number } = {}): string {
  const number = numeric(value);
  if (!Number.isFinite(number)) return missing;
  const amount = Math.abs(number);
  const sign = number < 0 ? '-' : '';
  if (Math.round(amount) < 10000) return sign + Math.round(amount).toLocaleString('en-US');
  const bases = [1e4, 1e8, 1e12];
  const labels = ['万', '亿', '万亿'];
  let level = amount >= 1e12 ? 2 : amount >= 1e8 ? 1 : 0;
  let coefficient = amount / bases[level];
  let precision = level === 2 || coefficient < 100 ? 1 : 0;
  if (Number(coefficient.toFixed(precision)) >= 10000 && level < 2) {
    level += 1;
    coefficient = amount / bases[level];
    precision = level === 2 || coefficient < 100 ? 1 : 0;
  }
  return sign + fixed(coefficient, precision) + labels[level];
}

export function formatUsdCurrency(value: unknown, options: MoneyOptions = {}): string {
  if (value == null || String(value).trim() === '') return missing;
  const text = String(value).trim();
  const number = Number(text);
  if (!Number.isFinite(number)) return text;
  const code = normalizeCurrency(options.currency);
  const converted = number * (code === 'CNY' && isValidRate(options.rate) ? options.rate : 1);
  const symbol = getCurrencySymbol(code);
  if (!Number.isFinite(converted) || Math.abs(converted) >= 1e21) return symbol + String(converted);
  const precision = digits(options.decimals ?? 2);
  const [integer, fraction] = Math.abs(converted).toFixed(6).split('.');
  return `${converted < 0 ? '-' : ''}${symbol}${BigInt(integer).toLocaleString()}${precision ? '.' + fraction.slice(0, precision) : ''}`;
}
