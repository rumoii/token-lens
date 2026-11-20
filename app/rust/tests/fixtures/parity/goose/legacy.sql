CREATE TABLE sessions (id,model_config_json,created_at,input_tokens,output_tokens,total_tokens);
INSERT INTO sessions VALUES (NULL, '{"modelId":["a","b"]}', 1768478400000, 10, 2, 999);
INSERT INTO sessions VALUES ('blob', X'7b7d', 1768478400000, 12, 3, 15);
INSERT INTO sessions VALUES ('utf8', CAST(X'ff' AS TEXT), NULL, 1, 2, 3);
