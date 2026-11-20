CREATE TABLE sessions (id,model_config_json,provider_name,created_at,input_tokens,output_tokens,total_tokens,accumulated_input_tokens,accumulated_output_tokens,accumulated_total_tokens);
INSERT INTO sessions VALUES ('z', '{"model_name":" model "}', ' provider ', 1768478400000, 10, 2, 90, 100, 20, 999);
INSERT INTO sessions VALUES ('a', '{"model":12}', NULL, 1768478400000, 12, 3, 999, NULL, NULL, NULL);
INSERT INTO sessions VALUES (NULL, '{', ' ', NULL, 10, 1, 900, NULL, NULL, NULL);
INSERT INTO sessions VALUES ('empty', '{"modelId":"   "}', NULL, 1768478400000, 1, 2, 20, NULL, NULL, NULL);
INSERT INTO sessions VALUES ('bad', '{"model_name":{"x":1}}', NULL, 'invalid', -1, '7', 100, NULL, NULL, NULL);
INSERT INTO sessions VALUES ('total-only', '{}', NULL, 1768478400000, NULL, NULL, 1000, NULL, NULL, NULL);
INSERT INTO sessions VALUES ('zero', '{}', NULL, 1768478400000, 0, 0, 9, 0, 0, 99);
