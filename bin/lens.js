#!/usr/bin/env node

import('../src/core/cli.js').catch((err) => {
  console.error(err);
  process.exit(1);
});
