import { StrictMode } from 'react';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { LocaleProvider } from '../LocaleProvider';
import { useLocale } from '../../../hooks/useLocale';
import { copy, setCopyLocale } from '../../../lib/copy';

function LanguageControls() {
  const { locale, resolvedLocale, setLocale } = useLocale();
  return <><output>{`${locale}/${resolvedLocale}/${copy('settings.appearance.language.label')}`}</output>
    {['en', 'zh-CN', 'system'].map(value => <button key={value} onClick={() => setLocale(value)}>{value}</button>)}
  </>;
}

describe('language ownership', () => {
  it.each(['ja', 'de', 'zh-TW'])('falls back from removed stored preference %s', previous => {
    localStorage.setItem('token-lens-locale', previous);
    render(<LocaleProvider><LanguageControls /></LocaleProvider>);
    expect(screen.getByRole('status')).toHaveTextContent('en/en/Interface language');
    expect(document.documentElement.lang).toBe('en');
  });
  it('renders saved Chinese immediately and changes shared text with document lang', () => {
    localStorage.setItem('token-lens-locale', 'zh-CN');
    setCopyLocale('en');
    render(<LocaleProvider><LanguageControls /></LocaleProvider>);
    expect(screen.getByRole('status')).toHaveTextContent('zh-CN/zh-CN/界面语言');
    expect(document.documentElement.lang).toBe('zh-CN');
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('quota'); });
    fireEvent.click(screen.getByText('en', { selector: 'button' }));
    expect(screen.getByRole('status')).toHaveTextContent('en/en/Interface language');
    expect(document.documentElement.lang).toBe('en');
  });
  it('observes system language only while selected and releases listeners in StrictMode', () => {
    const browser = { languages: ['zh-HK'] };
    vi.stubGlobal('navigator', browser);
    const added = vi.spyOn(window, 'addEventListener');
    const removed = vi.spyOn(window, 'removeEventListener');
    const mounted = render(<StrictMode><LocaleProvider><LanguageControls /></LocaleProvider></StrictMode>);
    expect(screen.getByRole('status')).toHaveTextContent('system/zh-CN/');
    browser.languages = ['en-US'];
    act(() => window.dispatchEvent(new Event('languagechange')));
    expect(screen.getByRole('status')).toHaveTextContent('system/en/');
    fireEvent.click(screen.getByText('zh-CN', { selector: 'button' }));
    act(() => window.dispatchEvent(new Event('languagechange')));
    expect(screen.getByRole('status')).toHaveTextContent('zh-CN/zh-CN/');
    mounted.unmount();
    expect(added.mock.calls.filter(([type]) => type === 'languagechange').length).toBe(removed.mock.calls.filter(([type]) => type === 'languagechange').length);
  });
  it('diagnoses a missing language provider', () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    expect(() => render(<LanguageControls />)).toThrow('LocaleProvider');
  });
});
