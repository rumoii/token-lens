import { formatChineseNumber, formatCompactNumber, toDisplayNumber } from './format';
import { safeGetItem, safeSetItem } from './safe-browser';

export const TOKEN_FORMAT_MODES = Object.freeze({ COMPACT: 'compact', FULL: 'full' });
export const TOKEN_UNIT_SYSTEMS = Object.freeze({ ENGLISH: 'english', CHINESE: 'chinese' });
export const TOKEN_FORMAT_STORAGE_KEY = 'tt.tokenFormat';
export const TOKEN_UNIT_SYSTEM_STORAGE_KEY = 'tt.tokenUnitSystem';
export const normalizeTokenFormatMode = value => value === 'full' ? 'full' : 'compact';
export const normalizeTokenUnitSystem = value => value === 'chinese' ? 'chinese' : 'english';
export const readTokenFormatMode = () => normalizeTokenFormatMode(safeGetItem(TOKEN_FORMAT_STORAGE_KEY));
export const readTokenUnitSystem = () => {
  if (safeGetItem(TOKEN_FORMAT_STORAGE_KEY) === 'chinese') return 'chinese';
  const value = safeGetItem(TOKEN_UNIT_SYSTEM_STORAGE_KEY);
  return value ? normalizeTokenUnitSystem(value) : 'chinese';
};
export const persistTokenFormatMode = value => {
  const normalized = normalizeTokenFormatMode(value);
  safeSetItem(TOKEN_FORMAT_STORAGE_KEY, normalized);
  return normalized;
};
export const persistTokenUnitSystem = value => {
  const normalized = normalizeTokenUnitSystem(value);
  safeSetItem(TOKEN_UNIT_SYSTEM_STORAGE_KEY, normalized);
  return normalized;
};
export const migrateLegacyChineseTokenFormat = () => {
  if (safeGetItem(TOKEN_FORMAT_STORAGE_KEY) !== 'chinese') return false;
  if (!safeSetItem(TOKEN_UNIT_SYSTEM_STORAGE_KEY, 'chinese')) return false;
  return safeSetItem(TOKEN_FORMAT_STORAGE_KEY, 'compact');
};
export const formatTokenCount = (value, options = {}) => {
  if (options.forceFull || normalizeTokenFormatMode(options.mode) === 'full') return toDisplayNumber(value);
  return options.unitSystem === 'chinese' || options.mode === 'chinese'
    ? formatChineseNumber(value, options) : formatCompactNumber(value, options);
};
export const formatTokenTooltip = (value, options = {}) => {
  const full = toDisplayNumber(value);
  const short = formatTokenCount(value, options);
  return full === short || full === '-' || short === '-' ? full : `${short} · ${full}`;
};
