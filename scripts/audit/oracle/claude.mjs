import { count, entry, jsonLines, readFiles } from './common.mjs';

export async function oracle(options = {}) {
  return readFiles('claude', options, async (file, issues) => {
    const entries = [];
    for await (const { value: row, line } of jsonLines(file, issues)) {
      const usage = row.message?.usage;
      if (!usage || typeof usage !== 'object') continue;
      const identity = row.message.id ?? row.uuid ?? `file:${file}:${line}`;
      entries.push(entry('claude', row.sessionId, identity, file, line, row.timestamp, {
        input: count(usage.input_tokens), output: count(usage.output_tokens),
        cache_read: count(usage.cache_read_input_tokens), cache_write: count(usage.cache_creation_input_tokens)
      }, { message_id: row.message.id ?? null, uuid: row.uuid ?? null, usage }));
    }
    return { entries };
  });
}
