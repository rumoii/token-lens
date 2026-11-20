CREATE TABLE local_runtime_token_usage (id,session_id,model,ts,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens);
INSERT INTO local_runtime_token_usage VALUES (1, 's', 'm', 1768478400000, 1, 2, 3, 4);
CREATE TABLE local_runtime_sessions (session_id,title);
INSERT INTO local_runtime_sessions VALUES ('s', 'ignored');
