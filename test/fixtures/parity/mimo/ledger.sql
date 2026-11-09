CREATE TABLE message (id,session_id,time_updated,time_created,data);
INSERT INTO message VALUES ('m-ledger', 's-ledger', 1768478400000, 1768478400000, '{"type":"assistant","model":{"id":"claude-opus-5-5","providerID":"anthropic"},"tokens":{"input":10,"output":2,"reasoning":1,"cache":{"read":3,"write":4}}}');
CREATE TABLE session (id,directory);
INSERT INTO session VALUES ('s-ledger', 'D:/work/ledger/');
