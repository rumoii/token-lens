CREATE TABLE session_message (id,session_id,type,time_updated,time_created,data);
INSERT INTO session_message VALUES ('m', 's', 'assistant', 1768478400000, 1768478400000, '{"type":"assistant","model":{"id":"m","providerID":" Provider "},"tokens":{"input":10,"output":2,"reasoning":1,"cache":{"read":3,"write":4}}}');
CREATE TABLE session (id,directory);
INSERT INTO session VALUES ('s', '/wrong-version');
