CREATE TABLE IF NOT EXISTS usage_timings (
  record_key TEXT PRIMARY KEY REFERENCES usage_records(record_key),
  source TEXT NOT NULL,
  ttft_ms INTEGER CHECK(ttft_ms >= 0),
  ttft_method TEXT CHECK(ttft_method IN ('client_reported','log_timestamps','content_event_proxy')),
  generation_ms INTEGER CHECK(generation_ms >= 0),
  generation_method TEXT CHECK(generation_method IN ('client_reported','log_timestamps','content_event_proxy')),
  duration_ms INTEGER CHECK(duration_ms > 0),
  duration_method TEXT CHECK(duration_method IN ('client_reported','log_timestamps','content_event_proxy')),
  timing_output_tokens INTEGER CHECK(timing_output_tokens >= 0),
  scope TEXT NOT NULL CHECK(scope IN ('request','turn')),
  status TEXT NOT NULL CHECK(status IN ('completed','partial','failed','cancelled','unknown')),
  source_file TEXT,
  parser_rev INTEGER, -- TIMING_REV, independent of usage_records.parser_rev
  timing_hash TEXT NOT NULL
);
