import {writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {Ledger} from '../../src/core/db/ledger.js';
import {buildSummary} from '../../src/core/api/v1/usage.js';
import {costOf} from '../../src/core/pricing/engine.js';

export function generateQueryBoundaries(output,now){
  const rows=[{type:'context',now,tz:'Asia/Shanghai'}];
  for(const [input,read] of [[31,1],[19999,1],[511,1],[0,1]]){
    const record={record_key:'ratio',source:'claude',model:'unlisted',observed_at:'2026-01-15T00:00:00.000Z',input_tokens:input,cache_read_tokens:read};
    const ledger=new Ledger(':memory:');ledger.write.ingestBatch([record],{priceOf:costOf});
    rows.push({type:'query',fn:'summary',record,expected:buildSummary(ledger.read,{})});ledger.close();
  }
  writeFileSync(join(output,'query-boundaries.jsonl'),rows.map(r=>JSON.stringify(r)).join('\n')+'\n');
}
