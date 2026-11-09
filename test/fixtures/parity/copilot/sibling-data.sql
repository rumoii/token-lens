CREATE TABLE sessions (id,model,total_input_tokens,total_output_tokens,total_cached_tokens,total_reasoning_tokens,created_at,updated_at);
INSERT INTO sessions VALUES ('shared', 'm', 999, 999, 0, 0, 1768478400000, 1768478400000);
INSERT INTO sessions VALUES ('unique', 'm', 10, 2, 0, 0, 1768478400000, 1768478400000);
INSERT INTO sessions VALUES ('no-time', 'm', 3, 4, 0, 0, 1768478400000, 1768478400000);
