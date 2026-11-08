import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

export function generateJscompatB2(output) {
  const rows = [];
  const inputs = [
    '{"z":1,"a":2,"z":3}',
    '{"z":0,"10":10,"2":2,"01":1,"4294967294":4,"4294967295":5,"-1":6,"a":7,"0":8}',
    '{"nested":{"b":1,"1":2,"a":3},"array":[{"z":0,"z":2},null,true,false]}',
    '"中文😀é\\n\\t\\r\\b\\f\\\\\\\""',
    '"\\ud800"', '"\\udfff"', '"\\ud83d\\ude00"',
    '{"\\ud800":1,"a":"\\udfff"}',
    '[0,-0,1.5,1e21,1e-7,1000000000000000100,9007199254740993,1e400]',
  ];
  for (const input of inputs) rows.push({type:'query',fn:'json',input,expected:JSON.stringify(JSON.parse(input))});
  for (const value of ["AZaz09-_.!~*'()", '中文😀 /|#?&=+', '\u0000\n\t"\\', '', '\ud800', '\udfff', 'a\ud800z']) {
    const units = Array.from({length:value.length},(_,i)=>value.charCodeAt(i));
    try { rows.push({type:'query',fn:'uri',units,expected:encodeURIComponent(value)}); }
    catch { rows.push({type:'query',fn:'uri',units,error:true}); }
  }
  writeFileSync(join(output,'jscompat-b2.jsonl'), rows.map(r=>JSON.stringify(r)).join('\n')+'\n');
}
