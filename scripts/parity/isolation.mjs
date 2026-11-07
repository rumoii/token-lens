import { mkdtempSync, mkdirSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';
import assert from 'node:assert/strict';

export function syntheticHome() {
  const root=mkdtempSync(join(tmpdir(),'token-lens-d31-ingest-'));
  const home=join(root,'home');
  for (const key of ['HOME','USERPROFILE']) process.env[key]=home;
  for (const key of ['APPDATA','LOCALAPPDATA','XDG_DATA_HOME']) process.env[key]=join(home,key);
  for (const key of ['DB_PATH','TOKEN_LENS_DATA_DIR','OPENCODE_DB','KILO_DB','MIMOCODE_HOME','MIMOCODE_DB','MIMOCODE_DISABLE_CHANNEL_DB','KIMI_SHARE_DIR','OPENHANDS_CONVERSATIONS_DIR','OPENHANDS_PERSISTENCE_DIR','ZCODE_DATA_BASE_DIR','ZCODE_SESSION_DB_PATH','ZCODE_SESSION_DB','MINIMAX_DATA_DIR','GEMINI_HOME','GOOSE_PATH_ROOT','COPILOT_HOME','OPENCLAW_HOME','OPENCLAW_STATE_DIR']) delete process.env[key];
  for (const directory of [home,process.env.APPDATA,process.env.LOCALAPPDATA,process.env.XDG_DATA_HOME]) mkdirSync(directory,{recursive:true});
  assert.equal(homedir(),home);
  return {root,home};
}
