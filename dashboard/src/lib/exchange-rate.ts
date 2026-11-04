import { isValidRate, type RateMap } from './currency';

export const EXCHANGE_RATE_TTL_MS = 24 * 60 * 60 * 1000;
type RateFetchOptions = {
  reason: 'user-click'; fetchImpl?: typeof fetch; url?: string; codes?: readonly string[]; signal?: AbortSignal;
};

export function shouldRefetch(fetchedAt: number | null | undefined, ttlMs = EXCHANGE_RATE_TTL_MS, now = Date.now()): boolean {
  return !isValidRate(fetchedAt) || now - fetchedAt > ttlMs;
}

export async function fetchUsdRates(options: RateFetchOptions): Promise<{ rates: RateMap; fetchedAt: number }> {
  if (options?.reason !== 'user-click') throw new Error('An explicit update click is required.');
  const request = options.fetchImpl ?? globalThis.fetch;
  if (typeof request !== 'function') throw new Error('Network requests are unavailable.');
  if (options.codes && !options.codes.includes('CNY')) throw new Error('The requested currencies must include CNY.');
  const controller = new AbortController();
  const cancel = () => controller.abort();
  if (options.signal?.aborted) cancel();
  options.signal?.addEventListener('abort', cancel, { once: true });
  const timeout = setTimeout(() => controller.abort(), 5000);
  try {
    const response = await request(options.url ?? 'https://open.er-api.com/v6/latest/USD', { signal: controller.signal });
    if (!response.ok) throw new Error(`Exchange service returned HTTP ${response.status}.`);
    const payload = await response.json();
    if (!payload?.rates || !isValidRate(payload.rates.CNY)) throw new Error('Exchange response has no usable CNY rate.');
    return { rates: { USD: 1, CNY: payload.rates.CNY }, fetchedAt: Date.now() };
  } catch (error) {
    if (controller.signal.aborted) throw new Error('Exchange request timed out or was interrupted.');
    throw error;
  } finally {
    clearTimeout(timeout);
    options.signal?.removeEventListener('abort', cancel);
  }
}
