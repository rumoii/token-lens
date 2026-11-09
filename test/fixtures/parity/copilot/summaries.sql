CREATE TABLE sessions (id,model,total_input_tokens,total_output_tokens,total_cached_tokens,total_reasoning_tokens,created_at,updated_at);
INSERT INTO sessions VALUES (NULL, NULL, 2, 3, NULL, 1, 1768478400000, NULL);
INSERT INTO sessions VALUES ('bad', 'm', -1, '7', 'bad', 1, NULL, NULL);
INSERT INTO sessions VALUES ('zero', 'm', 0, 0, 0, 0, 1768478400000, 1768478400000);
