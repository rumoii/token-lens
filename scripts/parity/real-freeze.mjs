import { mock } from 'node:test';
const now = Date.parse(process.env.TL_PARITY_NOW ?? '');
if (!Number.isFinite(now)) throw Error('TL_PARITY_NOW required');
mock.timers.enable({ apis: ['Date'], now });
