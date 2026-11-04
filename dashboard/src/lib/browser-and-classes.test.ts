import { describe, expect, it, vi } from 'vitest';
import { safeGetItem, safeSetItem } from './safe-browser';
import { cn } from './cn';

describe('browser boundaries and class composition', () => {
  it('reads and writes only the requested key through window storage', () => {
    localStorage.setItem('neighbor', 'untouched');
    const read = vi.spyOn(Storage.prototype, 'getItem');
    expect(safeSetItem('display-choice', 'chinese')).toBe(true);
    expect(safeGetItem('display-choice')).toBe('chinese');
    expect(read).toHaveBeenCalledWith('display-choice');
    expect(safeGetItem('unknown-key')).toBeNull();
    expect(localStorage.getItem('neighbor')).toBe('untouched');
  });
  it('contains absent capabilities, throwing getters and storage exceptions', () => {
    vi.stubGlobal('window', undefined);
    expect(safeGetItem('x')).toBeNull();
    expect(safeSetItem('x', 'y')).toBe(false);
    vi.stubGlobal('window', { localStorage: {} });
    expect(safeGetItem('x')).toBeNull();
    expect(safeSetItem('x', 'y')).toBe(false);
    vi.stubGlobal('window', { get localStorage() { throw new Error('permission'); } });
    expect(safeGetItem('x')).toBeNull();
    expect(safeSetItem('x', 'y')).toBe(false);
    vi.unstubAllGlobals();
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('quota'); });
    expect(safeSetItem('x', 'y')).toBe(false);
  });
  it('merges conflicting classes independently for each variant', () => {
    expect(cn('p-3', ['p-6', [null, false, 'custom-label']], { hidden: false, block: true })).toBe('p-6 custom-label block');
    expect(cn('bg-red-100 hover:bg-red-100 dark:p-3 md:p-2', 'hover:bg-blue-100 dark:p-6')).toBe('bg-red-100 md:p-2 hover:bg-blue-100 dark:p-6');
  });
});
