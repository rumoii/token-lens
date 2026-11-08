import { mkdirSync, writeFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { syntheticHome } from './isolation.mjs';
import { discoverAll } from '../../src/core/discovery.js';
export const sources = ['claude','codex','qwen','dsh','grok','aider','pi','cline','gemini','openhands','continue','trae','openclaw','kimi','codebuddy','commandcode'];
export function generateDiscoveryB2(output) {
  const rows=[];
  for (const scenario of ['default','kimi','openhands','openclaw','relative','empty']) {
    const {home}=syntheticHome();
    const files=[
      '.claude/projects/a.jsonl','.claude/projects/.hidden/a.jsonl','.codex/sessions/rollout-a.jsonl',
      '.qwen/usage/token-usage-a.jsonl','.qwen/usage/OPUS-USAGE-B.JSONL','.qwen/usage/.hidden-usage-a.jsonl','.qwen/usage/deep/token-usage-a.jsonl',
      '.dsh/storages/session_projcache/sessions/session-a.json','.grok/sessions/a/b/updates.jsonl','.grok/sessions/a/updates.jsonl','.aider.llm.history',
      '.pi/agent/sessions/a/a.jsonl','.pi/agent/sessions/.hidden/b.jsonl',
      'APPDATA/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/task/api_conversation_history.json',
      'APPDATA/Cursor/User/globalStorage/rooveterinaryinc.roo-cline/tasks/task/api_conversation_history.json',
      '.gemini/sessions/a/a.json','.gemini/sessions/a/A.JSONL','.config/gemini/sessions/a.json',
      '.openhands/conversations/a/base_state.json','.openhands/conversations/a/subagents/b/base_state.json','.openhands/conversations/a/Subagents/c/base_state.json',
      '.continue/sessions/a.json','.continue/sessions/deep/a.json','usage-trae.json','usage-TRAE.JSONL',
      'APPDATA/TRAE SOLO/User/globalStorage/a/usage-trae.json',
      '.openclaw/agents/a/sessions/a.jsonl','.openclaw/agents/a/session-sqlite-import-archive/a.jsonl.old','.openclaw/agents/.hidden/sessions/a.jsonl',
      '.kimi-code/sessions/a/session_S/agents/a/wire.jsonl','.kimi/sessions/a.json','.kimi/logs/a/a.jsonl',
      '.codebuddy/projects/a/a.jsonl','.codebuddy/projects/subagents/a.jsonl','.codebuddy/projects/Subagents/a.jsonl','.codebuddy/projects/a/A.JSONL',
      'LOCALAPPDATA/CodeBuddyExtension/Data/history/w/c/index.json','LOCALAPPDATA/CodeBuddyExtension/Data/history/w/c/messages/index.json',
      '.commandcode/projects/a/a.jsonl','.commandcode/projects/a/a.checkpoints.jsonl','.commandcode/projects/a/a.prompts.jsonl','.commandcode/projects/a/A.CHECKPOINTS.JSONL',
      'over-kimi/sessions/a.json','over-oh/a/base_state.json','over-claw/agents/a/sessions/a.jsonl',
    ];
    const directories=['.qwen/usage/dir-usage-a.jsonl','.continue/sessions/dir.json'];
    for(const file of files) {const path=join(home,file);mkdirSync(join(path,'..'),{recursive:true});writeFileSync(path,'{}');}
    for(const dir of directories) mkdirSync(join(home,dir),{recursive:true});
    const env={APPDATA:'APPDATA',LOCALAPPDATA:'LOCALAPPDATA',XDG_DATA_HOME:'XDG_DATA_HOME'};
    if(scenario==='kimi')env.KIMI_SHARE_DIR='over-kimi';
    if(scenario==='openhands')env.OPENHANDS_CONVERSATIONS_DIR='over-oh';
    if(scenario==='openclaw')env.OPENCLAW_HOME='over-claw';
    for(const [key,value] of Object.entries(env))process.env[key]=join(home,value);
    if(scenario==='relative')for(const key of ['KIMI_SHARE_DIR','OPENHANDS_CONVERSATIONS_DIR','OPENCLAW_HOME','GEMINI_HOME']){process.env[key]='relative';env[key]={literal:'relative'};}
    if(scenario==='empty')for(const key of ['KIMI_SHARE_DIR','OPENHANDS_CONVERSATIONS_DIR','OPENCLAW_HOME']){process.env[key]='';env[key]={literal:''};}
    const found=discoverAll();
    const expected=Object.fromEntries(sources.map(source=>[source,found[source].filter(f=>statSync(f).isFile()).map(f=>relative(home,f).replaceAll('\\','/')).sort()]));
    rows.push({type:'query',scenario,files,directories,env,expected});
  }
  writeFileSync(join(output,'discovery-b2.jsonl'),rows.map(r=>JSON.stringify(r)).join('\n')+'\n');
}
