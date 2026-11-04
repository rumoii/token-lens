import { createContext, useEffect, useLayoutEffect, useState } from 'react';
import { safeGetItem, safeSetItem } from '../../lib/safe-browser';

export const ThemeContext = createContext(null);
const query = '(prefers-color-scheme: dark)';
const valid = value => ['light', 'dark', 'system'].includes(value);
function media() {
  return typeof window !== 'undefined' && typeof window.matchMedia === 'function' ? window.matchMedia(query) : null;
}

export function ThemeProvider({ children }) {
  const [theme, select] = useState(() => {
    const stored = safeGetItem('token-lens-theme');
    return valid(stored) ? stored : 'system';
  });
  const [systemDark, changeSystem] = useState(() => media()?.matches ?? false);
  const resolvedTheme = theme === 'system' ? systemDark ? 'dark' : 'light' : theme;
  useLayoutEffect(() => {
    if (typeof document !== 'undefined') document.documentElement.classList.toggle('dark', resolvedTheme === 'dark');
  }, [resolvedTheme]);
  useEffect(() => {
    const preference = media();
    if (!preference) return;
    const changed = event => changeSystem(event.matches);
    changeSystem(preference.matches);
    if (preference.addEventListener) {
      preference.addEventListener('change', changed);
      return () => preference.removeEventListener('change', changed);
    }
    preference.addListener(changed);
    return () => preference.removeListener(changed);
  }, []);
  const setTheme = value => {
    if (!valid(value)) return;
    select(value);
    safeSetItem('token-lens-theme', value);
  };
  return <ThemeContext.Provider value={{ theme, resolvedTheme, setTheme }}>{children}</ThemeContext.Provider>;
}
