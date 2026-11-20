CREATE TABLE session_message (id,session_id,type,time_created,data);
INSERT INTO session_message VALUES (12.0, 12.0, 'assistant', 1, '{"tokens":{"input":10,"output":2,"reasoning":1,"cache":{"read":3,"write":4}},"time":{"created":1768478400000},"model":{"id":" model ","providerID":" P "}}');
INSERT INTO session_message VALUES ('m', X'3132', 'assistant', 1, '{"tokens":{"input":10,"output":2,"reasoning":1,"cache":{"read":3,"write":4}},"time":{"created":1768478400000},"model":{"id":" model ","providerID":" P "}}');
CREATE TABLE session (id,directory);
INSERT INTO session VALUES ('12', '/text-must-not-match');
INSERT INTO session VALUES (12.0, '/real-matches');
INSERT INTO session VALUES (X'3132', '/blob-matches');
