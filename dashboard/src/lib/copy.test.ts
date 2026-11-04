import { describe, expect, it, vi } from 'vitest';
import { copy, setCopyLocale } from './copy';

describe('static shared text', () => {
  it('switches between Chinese and English and falls back for untranslated units', () => {
    setCopyLocale('zh-CN');
    expect(copy('preference.theme.dark')).toBe('使用深色外观');
    expect(copy('shared.unit.thousand_abbrev')).toBe('K');
    setCopyLocale('en');
    expect(copy('preference.theme.dark')).toBe('Dark appearance');
    expect(copy('error.boundary.hint')).toContain('\n');
    const warning = vi.spyOn(console, 'warn').mockImplementation(() => {});
    expect(copy('absent.test.key')).toBe('absent.test.key');
    expect(warning).toHaveBeenCalledWith(expect.stringContaining('absent.test.key'));
    expect(copy('__proto__')).toBe('__proto__');
  });
  it('keeps missing parameters and treats zero, false and markup as text', () => {
    setCopyLocale('en');
    expect(copy('shared.error.prefix')).toContain('{{error}}');
    expect(copy('shared.error.prefix', { error: null })).toContain('{{error}}');
    expect(copy('shared.error.prefix', { error: 0 })).toBe('Diagnostic: 0');
    expect(copy('shared.error.prefix', { error: false })).toBe('Diagnostic: false');
    expect(copy('shared.error.prefix', { error: '<img onerror=bad>' })).toBe('Diagnostic: <img onerror=bad>');
  });
});
