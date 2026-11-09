CREATE TABLE assistant_usage_events (id,session_id,model,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,created_at);
INSERT INTO assistant_usage_events VALUES (1, 'c-ledger', 'claude-opus-5-5', 100, 20, 3, 2, 1, 1768478400000);
