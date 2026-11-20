CREATE TABLE model_usage (id,session_id,model_id,provider_id,started_at,input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens);
INSERT INTO model_usage VALUES ('m', 's', 'm', NULL, 1768478400000, 10, 2, 3, 4);
CREATE TABLE session (id,title);
INSERT INTO session VALUES ('s', 'ignored');
