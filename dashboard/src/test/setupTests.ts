import '@testing-library/jest-dom/vitest';
import { cleanup } from '@testing-library/react';
import { afterEach, vi } from 'vitest';

const browserStorage = window.localStorage;
Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: browserStorage });

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  browserStorage.clear();
});
