import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { zstdCompressSync } from 'node:zlib';
import { adapters } from '../../src/core/adapters/index.js';
import { fileTag } from '../../src/core/adapters/_lines.js';
import { newNotes } from '../../src/core/adapters/_num.js';
import { payloadHash } from '../../src/core/db/write.js';
import { decompressZstdFrames } from '../../src/core/adapters/_zstd.js';
import { identity } from './identity.mjs';

export async function generateAdapters(output, now) {
  const directory = 'test/fixtures/parity';
  const plain = readFileSync(join(directory,'codex.jsonl'));
  const midpoint = plain.indexOf(10,Math.floor(plain.length/2))+1;
  const skip = Buffer.alloc(11); skip.writeUInt32LE(0x184d2a50); skip.writeUInt32LE(3,4); skip.write('abc',8);
  const compressed = Buffer.concat([zstdCompressSync(plain.subarray(0,midpoint)),skip,zstdCompressSync(plain.subarray(midpoint))]);
  writeFileSync(join(directory,'codex.jsonl.zst'),compressed);
  const rows = [{type:'context',now,tz:process.env.TZ}];
  for (const [source,file] of [['claude',`${directory}/claude.jsonl`],['codex',`${directory}/codex.jsonl`],['codex',`${directory}/codex.jsonl.zst`],['codex','test/fixtures/codex/usage-sample.jsonl']]) {
    const notes = newNotes(); const records=[];
    for await (const record of adapters[source](file,notes)) records.push(record);
    rows.push({type:'adapter_record',source,file,records,notes});
    for (const record of records) rows.push({type:'identity',record,...identity(record)});
    rows.push({type:'identity',file,expected:fileTag(source==='codex'&&file.endsWith('.zst')?file.slice(0,-4):file)});
  }
  const streams = {multiframe:compressed, truncated:compressed.subarray(0,-1), garbage:Buffer.concat([compressed,Buffer.from('garbage')]), skippable:skip, empty:Buffer.alloc(0), short:skip.subarray(0,7)};
  for (const [name,bytes] of Object.entries(streams)) {
    writeFileSync(join(directory,`zstd-${name}.bin`),bytes);
    try { rows.push({type:'query',fn:'zstd',name,expected:decompressZstdFrames(bytes).toString('hex')}); }
    catch (error) { rows.push({type:'query',fn:'zstd',name,error:error.message}); }
  }
  writeFileSync(join(output,'adapters.jsonl'),rows.map(r=>JSON.stringify(r)).join('\n')+'\n');
  console.log(`adapters: ${rows.filter(r=>r.type==='adapter_record').reduce((n,r)=>n+r.records.length,0)} records`);
}
