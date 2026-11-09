import { writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import assert from 'node:assert/strict';
import { syntheticHome } from './isolation.mjs';
import { cleanup } from './discovery-b3.mjs';
import { materialize } from './adapters-b3.mjs';
import { runIngestion } from '../../src/core/ingest.js';
import { Ledger } from '../../src/core/db/ledger.js';
import { buildSummary, buildBreakdown } from '../../src/core/api/v1/usage.js';

export const setup = [
  ['hermes','LOCALAPPDATA/hermes/state.db'],
  ['cursor','APPDATA/Cursor/User/globalStorage/state.vscdb'],
  ['opencode','XDG_DATA_HOME/opencode/opencode.db'],
  ['kilo','XDG_DATA_HOME/kilo/kilo.db'],
  ['goose','APPDATA/goose/sessions/sessions.db'],
  ['zed','LOCALAPPDATA/Zed/threads/threads.db'],
  ['copilot','.copilot/session-store.db'],
  ['mimo','XDG_DATA_HOME/mimocode/mimocode.db'],
  ['minimax','.minimax/v2/sqlite/runtime-state.sqlite'],
  ['zcode','.zcode/cli/db/db.sqlite'],
  ['anythingllm','APPDATA/anythingllm-desktop/storage/anythingllm.db'],
].map(([source,target])=>({source,input:`test/fixtures/parity/${source}/ledger.sql`,target,ledger:true}));

export async function generateIngestB3(output,now) {
  const outputPath=resolve(output);
  const {root,home}=syntheticHome();
  const rows=[{type:'context',now,tz:process.env.TZ},{type:'setup',files:setup}];
  try {
    for (const entry of setup) materialize(home,{source:entry.source,file:entry.target,kind:'seed',seed:entry.input});
    const dataDir=join(root,'data');
    for (let index=0;index<2;index++) {
      const result=await runIngestion({dataDir});
      result.durationMs='<volatile>';rows.push({type:'run',index,expected:result});
    }
    const ledger=new Ledger(join(dataDir,'ledger.db'));
    try {
      rows.push({type:'query',fn:'summary',expected:buildSummary(ledger.read,{tz:'Asia/Shanghai'})});
      rows.push({type:'query',fn:'breakdown',expected:buildBreakdown(ledger.read,{tz:'Asia/Shanghai',by:'source'})});
    } finally {ledger.close();}
    const db=new DatabaseSync(join(dataDir,'ledger.db'),{readOnly:true});
    try {
      for (const row of db.prepare('SELECT * FROM usage_records ORDER BY record_key').all()) {
        assert.ok(!/\bf[0-9a-f]{12}[|:]/.test(row.record_key) && !row.record_key.includes(home),'path-dependent ledger identity');
        delete row.id;row.ingested_at='<volatile>';row.source_file=row.source_file.slice(home.length+1);
        rows.push({type:'ledger_row',expected:row});
      }
    } finally {db.close();}
    assert.equal(rows.filter(r=>r.type==='ledger_row').length,11);
    assert.equal(rows.find(r=>r.type==='run'&&r.index===1).expected.inserted,0);
    writeFileSync(join(outputPath,'ingest-b3.jsonl'),rows.map(r=>JSON.stringify(r)).join('\n')+'\n');
    console.log('ingest-b3: 11 sources, 11 ledger rows, 2 syncs');
  } finally {cleanup(root);}
}
