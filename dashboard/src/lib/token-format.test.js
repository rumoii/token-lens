import { beforeEach, describe, expect, it, vi } from 'vitest';
import { formatTokenCount, formatTokenTooltip, migrateLegacyChineseTokenFormat, normalizeTokenFormatMode, normalizeTokenUnitSystem, persistTokenFormatMode, persistTokenUnitSystem, readTokenFormatMode, readTokenUnitSystem } from './token-format';

beforeEach(() => localStorage.clear());
describe('token choices', () => {
  it('has Chinese application defaults and English pure formatting defaults', () => {
    expect(readTokenFormatMode()).toBe('compact');
    expect(readTokenUnitSystem()).toBe('chinese');
    expect(formatTokenCount(2867000)).toBe('2.9M');
    expect(formatTokenCount(2867000, { unitSystem: 'chinese' })).toBe('287万');
    expect(formatTokenCount(2867000, { mode: 'chinese' })).toBe('287万');
    expect(formatTokenCount(2867000, { unitSystem: 'chinese', mode: 'full' })).toBe('2,867,000');
    expect(formatTokenCount(2867000, { mode: 'chinese', forceFull: true })).toBe('2,867,000');
    expect(formatTokenTooltip(2867000)).toBe('2.9M · 2,867,000');
    expect(formatTokenTooltip(27)).toBe('27');
    expect(formatTokenTooltip(null)).toBe('-');
    expect(formatTokenTooltip(NaN)).toBe('NaN');
    expect(formatTokenTooltip(2867000, { mode: 'full' })).toBe('2,867,000');
    expect(formatTokenCount(-2500, { thousandSuffix: 'kilo' })).toBe('-2.5kilo');
  });
  it('normalizes independent keys and persists only their normalized values', () => {
    expect(normalizeTokenFormatMode('invalid')).toBe('compact');
    expect(normalizeTokenUnitSystem('invalid')).toBe('english');
    localStorage.setItem('tt.tokenUnitSystem', '');
    expect(readTokenUnitSystem()).toBe('chinese');
    localStorage.setItem('tt.tokenUnitSystem', 'invalid');
    expect(readTokenUnitSystem()).toBe('english');
    expect(persistTokenFormatMode('full')).toBe('full');
    expect(readTokenFormatMode()).toBe('full');
    expect(persistTokenUnitSystem('chinese')).toBe('chinese');
    expect(readTokenUnitSystem()).toBe('chinese');
  });
  it('writes the legacy unit before replacing the legacy mode and can retry a failure', () => {
    localStorage.setItem('tt.tokenFormat', 'chinese');
    localStorage.setItem('tt.tokenUnitSystem', 'english');
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('quota'); });
    expect(migrateLegacyChineseTokenFormat()).toBe(false);
    expect(readTokenUnitSystem()).toBe('chinese');
    expect(localStorage.getItem('tt.tokenFormat')).toBe('chinese');
    expect(persistTokenFormatMode('full')).toBe('full');
    vi.restoreAllMocks();
    expect(migrateLegacyChineseTokenFormat()).toBe(true);
    expect(readTokenFormatMode()).toBe('compact');
    expect(readTokenUnitSystem()).toBe('chinese');
    expect(migrateLegacyChineseTokenFormat()).toBe(false);
    persistTokenUnitSystem('english');
    expect(migrateLegacyChineseTokenFormat()).toBe(false);
    expect(readTokenUnitSystem()).toBe('english');
  });
});
