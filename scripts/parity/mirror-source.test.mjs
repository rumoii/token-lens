import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { mirrorSource } from './real-common.mjs';
import { parseGrok } from '../../src/core/adapters/grok.js';
import { parseCline } from '../../src/core/adapters/cline.js';

const cases = [
  {
    source: 'grok', primary: '.grok/sessions/session/updates.jsonl', sidecar: 'summary.json', parse: parseGrok,
    content: JSON.stringify({ timestamp: '2026-01-15T03:00:00Z', params: { sessionId: 'session', update: {
      sessionUpdate: 'turn_completed', turnId: 'turn', usage: { inputTokens: 10, outputTokens: 2 },
    } } }) + '\n',
    metadata: { current_model_id: 'grok-4.7' }, model: 'grok-4.7',
  },
  {
    source: 'cline', primary: 'AppData/Roaming/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/task/api_conversation_history.json',
    sidecar: 'ui_messages.json', parse: parseCline,
    content: JSON.stringify([{ role: 'assistant', id: 'message', ts: 1768446000000, usage: { input_tokens: 10, output_tokens: 2 } }]),
    metadata: [{ ts: 1768446000000, say: 'api_req_started', text: JSON.stringify({ model: 'claude-sonnet-4' }) }], model: 'claude-sonnet-4',
  },
];
const records = async (parse, file) => {
  const result = [];
  for await (const record of parse(file)) result.push(record);
  return result;
};

for (const entry of cases) {
  for (const withSidecar of [true, false]) {
    test(`mirrorSource ${entry.source}: ${withSidecar ? 'copies model sidecar and preserves parsed records' : 'allows missing optional sidecar'}`, async () => {
      const root = mkdtempSync(join(tmpdir(), 'token-lens-mirror-'));
      const home = join(root, 'home'), target = join(root, 'mirror');
      const primary = join(home, entry.primary), sidecar = join(dirname(primary), entry.sidecar);
      mkdirSync(dirname(primary), { recursive: true });
      writeFileSync(primary, entry.content);
      if (withSidecar) writeFileSync(sidecar, JSON.stringify(entry.metadata));
      mirrorSource(home, [primary], target, entry.source);
      const mirrored = join(target, entry.primary), mirroredSidecar = join(dirname(mirrored), entry.sidecar);
      assert.deepEqual(readFileSync(mirrored), readFileSync(primary));
      assert.equal(existsSync(mirroredSidecar), withSidecar, entry.sidecar);
      if (withSidecar) assert.deepEqual(readFileSync(mirroredSidecar), readFileSync(sidecar));
      const original = await records(entry.parse, primary);
      assert.equal(original.length, 1);
      assert.equal(original[0].model, withSidecar ? entry.model : null);
      assert.deepEqual(await records(entry.parse, mirrored), original);
    });
  }
}
