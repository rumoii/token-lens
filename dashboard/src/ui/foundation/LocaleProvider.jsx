import { createContext, useEffect, useLayoutEffect, useState } from 'react';
import { getInitialLocalePreference, normalizeLocalePreference, persistLocalePreference, resolvePreferredLocale } from '../../lib/locale';
import { setCopyLocale } from '../../lib/copy';

export const LocaleContext = createContext(null);

export const LocaleProvider = ({ children }) => {
  const [locale, select] = useState(getInitialLocalePreference);
  const [, revise] = useState(0);
  const resolvedLocale = resolvePreferredLocale(locale);
  setCopyLocale(resolvedLocale);
  useLayoutEffect(() => {
    if (typeof document !== 'undefined') document.documentElement.lang = resolvedLocale;
  }, [resolvedLocale]);
  useEffect(() => {
    if (locale !== 'system' || typeof window === 'undefined') return;
    const changed = () => revise(n => n + 1);
    window.addEventListener('languagechange', changed);
    return () => window.removeEventListener('languagechange', changed);
  }, [locale]);
  const setLocale = value => {
    const normalized = normalizeLocalePreference(value);
    persistLocalePreference(normalized);
    select(normalized);
  };
  return <LocaleContext.Provider value={{ locale, resolvedLocale, setLocale }}>{children}</LocaleContext.Provider>;
};
