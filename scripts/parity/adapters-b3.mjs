import { mkdirSync, readFileSync, readdirSync, writeFileSync, copyFileSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import assert from 'node:assert/strict';
import { syntheticHome } from './isolation.mjs';
import { cleanup, sources } from './discovery-b3.mjs';
import { adapters } from '../../src/core/adapters/index.js';
import { newNotes } from '../../src/core/adapters/_num.js';
import { fileTag } from '../../src/core/adapters/_lines.js';
import { identity } from './identity.mjs';

const repo = fileURLToPath(new URL('../../', import.meta.url));
const fixture = source => `test/fixtures/parity/${source}`;
export function scenarios() {
  const setups=[];
  for (const source of sources) {
    for (const name of readdirSync(join(repo,fixture(source))).filter(n=>n.endsWith('.sql')).sort()) {
      setups.push({source,scenario:name.slice(0,-4),file:`${fixture(source)}/${name.slice(0,-4)}.db`,kind:'seed',seed:`${fixture(source)}/${name}`});
    }
    for (const kind of ['missing','empty','missing-table','garbage','open-error','wal-live','wal-leftover']) {
      setups.push({source,scenario:kind,file:`${fixture(source)}/${kind}.db`,kind,...(kind.startsWith('wal-')?{seed:`${fixture(source)}/ledger.sql`}:{})});
    }
  }
  for (const name of readdirSync(join(repo,fixture('cursor'))).filter(n=>n.endsWith('.csv')).sort()) {
    setups.push({source:'cursor',scenario:name,file:`${fixture('cursor')}/${name}`,kind:'csv',input:`${fixture('cursor')}/${name}`});
  }
  for (const [scenario,file,kind] of [['crlf','crlf.csv','csv-crlf'],['upper-suffix','usage.CSV','csv'],['second-directory','second/usage.csv','csv']]) {
    setups.push({source:'cursor',scenario,file:`${fixture('cursor')}/${file}`,kind,input:`${fixture('cursor')}/usage.csv`});
  }
  setups.push({source:'cursor',scenario:'missing-csv',file:`${fixture('cursor')}/missing.CSV`,kind:'missing'},
    {source:'cursor',scenario:'unsupported',file:`${fixture('cursor')}/unsupported.json`,kind:'garbage'},
    {source:'cursor',scenario:'no-extension',file:`${fixture('cursor')}/no-extension`,kind:'missing'});
  for (const [scenario,name,sibling] of [['adjacent','data.db','seed'],['uppercase-basename','Data.db','seed'],['sibling-failure','data.db','garbage'],['sibling-open-failure','data.db','open-error']]) {
    setups.push({source:'copilot',scenario,file:`${fixture('copilot')}/${scenario}/${name}`,kind:'seed',seed:`${fixture('copilot')}/sibling-data.sql`,siblings:[{file:'session-store.db',kind:sibling,seed:`${fixture('copilot')}/sibling-events.sql`}]});
  }
  return setups;
}

export function materialize(root,setup) {
  const file=resolve(root,setup.file);
  assert.ok(file.startsWith(resolve(root) + (process.platform==='win32'?'\\':'/')));
  mkdirSync(dirname(file),{recursive:true});
  let writer;
  try {
    if (setup.kind==='missing') return {file,writer};
    if (setup.kind==='open-error') mkdirSync(file);
    else if (setup.kind==='empty') writeFileSync(file,Buffer.alloc(0));
    else if (setup.kind==='garbage') writeFileSync(file,Buffer.alloc(1024,0x5a));
    else if (setup.kind.startsWith('csv')) {
      const bytes=readFileSync(join(repo,setup.input));
      writeFileSync(file,setup.kind==='csv-crlf'?Buffer.from(bytes.toString('utf8').replaceAll('\n','\r\n')):bytes);
    } else if (setup.kind.startsWith('wal-')) {
      const live=setup.kind==='wal-live';
      const path=live?file:join(root,'writers',setup.source,'source.db');
      mkdirSync(dirname(path),{recursive:true});
      writer=new DatabaseSync(path);
      writer.exec('PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0');
      writer.exec(readFileSync(join(repo,setup.seed),'utf8'));
      if (!live) {copyFileSync(path,file);copyFileSync(path+'-wal',file+'-wal');}
    } else {
      const db=new DatabaseSync(file);
      try {db.exec(setup.kind==='missing-table'?'CREATE TABLE unrelated (id)':readFileSync(join(repo,setup.seed),'utf8'));} finally {db.close();}
    }
    for (const sibling of setup.siblings || []) materialize(root,{...sibling,source:setup.source,file:join(dirname(setup.file),sibling.file)});
    return {file,writer};
  } catch (error) { writer?.close();throw error; }
}

export async function generateAdaptersB3(output,now) {
  const outputPath=resolve(output);
  const {root}=syntheticHome();
  const cwd=process.cwd();
  const rows=[{type:'context',now,tz:process.env.TZ}];
  try {
    for (const setup of scenarios()) {
      rows.push({type:'setup',...setup});
      const {file,writer}=materialize(root,setup);
      try {
        const snapshots=setup.kind.startsWith('wal-')?[file,file+'-wal'].map(p=>[p,readFileSync(p)]):[];
        process.chdir(root);
        const records=[];const notes=newNotes();
        try {
          for await (const record of adapters[setup.source](setup.file,notes)) records.push(record);
          rows.push({type:'adapter_record',source:setup.source,file:setup.file,records,notes});
          for (const record of records) rows.push({type:'identity',record,...identity(record)});
        } catch {rows.push({type:'adapter_record',source:setup.source,file:setup.file,error:true});}
        for (const [path,bytes] of snapshots) assert.deepEqual(readFileSync(path),bytes,`WAL bytes changed: ${setup.source} ${setup.kind}`);
        if (snapshots.length) assert.ok(rows.findLast(r=>r.type==='adapter_record').records?.length,`WAL row missing: ${setup.source}`);
        rows.push({type:'identity',file:setup.file,expected:fileTag(setup.file)});
      } finally {process.chdir(cwd);writer?.close();}
    }
    // The contract represents SQLite Uint8Array values as JSON byte arrays, including raw ID fields.
    writeFileSync(join(outputPath,'adapters-b3.jsonl'),rows.map(r=>JSON.stringify(r,(_key,value)=>value instanceof Uint8Array?[...value]:value)).join('\n')+'\n');
    const versionDb=new DatabaseSync(':memory:');
    try {console.log(`adapters-b3: ${rows.filter(r=>r.type==='adapter_record').length} scenarios, ${rows.filter(r=>r.type==='adapter_record').reduce((n,r)=>n+(r.records?.length||0),0)} records; SQLite ${versionDb.prepare('select sqlite_version() AS v').get().v}`);} finally {versionDb.close();}
  } finally {process.chdir(cwd);cleanup(root);}
}
