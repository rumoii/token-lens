import { createContext, useContext, useEffect, useRef, useState } from 'react';
import { getInitialCurrency, getInitialExchangeRates, getRateFor, normalizeCurrency, persistCurrency, persistExchangeRates } from '../../lib/currency';
import { fetchUsdRates } from '../../lib/exchange-rate';

const CurrencyContext = createContext(null);
export const useCurrency = () => useContext(CurrencyContext);

export function CurrencyProvider({ children }) {
  const [currency, select] = useState(getInitialCurrency);
  const [exchange, update] = useState(getInitialExchangeRates);
  const [refreshing, markPending] = useState(false);
  const [error, showError] = useState(null);
  const inflight = useRef(null);
  useEffect(() => () => {
    inflight.current?.abort();
    inflight.current = null;
  }, []);
  const setCurrency = value => {
    const normalized = normalizeCurrency(value);
    select(normalized);
    persistCurrency(normalized);
  };
  const refreshRates = async () => {
    if (inflight.current) return;
    const operation = new AbortController();
    inflight.current = operation;
    markPending(true);
    showError(null);
    try {
      const fetched = await fetchUsdRates({ reason: 'user-click', signal: operation.signal });
      if (inflight.current !== operation) return;
      const next = { ...fetched, source: 'fetched' };
      update(next);
      persistExchangeRates(next);
    } catch (failure) {
      if (inflight.current === operation) showError(`汇率更新失败：${failure instanceof Error ? failure.message : String(failure)}`);
    } finally {
      if (inflight.current === operation) {
        inflight.current = null;
        markPending(false);
      }
    }
  };
  return <CurrencyContext.Provider value={{ currency, ...exchange, rate: getRateFor(exchange.rates, currency), refreshing, error, setCurrency, refreshRates }}>{children}</CurrencyContext.Provider>;
}
