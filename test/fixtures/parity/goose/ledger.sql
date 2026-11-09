CREATE TABLE sessions (id,model_config_json,provider_name,created_at,input_tokens,output_tokens,total_tokens);
INSERT INTO sessions VALUES ('g-ledger', '{"model_name":"claude-opus-5-5"}', 'anthropic', 1768478400000, 100, 20, 999);
