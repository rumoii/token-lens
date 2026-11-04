import { afterEach, describe, expect, it, vi } from 'vitest';
import { EXCHANGE_RATE_TTL_MS, fetchUsdRates, shouldRefetch } from './exchange-rate';

const success = (rates: unknown = { USD: 50, CNY: 7.64, EUR: 0.9 }) => new Response(JSON.stringify({ rates }), { status: 200 });
afterEach(() => vi.useRealTimers());
describe('explicit exchange update', () => {
  it('requires a click before any request and only returns USD/CNY', async () => {
    const request = vi.fn().mockResolvedValue(success());
    vi.stubGlobal('fetch', request);
    // @ts-expect-error missing click authorization is rejected at runtime
    await expect(fetchUsdRates()).rejects.toThrow('click');
    // @ts-expect-error an automatic refresh is not an authorized trigger
    await expect(fetchUsdRates({ reason: 'timer' })).rejects.toThrow('click');
    expect(request).toHaveBeenCalledTimes(0);
    const result = await fetchUsdRates({ reason: 'user-click' });
    expect(request).toHaveBeenCalledTimes(1);
    expect(request.mock.calls[0][0]).toBe('https://open.er-api.com/v6/latest/USD');
    expect(result.rates).toEqual({ USD: 1, CNY: 7.64 });
    expect(result.fetchedAt).toBeGreaterThan(0);
    await expect(fetchUsdRates({ reason: 'user-click', codes: ['EUR'] })).rejects.toThrow('CNY');
    expect(request).toHaveBeenCalledTimes(1);
  });
  it('rejects HTTP, JSON, payload, network and absent-fetch failures without retry', async () => {
    for (const response of [new Response('{}', { status: 503 }), new Response('not-json'), success({ CNY: '7.4' }), success({ CNY: 0 }), success({ EUR: 1 })]) {
      const request = vi.fn().mockResolvedValue(response);
      await expect(fetchUsdRates({ reason: 'user-click', fetchImpl: request })).rejects.toThrow();
      expect(request).toHaveBeenCalledTimes(1);
    }
    const offline = vi.fn().mockRejectedValue(new Error('offline'));
    await expect(fetchUsdRates({ reason: 'user-click', fetchImpl: offline })).rejects.toThrow('offline');
    vi.stubGlobal('fetch', undefined);
    await expect(fetchUsdRates({ reason: 'user-click' })).rejects.toThrow('unavailable');
  });
  it('aborts at five seconds and releases the timer on every settled outcome', async () => {
    vi.useFakeTimers();
    let signal: AbortSignal | undefined;
    const pending = vi.fn((_url, init) => new Promise<Response>((_resolve, reject) => {
      signal = init.signal;
      signal!.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')), { once: true });
    }));
    const result = fetchUsdRates({ reason: 'user-click', fetchImpl: pending });
    const rejected = expect(result).rejects.toThrow('interrupted');
    await vi.advanceTimersByTimeAsync(4999);
    expect(signal?.aborted).toBe(false);
    await vi.advanceTimersByTimeAsync(1);
    await rejected;
    expect(signal?.aborted).toBe(true);
    expect(vi.getTimerCount()).toBe(0);
    await fetchUsdRates({ reason: 'user-click', fetchImpl: vi.fn().mockResolvedValue(success()) });
    expect(vi.getTimerCount()).toBe(0);
    await expect(fetchUsdRates({ reason: 'user-click', fetchImpl: vi.fn().mockRejectedValue(new Error('offline')) })).rejects.toThrow();
    expect(vi.getTimerCount()).toBe(0);
  });
  it('only reports age and never schedules updates', () => {
    const request = vi.fn();
    vi.stubGlobal('fetch', request);
    const start = 900000000;
    expect(EXCHANGE_RATE_TTL_MS).toBe(86400000);
    for (const missing of [null, undefined, 0, NaN, Infinity]) expect(shouldRefetch(missing)).toBe(true);
    expect(shouldRefetch(start, 30, start + 30)).toBe(false);
    expect(shouldRefetch(start, 30, start + 31)).toBe(true);
    expect(shouldRefetch(start + 40, 30, start)).toBe(false);
    expect(request).toHaveBeenCalledTimes(0);
  });
});
