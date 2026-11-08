import {PARSER_REV, parserRevOf} from '../../src/core/adapters/index.js';
import {writeFileSync} from 'node:fs';
import {join} from 'node:path';
export function generateParserRev(output) {writeFileSync(join(output,'parser-rev.jsonl'), [...Object.entries(PARSER_REV),['unregistered',parserRevOf('unregistered')]].map(([source,expected])=>JSON.stringify({type:'query',source,expected})).join('\n')+'\n');}
