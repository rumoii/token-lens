CREATE TABLE session_model_usage (session_id,model,input_tokens,output_tokens,last_seen);
INSERT INTO session_model_usage VALUES ('zero','m',0,0,1768478400000);
CREATE TABLE sessions (id,model,input_tokens,output_tokens,started_at);
INSERT INTO sessions VALUES ('must-not-fallback','m',10,2,1768478400000);
