CREATE TABLE message (id,session_id,time_updated,time_created,data);
INSERT INTO message VALUES ('ok', 's', 1768478399999, 1768478400000, '{"type":"assistant","model":{"id":"m","providerID":" Provider "},"tokens":{"input":10,"output":2,"reasoning":1,"cache":{"read":3,"write":4}}}');
INSERT INTO message VALUES ('bad', 's', 1768478400000, 1768478400000, 'null');
