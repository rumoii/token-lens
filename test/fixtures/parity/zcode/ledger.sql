CREATE TABLE model_usage (id,session_id,model_id,provider_id,started_at,input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens);
INSERT INTO model_usage VALUES ('z-ledger', 's-ledger', 'claude-opus-5-5', 'anthropic', 1768478400000, 100, 20, 3, 2);
CREATE TABLE session (id,directory);
INSERT INTO session VALUES ('s-ledger', '/srv/zcode/');
