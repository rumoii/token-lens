import { StrictMode, useContext } from 'react';
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { CurrencyProvider, useCurrency } from '../CurrencyProvider';
import { ThemeProvider } from '../ThemeProvider';
import { LocaleProvider } from '../LocaleProvider';
import { TokenFormatContext, TokenFormatProvider } from '../TokenFormatProvider';
import { useTheme } from '../../../hooks/useTheme';
import { SettingsPage } from '../../../pages/v1/SettingsPage';
import { api } from '../../../lib/v1';
import { createSyncState } from '../../../lib/sync-state';

function CurrencyControls() {
  const state = useCurrency();
  if (!state) return <output>no currency provider</output>;
  return <><output>{`${state.currency}/${state.rate}/${state.source}/${state.fetchedAt}/${state.refreshing}/${state.error}`}</output>
    <button onClick={() => state.setCurrency('CNY')}>select CNY</button>
    <button onClick={state.refreshRates}>update</button>
  </>;
}
function ThemeControls() {
  const { theme, resolvedTheme, setTheme } = useTheme();
  return <><output>{`${theme}/${resolvedTheme}`}</output>{['light', 'dark', 'system', 'bad'].map(value => <button key={value} onClick={() => setTheme(value)}>{value}</button>)}</>;
}
function Units() {
  const context = useContext(TokenFormatContext);
  return <><output>{context.unitSystem}</output><button onClick={() => context.setUnitSystem('english')}>english units</button></>;
}
function mediaMock(legacy = false) {
  const listeners = new Set();
  const media = { matches: true };
  const add = vi.fn(listener => listeners.add(listener));
  const remove = vi.fn(listener => listeners.delete(listener));
  if (legacy) Object.assign(media, { addListener: add, removeListener: remove });
  else Object.assign(media, { addEventListener: (_type, listener) => add(listener), removeEventListener: (_type, listener) => remove(listener) });
  vi.stubGlobal('matchMedia', () => media);
  return { listeners, set: dark => { media.matches = dark; act(() => listeners.forEach(listener => listener({ matches: dark }))); } };
}
afterEach(() => {
  vi.useRealTimers();
  document.documentElement.classList.remove('dark', 'preserve-test-class');
});

describe('currency request ownership', () => {
  it('does not refresh rates after a day, browser events or local synchronization', async () => {
    vi.useFakeTimers();
    const request = vi.fn();
    vi.stubGlobal('fetch', request);
    vi.spyOn(api, 'sync').mockResolvedValue({ attempted: 1, inserted: 1, anomalies: [] });
    render(<CurrencyProvider><CurrencyControls /></CurrencyProvider>);
    act(() => {
      window.dispatchEvent(new Event('focus'));
      document.dispatchEvent(new Event('visibilitychange'));
    });
    await act(async () => {
      await vi.advanceTimersByTimeAsync(25 * 60 * 60 * 1000);
      await createSyncState().startSync();
    });
    expect(request).toHaveBeenCalledTimes(0);
    expect(screen.getByRole('status')).toHaveTextContent('/false/null');
  });
  it('initializes and switches without a request; suppresses duplicate pending updates', async () => {
    localStorage.setItem('token-lens-currency', 'EUR');
    let finish;
    const request = vi.fn(() => new Promise(resolve => { finish = resolve; }));
    vi.stubGlobal('fetch', request);
    const mounted = render(<StrictMode><CurrencyProvider><CurrencyControls /></CurrencyProvider></StrictMode>);
    expect(screen.getByRole('status')).toHaveTextContent('USD/1/default/null/false/null');
    fireEvent.click(screen.getByText('select CNY'));
    expect(request).toHaveBeenCalledTimes(0);
    fireEvent.click(screen.getByText('update'));
    fireEvent.click(screen.getByText('update'));
    expect(request).toHaveBeenCalledTimes(1);
    await act(async () => finish(new Response('{"rates":{"CNY":7.91}}')));
    expect(screen.getByRole('status')).toHaveTextContent('CNY/7.91/fetched/');
    mounted.unmount();
    render(<CurrencyProvider><CurrencyControls /></CurrencyProvider>);
    expect(screen.getByRole('status')).toHaveTextContent('CNY/7.91/fetched/');
    expect(request).toHaveBeenCalledTimes(1);
  });
  it('retains old values on failure and uses successful unsaved rates until remount', async () => {
    localStorage.setItem('token-lens-currency', 'CNY');
    localStorage.setItem('token-lens-exchange-rates', '{"CNY":7.1}');
    localStorage.setItem('token-lens-exchange-rate-source', 'fetched');
    localStorage.setItem('token-lens-exchange-rate-fetched-at', '123456');
    const request = vi.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce(new Response('{"rates":{"CNY":8.12}}'));
    vi.stubGlobal('fetch', request);
    const mounted = render(<CurrencyProvider><CurrencyControls /></CurrencyProvider>);
    fireEvent.click(screen.getByText('update'));
    await screen.findByText(/offline/);
    expect(screen.getByRole('status')).toHaveTextContent('CNY/7.1/fetched/123456/false/');
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('quota'); });
    fireEvent.click(screen.getByText('update'));
    await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('CNY/8.12/fetched/'));
    expect(screen.getByRole('status').textContent.endsWith('/false/null')).toBe(true);
    mounted.unmount();
    render(<CurrencyProvider><CurrencyControls /></CurrencyProvider>);
    expect(screen.getByRole('status')).toHaveTextContent('CNY/7.1/fetched/123456/false/null');
  });
  it('aborts an owned update on unmount and ignores late completion', async () => {
    let signal;
    let finish;
    vi.stubGlobal('fetch', vi.fn((_url, init) => { signal = init.signal; return new Promise(resolve => { finish = resolve; }); }));
    const mounted = render(<CurrencyProvider><CurrencyControls /></CurrencyProvider>);
    fireEvent.click(screen.getByText('update'));
    mounted.unmount();
    expect(signal.aborted).toBe(true);
    await act(async () => finish(new Response('{"rates":{"CNY":9.4}}')));
    expect(localStorage.getItem('token-lens-exchange-rates')).toBeNull();
  });
  it('keeps the real settings page offline through mount, remount and currency selection until update is clicked', async () => {
    vi.spyOn(api, 'pricing').mockResolvedValue({ models: [] });
    vi.spyOn(api, 'breakdown').mockResolvedValue({ groups: [] });
    vi.spyOn(api, 'health').mockResolvedValue({});
    const request = vi.fn().mockResolvedValue(new Response('{"rates":{"CNY":7.72}}'));
    vi.stubGlobal('fetch', request);
    const mount = () => render(<ThemeProvider><CurrencyProvider><SettingsPage /></CurrencyProvider></ThemeProvider>);
    const first = mount();
    await screen.findByText('更新汇率');
    fireEvent.click(screen.getByRole('tab', { name: '人民币 ¥' }));
    first.unmount();
    mount();
    await screen.findByText('更新汇率');
    expect(request).toHaveBeenCalledTimes(0);
    fireEvent.click(screen.getByText('更新汇率'));
    await waitFor(() => expect(screen.getByText(/1 美元 ≈ 7.72/)).toBeInTheDocument());
    expect(request).toHaveBeenCalledTimes(1);
  });
  it('allows an absent currency provider', () => {
    render(<CurrencyControls />);
    expect(screen.getByRole('status')).toHaveTextContent('no currency provider');
  });
});

describe('theme and token subscriptions', () => {
  it.each([false, true])('cleans up system theme listeners with legacy=%s', legacy => {
    const media = mediaMock(legacy);
    document.documentElement.classList.add('preserve-test-class');
    const mounted = render(<StrictMode><ThemeProvider><ThemeControls /></ThemeProvider></StrictMode>);
    expect(screen.getByRole('status')).toHaveTextContent('system/dark');
    expect(media.listeners.size).toBe(1);
    media.set(false);
    expect(document.documentElement).not.toHaveClass('dark');
    fireEvent.click(screen.getByText('dark', { selector: 'button' }));
    media.set(true); media.set(false);
    expect(screen.getByRole('status')).toHaveTextContent('dark/dark');
    expect(document.documentElement).toHaveClass('dark', 'preserve-test-class');
    fireEvent.click(screen.getByText('bad', { selector: 'button' }));
    expect(screen.getByRole('status')).toHaveTextContent('dark/dark');
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('quota'); });
    fireEvent.click(screen.getByText('light', { selector: 'button' }));
    expect(screen.getByRole('status')).toHaveTextContent('light/light');
    mounted.unmount();
    expect(media.listeners.size).toBe(0);
  });
  it('uses system appearance on invalid or denied storage and diagnoses missing provider', () => {
    mediaMock();
    localStorage.setItem('token-lens-theme', 'removed-theme');
    const first = render(<ThemeProvider><ThemeControls /></ThemeProvider>);
    expect(screen.getByRole('status')).toHaveTextContent('system/dark');
    first.unmount();
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('denied'); });
    render(<ThemeProvider><ThemeControls /></ThemeProvider>);
    expect(screen.getByRole('status')).toHaveTextContent('system/dark');
    vi.spyOn(console, 'error').mockImplementation(() => {});
    expect(() => render(<ThemeControls />)).toThrow('ThemeProvider');
  });
  it('migrates token units, handles external changes and releases storage subscriptions', () => {
    localStorage.setItem('tt.tokenFormat', 'chinese');
    const added = vi.spyOn(window, 'addEventListener');
    const removed = vi.spyOn(window, 'removeEventListener');
    const mounted = render(<StrictMode><LocaleProvider><TokenFormatProvider><Units /></TokenFormatProvider></LocaleProvider></StrictMode>);
    expect(screen.getByRole('status')).toHaveTextContent('chinese');
    act(() => window.dispatchEvent(new StorageEvent('storage', { key: 'tt.tokenUnitSystem', newValue: 'invalid' })));
    expect(screen.getByRole('status')).toHaveTextContent('english');
    act(() => window.dispatchEvent(new StorageEvent('storage', { key: 'tt.tokenFormat', newValue: 'chinese' })));
    expect(screen.getByRole('status')).toHaveTextContent('chinese');
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('quota'); });
    fireEvent.click(screen.getByText('english units'));
    expect(screen.getByRole('status')).toHaveTextContent('english');
    mounted.unmount();
    expect(added.mock.calls.filter(([type]) => type === 'storage').length).toBe(removed.mock.calls.filter(([type]) => type === 'storage').length);
  });
});
