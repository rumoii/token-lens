CREATE TABLE assistant_usage_events (id,session_id,model,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,created_at);
INSERT INTO assistant_usage_events VALUES (1, 'shared', 'm', 10, 2, 0, 0, 0, 1768478400000);
INSERT INTO assistant_usage_events VALUES (2, 'bad-fields', 'm', -1, 2, 0, 0, 0, 1768478400000);
INSERT INTO assistant_usage_events VALUES (3, 'zero', 'm', 0, 0, 0, 0, 0, 1768478400000);
INSERT INTO assistant_usage_events VALUES (4, 'no-time', 'm', 1, 2, 0, 0, 0, NULL);
