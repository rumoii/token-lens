import { describe, expect, it, vi } from 'vitest';
import { getInitialLocalePreference, normalizeLocalePreference, normalizeResolvedLocale, persistLocalePreference, resolvePreferredLocale } from './locale';

describe('two-language preference', () => {
  it('separates removed saved preferences from system Chinese tags', () => {
    expect(getInitialLocalePreference()).toBe('system');
    for (const old of ['ja', 'de', 'ko', 'zh-TW', 'unknown']) {
      localStorage.setItem('token-lens-locale', old);
      expect(getInitialLocalePreference()).toBe('en');
    }
    for (const tag of ['zh-TW', 'zh-HK', ' ZH_hant ', 'zh', 'zh-CN']) {
      expect(normalizeResolvedLocale(tag)).toBe('zh-CN');
      expect(resolvePreferredLocale('system', [tag])).toBe('zh-CN');
    }
    expect(normalizeLocalePreference('zh-TW')).toBe('en');
    expect(persistLocalePreference('de')).toBe(true);
    expect(localStorage.getItem('token-lens-locale')).toBe('en');
  });
  it('uses only the first populated language and handles absent browser capabilities', () => {
    expect(resolvePreferredLocale('system', [' ', 'en-GB', 'zh-CN'])).toBe('en');
    expect(resolvePreferredLocale('system', ['', 'zh_TW'])).toBe('zh-CN');
    expect(resolvePreferredLocale('en', ['zh'])).toBe('en');
    expect(resolvePreferredLocale('zh-CN', ['en'])).toBe('zh-CN');
    vi.stubGlobal('navigator', undefined);
    expect(resolvePreferredLocale('system')).toBe('en');
    vi.stubGlobal('navigator', { languages: [], language: 'zh-HK' });
    expect(resolvePreferredLocale('system')).toBe('zh-CN');
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('read'); });
    expect(getInitialLocalePreference()).toBe('system');
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('write'); });
    expect(persistLocalePreference('zh-CN')).toBe(false);
  });
});
