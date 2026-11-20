CREATE TABLE session_model_usage (session_id,model,input_tokens,output_tokens,last_seen);
CREATE TABLE sessions (id,model,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,last_activity_at);
INSERT INTO sessions VALUES (NULL, NULL, 2, 3, 1, 0, 1768478400000);
INSERT INTO sessions VALUES ('zero', 'm', 0, 0, 0, 0, 1768478400000);
INSERT INTO sessions VALUES ('b', 'm', 1, 2, NULL, NULL, 1768478400000);
