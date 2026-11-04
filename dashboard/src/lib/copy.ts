import { en, zhCN } from '../content/messages';
import { normalizeResolvedLocale, type ResolvedLocale } from './locale';

let current: ResolvedLocale = 'en';
export function setCopyLocale(locale: unknown): void {
  current = normalizeResolvedLocale(locale);
}

export function copy(key: unknown, params: Record<string, unknown> = {}): string {
  const name = String(key);
  const base = Object.hasOwn(en, name) ? en[name] : undefined;
  if (base === undefined && import.meta.env.DEV) console.warn(`Unregistered interface text: ${name}`);
  const translated = current === 'zh-CN' && Object.hasOwn(zhCN, name) ? zhCN[name] : undefined;
  const text = translated?.trim() ? translated : base ?? name;
  return text.replace(/\\n/g, '\n').replace(/\{\{(\w+)\}\}/g, (slot, parameter: string) =>
    Object.hasOwn(params, parameter) && params[parameter] != null ? String(params[parameter]) : slot);
}
