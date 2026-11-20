CREATE TABLE session_message (id,session_id,type,time_updated,time_created,data);
CREATE TABLE message (id,session_id,time_updated,time_created,data);
INSERT INTO message VALUES (NULL, 's', 1768478400000, 1768478400000, '{"type":null,"model":null,"tokens":{"input":10,"output":2,"reasoning":1,"cache":{"read":3,"write":4}},"role":"assistant","modelID":"old","providerID":" v1 "}');
INSERT INTO message VALUES ('', 's', 1768478400000, 1768478400000, '{"type":"assistant","model":{"id":"m","providerID":" Provider "},"tokens":{"input":10,"output":2,"reasoning":1,"cache":{"read":3,"write":4}},"id":"not-used"}');
INSERT INTO message VALUES (NULL, 's', NULL, 1768478400000, '{"type":"assistant","model":{"id":"m","providerID":" Provider "},"tokens":{"input":10,"output":2,"reasoning":1,"cache":{"read":3,"write":4}}}');
CREATE TABLE session (id,directory);
INSERT INTO session VALUES ('s', '/srv/v1/');
CREATE TABLE session_v2 (id,directory);
INSERT INTO session_v2 VALUES ('s', '/wrong-version');
