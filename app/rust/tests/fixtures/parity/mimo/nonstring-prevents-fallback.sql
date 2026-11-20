CREATE TABLE session_message (id,session_id,type,time_updated,time_created,data);
INSERT INTO session_message VALUES ('null','s','assistant',1768478400000,NULL,NULL);
INSERT INTO session_message VALUES ('number','s','assistant',1768478400000,NULL,12);
INSERT INTO session_message VALUES ('blob','s','assistant',1768478400000,NULL,X'7b7d');
CREATE TABLE message (id,session_id,time_updated,time_created,data);
INSERT INTO message VALUES ('must-not-fallback','s',1768478400000,NULL,'{"tokens":{"input":10}}');
