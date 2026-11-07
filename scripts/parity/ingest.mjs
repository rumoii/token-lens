import { copyFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { syntheticHome } from './isolation.mjs';
import { runIngestion } from '../../src/core/ingest.js';
import { Ledger } from '../../src/core/db/ledger.js';
import { buildSummary,buildBreakdown } from '../../src/core/api/v1/usage.js';

export async function generateIngest(output, now) {
  const {root,home}=syntheticHome();
  const destination={ 'ingest-a.jsonl':'.claude/projects/a.jsonl', 'ingest-b.jsonl':'.claude/projects/b.jsonl', 'ingest-codex.jsonl':'.codex/sessions/rollout-test.jsonl' };
  for(const [source,path] of Object.entries(destination)) {
    const full=join(home,path); mkdirSync(join(full,'..'),{recursive:true}); copyFileSync(join('test/fixtures/parity',source),full);
  }
  const dataDir=join(root,'data');
  const rows=[{type:'context',now,tz:process.env.TZ}];
  for(let index=0;index<2;index+=1) {
    const result=await runIngestion({dataDir});result.durationMs='<volatile>';
    rows.push({type:'run',index,expected:result});
  }
  const ledger=new Ledger(join(dataDir,'ledger.db'));
  rows.push({type:'query',fn:'lastRun',expected:ledger.read.lastRun()});
  for(const [tz,offsetMinutes] of [['Asia/Shanghai',480],['UTC',0]]) {
    process.env.TZ=tz;
    for(const params of [{tz},{tz,from:'2026-01-01',to:'2026-01-15'},{tz,source:'claude'},{tz,model:'unknown-model'},{tz,project:'/synthetic/project'},{tz,source:'missing'}]) {
      const filter={from:params.from||'',to:params.to||'',source:params.source||null,model:params.model||null,project:params.project||null,offsetMinutes};
      for(const [fn,call] of [['summary',()=>buildSummary(ledger.read,params)], ...['model','source','project','source_model'].map(by=>['breakdown',()=>buildBreakdown(ledger.read,{...params,by})])]) {
        const value=call(); rows.push({type:'query',fn,params:{...params,...(fn==='breakdown'?{by:value.by}:{})},offsetMinutes,expected:value});
      }
      for(const [fn,args] of [['totals',[filter]],['activity',[filter]],['breakdown',['source',filter]],['grouped',['source','model',filter]],['costRows',[filter]]]) rows.push({type:'query',fn:`read.${fn}`,args,expected:fn==='costRows'?[...ledger.read[fn](...args)]:ledger.read[fn](...args)});
    }
  }
  process.env.TZ='Asia/Shanghai';
  const mutation=new DatabaseSync(join(dataDir,'ledger.db'));
  const sql="UPDATE usage_records SET cost_micros=cost_micros+1 WHERE record_key='claude|owner'; UPDATE usage_records SET price_version='old' WHERE record_key='claude|older';";
  mutation.exec(sql);
  rows.push({type:'query',fn:'tamperedBreakdown',sql,params:{tz:'Asia/Shanghai',by:'model'},offsetMinutes:480,expected:buildBreakdown(ledger.read,{by:'model',tz:'Asia/Shanghai'})});
  mutation.exec("UPDATE usage_records SET cost_micros=cost_micros-1 WHERE record_key='claude|owner'; UPDATE usage_records SET price_version='7a41a11013b21c6b' WHERE record_key='claude|older';");
  mutation.close();ledger.close();
  const db=new DatabaseSync(join(dataDir,'ledger.db'),{readOnly:true});
  for(const row of db.prepare('SELECT u.*,s.record_key AS superseded_key FROM usage_records u LEFT JOIN usage_records s ON s.id=u.superseded_by ORDER BY u.record_key').all()) {
    delete row.id;row.ingested_at='<volatile>';row.superseded_by=row.superseded_key;delete row.superseded_key;
    row.source_file=row.source_file.slice(home.length+1);
    rows.push({type:'ledger_row',expected:row});
  }
  db.close();
  writeFileSync(join(output,'ingest.jsonl'),rows.map(r=>JSON.stringify(r)).join('\n')+'\n');
  console.log(`ingest: ${rows.length} vectors`);
}
