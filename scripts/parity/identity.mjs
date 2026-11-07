import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import { payloadHash } from '../../src/core/db/write.js';

// payloadHash exposes its digest, not its canonical bytes. Pin both and verify
// that these reconstructed bytes produce the production entry point's digest.
export function identity(record) {
  const known = value => value == null ? 'null' : Number(value);
  const fields = [record.kind || 'event', record.model || '',
    ...['input_tokens','output_tokens','cache_read_tokens','cache_write_tokens'].map(key => known(record[key])),
    record.observed_at || '', record.ended_at || '', record.session_id || '',
    known(record.cache_write_5m_tokens), known(record.cache_write_1h_tokens)];
  if (record.provider != null) fields.push(record.provider);
  const bytes = Buffer.from(fields.join('\x1f'),'utf8');
  const expected = payloadHash(record);
  assert.equal(createHash('sha256').update(bytes).digest('hex').slice(0,32),expected);
  return {expected,canonical_utf8_hex:bytes.toString('hex')};
}
