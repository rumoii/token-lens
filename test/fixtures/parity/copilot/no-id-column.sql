CREATE TABLE assistant_usage_events (session_id,model,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,created_at);
INSERT INTO assistant_usage_events VALUES ('s', 'm', 1, 2, NULL, NULL, NULL, 1768478400000);
INSERT INTO assistant_usage_events VALUES ('s', 'm', 0, 0, 0, 0, 0, 1768478400000);
INSERT INTO assistant_usage_events VALUES ('s', 'm', 3, 4, NULL, NULL, NULL, 1768478400000);
