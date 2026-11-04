import { createContext, useEffect, useState } from 'react';
import { useLocale } from '../../hooks/useLocale';
import { copy } from '../../lib/copy';
import { formatTokenCount, formatTokenTooltip, migrateLegacyChineseTokenFormat, normalizeTokenUnitSystem, persistTokenUnitSystem, readTokenUnitSystem, TOKEN_FORMAT_STORAGE_KEY, TOKEN_UNIT_SYSTEM_STORAGE_KEY } from '../../lib/token-format';

export const TokenFormatContext = createContext(null);

export const TokenFormatProvider = ({ children }) => {
  useLocale();
  const [unitSystem, select] = useState(() => {
    migrateLegacyChineseTokenFormat();
    return readTokenUnitSystem();
  });
  useEffect(() => {
    const storageChanged = event => {
      if (event.key === TOKEN_UNIT_SYSTEM_STORAGE_KEY) select(event.newValue ? normalizeTokenUnitSystem(event.newValue) : 'chinese');
      if (event.key === TOKEN_FORMAT_STORAGE_KEY && event.newValue === 'chinese') select('chinese');
    };
    window.addEventListener('storage', storageChanged);
    return () => window.removeEventListener('storage', storageChanged);
  }, []);
  const options = {
    unitSystem,
    thousandSuffix: copy('shared.unit.thousand_abbrev'), millionSuffix: copy('shared.unit.million_abbrev'),
    billionSuffix: copy('shared.unit.billion_abbrev'), trillionSuffix: copy('shared.unit.trillion_abbrev')
  };
  return <TokenFormatContext.Provider value={{
    unitSystem, setUnitSystem: value => select(persistTokenUnitSystem(value)),
    formatTokens: value => formatTokenCount(value, options),
    formatTooltip: value => formatTokenTooltip(value, options)
  }}>{children}</TokenFormatContext.Provider>;
};
