import { count, entry, jsonLines, readFiles, subtract } from './common.mjs';

const rawFields = ['input_tokens', 'output_tokens', 'cached_input_tokens', 'total_tokens'];

function sumUsage(rows) {
  return Object.fromEntries(rawFields.map(field => {
    const values = rows.map(row => count(row[field]));
    return [field, values.includes(null) ? null : values.reduce((a, b) => a + b, 0)];
  }));
}

export async function oracle(options = {}) {
  return readFiles('codex', options, async (file, issues) => {
    const entries = [], lastUsages = [], allLastUsages = [], responses = new Map(), unreflected = [];
    let pending = [];
    let session = null, lastTotal = null, totalLine = null, repeated = 0, resets = 0, extraField = null;
    for await (const { value: row, line } of jsonLines(file, issues)) {
      const payload = row.payload;
      if (row.type === 'session_meta') session = payload?.session_id ?? payload?.id ?? null;
      if (row.type === 'event_msg' && payload?.type === 'token_count' && payload.info?.total_token_usage) {
        const total = payload.info.total_token_usage;
        if (payload.info.last_token_usage) allLastUsages.push(payload.info.last_token_usage);
        const same = lastTotal && rawFields.every(field => total[field] === lastTotal[field]);
        if (same) {
          repeated++;
          for (const response of pending) unreflected.push({ ...response, reason: 'next_notice_total_unchanged',
            notice_line: line, last_token_usage: payload.info.last_token_usage, total_token_usage: total });
        }
        else {
          if (lastTotal && rawFields.some(field => count(total[field]) !== null && count(lastTotal[field]) !== null && total[field] < lastTotal[field])) resets++;
          if (payload.info.last_token_usage) lastUsages.push(payload.info.last_token_usage);
        }
        lastTotal = total;
        totalLine = line;
        pending = [];
      }
      if (row.type !== 'token_usage_record' || !payload?.usage) continue;
      const usage = payload.usage;
      const sid = payload.session_id ?? session;
      const id = payload.response_id;
      if (!id) issues.push({ type: 'missing_response_id', file, line });
      if ('cache_write_input_tokens' in usage && !extraField) extraField = { type: 'schema_extra_cache_write', file, line, value: usage.cache_write_input_tokens,
        note: '规格称客户端不报缓存写；保留原值作证据，oracle 缓存写依契约为未知。' };
      const identity = JSON.stringify([sid, id ?? `file:${file}:${line}`]);
      const tokens = { input: subtract(count(usage.input_tokens), count(usage.cached_input_tokens)),
        output: count(usage.output_tokens), cache_read: count(usage.cached_input_tokens), cache_write: null };
      entries.push(entry('codex', sid, identity, file, line, row.timestamp, tokens, { response_id: id ?? null, usage }));
      responses.set(identity, usage);
      pending.push({ line, response_id: id ?? null, usage });
    }
    if (extraField) issues.push(extraField);
    const usageSum = sumUsage([...responses.values()]);
    const lastSum = sumUsage(lastUsages);
    const allLastSum = sumUsage(allLastUsages);
    for (const response of pending) unreflected.push({ ...response, reason: 'after_final_total' });
    const unreflectedSum = sumUsage(unreflected.map(row => row.usage));
    const difference = sum => Object.fromEntries(rawFields.map(field => [field,
      lastTotal && count(lastTotal[field]) !== null && sum[field] !== null ? sum[field] - lastTotal[field] : null]));
    return { entries, cross_checks: [{ file, session_id: session, line: totalLine, total_token_usage: lastTotal,
      usage_records: responses.size, last_usage_records: lastUsages.length, repeated_token_count: repeated,
      cumulative_resets: resets, sum_usage: usageSum, sum_last_token_usage: lastSum,
      sum_all_last_token_usage: allLastSum, raw_last_minus_total: difference(allLastSum),
      unreflected_responses: unreflected, unreflected_sum: unreflectedSum,
      residual_after_unreflected: Object.fromEntries(rawFields.map(field => [field,
        difference(usageSum)[field] === null || unreflectedSum[field] === null ? null : difference(usageSum)[field] - unreflectedSum[field]])),
      usage_minus_total: difference(usageSum), last_minus_total: difference(lastSum),
      status: !lastTotal ? 'missing_total' : resets ? 'cumulative_reset' : 'compared' }] };
  });
}
