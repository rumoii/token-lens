CREATE TABLE session_message (id,session_id,type,time_created,data);
INSERT INTO session_message VALUES ('m-ledger', 's-ledger', 'assistant', 1768478400000, '{"tokens":{"input":10,"output":2,"reasoning":1,"cache":{"read":3,"write":4}},"time":{"created":1768478400000},"model":{"id":"claude-opus-5-5","providerID":"anthropic"}}');
CREATE TABLE session (id,directory);
INSERT INTO session VALUES ('s-ledger', '/srv/kilo/');
