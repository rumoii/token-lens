import { mkdirSync, writeFileSync, statSync, rmSync, realpathSync } from 'node:fs';
import { join, relative, dirname, basename, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import assert from 'node:assert/strict';
import { syntheticHome } from './isolation.mjs';
import { discoverAll } from '../../src/core/discovery.js';

export const sources = ['hermes','cursor','opencode','kilo','goose','zed','copilot','mimo','minimax','zcode','anythingllm'];
export function cleanup(root) {
  assert.equal(dirname(resolve(root)), realpathSync(tmpdir()));
  assert.equal(realpathSync(root), resolve(root));
  assert.ok(basename(root).startsWith('token-lens-d31-ingest-'));
  rmSync(root, { recursive: true, force: true });
}

export function generateDiscoveryB3(output) {
  const rows = [];
  const cases = [['default', {}]];
  for (const key of ['APPDATA','LOCALAPPDATA','XDG_DATA_HOME','OPENCODE_DB','KILO_DB','MIMOCODE_HOME','MIMOCODE_DB','MINIMAX_DATA_DIR','COPILOT_HOME','GOOSE_PATH_ROOT','ZCODE_DATA_BASE_DIR','ZCODE_SESSION_DB_PATH','ZCODE_SESSION_DB']) {
    for (const value of ['absolute','relative','empty','memory']) cases.push([`${key}-${value}`, { [key]: value }]);
  }
  for (const flag of ['false','FaLsE','0','true','1','','relative',':memory:']) cases.push([`channels-${flag}`, {MIMOCODE_DISABLE_CHANNEL_DB:{literal:flag}}]);
  cases.push(['opencode-crlf', { OPENCODE_DB:{literal:'opencode.db\r\n'} }], ['xdg-crlf', {XDG_DATA_HOME:'crlf'}], ['appdata-crlf',{APPDATA:'crlf'}], ['localappdata-crlf',{LOCALAPPDATA:'crlf'}]);
  for (const config of ['absolute','relative','tilde','empty','null','bad','duplicate']) cases.push([`zcode-config-${config}`, {}, config]);
  for (const key of ['OPENCODE_DB','KILO_DB','MIMOCODE_DB','ZCODE_SESSION_DB_PATH','ZCODE_SESSION_DB']) cases.push([`${key}-forward`,{[key]:{home:'override/custom.db',slashes:'forward'}}]);
  for (const key of ['ZCODE_SESSION_DB_PATH','ZCODE_SESSION_DB']) cases.push([`${key}-tilde`,{ZCODE_DATA_BASE_DIR:'absolute',[key]:{literal:'~/extra.db'}}]);
  cases.push(['zcode-base-crlf',{ZCODE_DATA_BASE_DIR:{home:'override',suffix:'\r\n'}}],['zcode-db-crlf',{ZCODE_SESSION_DB_PATH:{home:'override/custom.db',suffix:'\r\n'}}]);
  for (const [scenario, overrides, config] of cases) {
    const {home,root} = syntheticHome();
    try {
      const files = [
        'LOCALAPPDATA/hermes/state.db','AppData/Local/hermes/state.db','.hermes/state.db',
        'APPDATA/Cursor/User/globalStorage/state.vscdb','AppData/Roaming/Cursor/User/globalStorage/state.vscdb','a-cursor.csv','b-CURSOR.CSV',
        'XDG_DATA_HOME/opencode/opencode.db','XDG_DATA_HOME/opencode/custom.db','.local/share/opencode/opencode.db','.local/share/opencode/custom.db','.opencode/opencode.db',
        'XDG_DATA_HOME/kilo/kilo.db','XDG_DATA_HOME/kilo/custom.db','.local/share/kilo/kilo.db','.local/share/kilo/custom.db',
        'XDG_DATA_HOME/mimocode/mimocode.db','XDG_DATA_HOME/mimocode/mimocode-alpha.db','XDG_DATA_HOME/mimocode/mimocode-beta.db','XDG_DATA_HOME/mimocode/custom.db',
        '.local/share/mimocode/mimocode.db','.local/share/mimocode/mimocode-alpha.db','.local/share/mimocode/custom.db',
        'APPDATA/Xiaomi MiMo/mimocode/mimocode.db','AppData/Roaming/Xiaomi MiMo/mimocode/mimocode.db',
        'APPDATA/goose/sessions/sessions.db','AppData/Roaming/goose/sessions/sessions.db','LOCALAPPDATA/block/goose/data.db','AppData/Local/block/goose/data.db','.goose/data/sessions/sessions.db',
        'LOCALAPPDATA/Zed/threads/threads.db','AppData/Local/Zed/threads/threads.db','.local/share/zed/threads/threads.db',
        '.copilot/session-store.db','.copilot/data.db','.minimax/v2/sqlite/runtime-state.sqlite','.minimax-a/v2/sqlite/runtime-state.sqlite','.minimax-b/v2/sqlite/runtime-state.sqlite',
        '.zcode/cli/db/db.sqlite','APPDATA/anythingllm-desktop/storage/anythingllm.db','AppData/Roaming/anythingllm-desktop/storage/anythingllm.db',
        'override/custom.db','override/data/mimocode.db','override/data/mimocode-alpha.db','override/session-store.db','override/data.db','override/data/sessions/sessions.db','override/v2/sqlite/runtime-state.sqlite',
        'override/.zcode/cli/db/db.sqlite','override/extra.db','settings/.zcode/cli/db/db.sqlite','settings/extra.db','extra.db',
        'override/opencode/opencode.db','override/kilo/kilo.db','override/mimocode/mimocode.db',
        'override/hermes/state.db','override/Zed/threads/threads.db','override/block/goose/data.db',
        'override/Cursor/User/globalStorage/state.vscdb','override/goose/sessions/sessions.db','override/anythingllm-desktop/storage/anythingllm.db'
      ];
      const directories = ['XDG_DATA_HOME/mimocode/mimocode-dir.db','.minimax-dir/v2/sqlite/runtime-state.sqlite','directory-cursor.csv'];
      for (const file of files) { const path=join(home,file); mkdirSync(dirname(path),{recursive:true}); writeFileSync(path,'{}'); }
      for (const dir of directories) mkdirSync(join(home,dir),{recursive:true});
      const env = {APPDATA:'APPDATA',LOCALAPPDATA:'LOCALAPPDATA',XDG_DATA_HOME:'XDG_DATA_HOME'};
      for (const [key, kind] of Object.entries(overrides)) {
        if (typeof kind === 'object') env[key]=kind;
        else if (kind === 'empty') env[key]={literal:''};
        else if (kind === 'memory') env[key]={literal:':memory:'};
        else if (kind === 'relative') env[key]={literal: ['OPENCODE_DB','KILO_DB','MIMOCODE_DB'].includes(key) ? 'custom.db' : 'relative'};
        else if (kind === 'crlf') env[key]={home:key,suffix:'\r\n'};
        else env[key]=['OPENCODE_DB','KILO_DB','MIMOCODE_DB','ZCODE_SESSION_DB_PATH','ZCODE_SESSION_DB'].includes(key) ? 'override/custom.db' : 'override';
      }
      const json = [];
      if (config) {
        const value = ['absolute','tilde'].includes(config) ? {home:'settings'} : config === 'duplicate' ? {home:''} : {literal: config === 'null' ? null : config === 'empty' ? '' : 'relative'};
        json.push({file:'.zcode/v2/setting.json', value:config === 'bad' ? '{bad' : {dataBaseDir:value}});
        for (const base of ['', 'settings', 'override']) json.push({file:join(base,'.zcode/cli/config.json').replaceAll('\\','/'), value:config === 'bad' ? 'null' : {storage:{sessionDbPath:config === 'tilde' ? {literal:'~/extra.db'} : config === 'absolute' ? {home:join(base,'extra.db')} : config === 'duplicate' ? {home:'extra.db'} : value}}});
        if (config==='duplicate') Object.assign(env,{ZCODE_DATA_BASE_DIR:'',ZCODE_SESSION_DB_PATH:'extra.db',ZCODE_SESSION_DB:'extra.db'});
      }
      const expand = v => {
        if (v && typeof v === 'object' && Object.hasOwn(v,'home')) {const path=join(home,v.home) + (v.suffix || '');return v.slashes==='forward'?path.replaceAll('\\','/'):path;}
        if (v && typeof v === 'object' && Object.hasOwn(v,'literal')) return v.literal;
        if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k,x])=>[k,expand(x)]));
        return v;
      };
      for (const entry of json) {const target=join(home,entry.file);mkdirSync(dirname(target),{recursive:true});writeFileSync(target,typeof entry.value === 'string'?entry.value:JSON.stringify(expand(entry.value)));}
      for (const [key,value] of Object.entries(env)) process.env[key]=typeof value === 'string'?join(home,value):expand(value);
      const found=discoverAll();
      const expected=Object.fromEntries(sources.map(source=>[source,found[source].filter(f=>statSync(f).isFile()).map(f=>relative(home,f).replaceAll('\\','/'))]));
      const identity_suffixes=Object.fromEntries(sources.map(source=>[source,found[source].filter(f=>statSync(f).isFile()).map(f=>f.slice(home.length))]));
      rows.push({type:'query',scenario,platform:process.platform,files,directories,env,json,expected,identity_suffixes});
    } finally { cleanup(root); }
  }
  writeFileSync(join(output,'discovery-b3.jsonl'),rows.map(r=>JSON.stringify(r)).join('\n')+'\n');
  console.log(`discovery-b3: ${rows.length} scenarios`);
}
