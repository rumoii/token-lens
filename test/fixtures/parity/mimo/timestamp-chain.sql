CREATE TABLE message (id,session_id,time_updated,time_created,data);
INSERT INTO message VALUES ('updated','s',1768478400000,1768478300000,'{"tokens":{"input":1},"time":{"completed":1768478200000}}');
INSERT INTO message VALUES ('created','s',0,1768478400000,'{"tokens":{"input":1},"time":{"completed":1768478200000}}');
INSERT INTO message VALUES ('completed','s',0,0,'{"tokens":{"input":1},"time":{"completed":1768478400000,"created":1768478200000}}');
INSERT INTO message VALUES ('data-created','s',0,0,'{"tokens":{"input":1},"time":{"completed":0,"created":1768478400000}}');
INSERT INTO message VALUES ('',NULL,0,0,'{"id":"must-not-use-id","sessionID":0,"session_id":0,"tokens":{"input":1},"time":{"created":1768478400000}}');
