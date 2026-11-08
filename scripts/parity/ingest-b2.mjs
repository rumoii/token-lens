import { copyFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { syntheticHome } from './isolation.mjs';
import { runIngestion } from '../../src/core/ingest.js';
import { Ledger } from '../../src/core/db/ledger.js';
import { buildSummary,buildBreakdown } from '../../src/core/api/v1/usage.js';
export const setup=[{"source": "qwen", "input": "test/fixtures/parity/qwen/.qwen/usage/token-usage-ledger.jsonl", "target": ".qwen/usage/token-usage-ledger.jsonl", "ledger": true}, {"source": "dsh", "input": "test/fixtures/parity/dsh/.dsh/storages/session_projcache/sessions/session-ledger.json", "target": ".dsh/storages/session_projcache/sessions/session-ledger.json", "ledger": true}, {"source": "grok", "input": "test/fixtures/parity/grok/.grok/sessions/p/ledger/updates.jsonl", "target": ".grok/sessions/p/ledger/updates.jsonl", "ledger": true}, {"source": "aider", "input": "test/fixtures/parity/aider/.aider.llm.history", "target": ".aider.llm.history", "ledger": false}, {"source": "pi", "input": "test/fixtures/parity/pi/.pi/agent/sessions/p/ledger.jsonl", "target": ".pi/agent/sessions/p/ledger.jsonl", "ledger": true}, {"source": "cline", "input": "test/fixtures/parity/cline/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/ledger/api_conversation_history.json", "target": "APPDATA/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/ledger/api_conversation_history.json", "ledger": true}, {"source": "gemini", "input": "test/fixtures/parity/gemini/.gemini/sessions/session-ledger.json", "target": ".gemini/sessions/session-ledger.json", "ledger": true}, {"source": "openhands", "input": "test/fixtures/parity/openhands/.openhands/conversations/ledger/base_state.json", "target": ".openhands/conversations/ledger/base_state.json", "ledger": true}, {"source": "continue", "input": "test/fixtures/parity/continue/.continue/sessions/ledger.json", "target": ".continue/sessions/ledger.json", "ledger": true}, {"source": "trae", "input": "test/fixtures/parity/trae/ledger-trae.jsonl", "target": "ledger-trae.jsonl", "ledger": true}, {"source": "openclaw", "input": "test/fixtures/parity/openclaw/.openclaw/agents/a/sessions/ledger.jsonl", "target": ".openclaw/agents/a/sessions/ledger.jsonl", "ledger": true}, {"source": "kimi", "input": "test/fixtures/parity/kimi/.kimi/sessions/ledger.json", "target": ".kimi/sessions/ledger.json", "ledger": true}, {"source": "codebuddy", "input": "test/fixtures/parity/codebuddy/CodeBuddyExtension/Data/history/w/ledger/index.json", "target": "LOCALAPPDATA/CodeBuddyExtension/Data/history/w/ledger/index.json", "ledger": true}, {"source": "commandcode", "input": "test/fixtures/parity/commandcode/.commandcode/projects/p/ledger.jsonl", "target": ".commandcode/projects/p/ledger.jsonl", "ledger": true}, {"source": "openhands", "input": "test/fixtures/parity/openhands/.openhands/conversations/ledger/events/event-00000-00000000.json", "target": ".openhands/conversations/ledger/events/event-00000-00000000.json", "ledger": true, "sidecar": true}, {"source": "claude", "input": "test/fixtures/parity/ingest-a.jsonl", "target": ".claude/projects/a.jsonl", "ledger": false}, {"source": "codex", "input": "test/fixtures/parity/ingest-codex.jsonl", "target": ".codex/sessions/rollout-test.jsonl", "ledger": false}];
export async function generateIngestB2(output,now){
 const {home,root}=syntheticHome();
 const rows=[{type:'context',now,tz:process.env.TZ},{type:'setup',files:setup}];
 for(const row of setup.filter(r=>r.ledger)){const target=join(home,row.target);mkdirSync(join(target,'..'),{recursive:true});copyFileSync(row.input,target);}
 const dataDir=join(root,'data');
 for(let index=0;index<2;index++){const result=await runIngestion({dataDir});result.durationMs='<volatile>';rows.push({type:'run',index,expected:result});}
 const ledger=new Ledger(join(dataDir,'ledger.db'));
 rows.push({type:'query',fn:'summary',expected:buildSummary(ledger.read,{tz:'Asia/Shanghai'})});
 rows.push({type:'query',fn:'breakdown',expected:buildBreakdown(ledger.read,{tz:'Asia/Shanghai',by:'source'})});
 ledger.close();
 const db=new DatabaseSync(join(dataDir,'ledger.db'),{readOnly:true});
 for(const row of db.prepare('SELECT * FROM usage_records ORDER BY record_key').all()){
   if(/\bf[0-9a-f]{12}:/.test(row.record_key))throw Error('path-dependent record in ledger golden');
   delete row.id;row.ingested_at='<volatile>';row.source_file=row.source_file.slice(home.length+1);rows.push({type:'ledger_row',expected:row});
 }
 db.close();writeFileSync(join(output,'ingest-b2.jsonl'),rows.map(r=>JSON.stringify(r)).join('\n')+'\n');
}
