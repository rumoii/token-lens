CREATE TABLE session_message (id,session_id,type,time_created,data);
INSERT INTO session_message VALUES ('m', 's', 'assistant', 1, '{"tokens":{"input":10,"output":2,"reasoning":1,"cache":{"read":3,"write":4}},"time":{"created":1768478400000},"model":{"id":" model ","providerID":" P "}}');
CREATE TABLE session (id,title);
INSERT INTO session VALUES ('s', 'ignored');
