import { safeGetItem, safeSetItem } from './safe-browser';

export const EN_LOCALE = 'en';
export const ZH_CN_LOCALE = 'zh-CN';
export const SYSTEM_LOCALE = 'system';
export const LOCALE_STORAGE_KEY = 'token-lens-locale';
export type ResolvedLocale = typeof EN_LOCALE | typeof ZH_CN_LOCALE;
export type LocalePreference = ResolvedLocale | typeof SYSTEM_LOCALE;

export function normalizeResolvedLocale(value: unknown): ResolvedLocale {
  return typeof value === 'string' && /^zh(?:[-_]|$)/i.test(value.trim()) ? ZH_CN_LOCALE : EN_LOCALE;
}

export function normalizeLocalePreference(value: unknown): LocalePreference {
  if (value == null || value === '' || value === SYSTEM_LOCALE) return SYSTEM_LOCALE;
  return value === ZH_CN_LOCALE ? ZH_CN_LOCALE : EN_LOCALE;
}

export function resolvePreferredLocale(preference: unknown, languages?: readonly string[]): ResolvedLocale {
  const selected = normalizeLocalePreference(preference);
  if (selected !== SYSTEM_LOCALE) return selected;
  const available = languages ?? (typeof navigator === 'undefined' ? [] : navigator.languages?.length ? navigator.languages : [navigator.language]);
  return normalizeResolvedLocale(available.find(item => typeof item === 'string' && item.trim()));
}

export function getInitialLocalePreference(): LocalePreference {
  return normalizeLocalePreference(safeGetItem(LOCALE_STORAGE_KEY));
}

export function persistLocalePreference(preference: unknown): boolean {
  return safeSetItem(LOCALE_STORAGE_KEY, normalizeLocalePreference(preference));
}
