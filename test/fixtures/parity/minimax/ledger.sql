CREATE TABLE local_runtime_token_usage (id,session_id,model,ts,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens);
INSERT INTO local_runtime_token_usage VALUES (1, 'mini-ledger', 'claude-opus-5-5', 1768478400000, 100, 20, 3, 2);
CREATE TABLE local_runtime_sessions (session_id,workspace_dir);
INSERT INTO local_runtime_sessions VALUES ('mini-ledger', '/srv/mini/');
