--
-- Creates a managed table with a NULL log interval and makes sure it's not affected 
-- by cleanup() calls
--

BEGIN;
CREATE EXTENSION recall;

CREATE TABLE config (
	key VARCHAR(100) PRIMARY KEY,
	value TEXT NOT NULL
);

SELECT recall_enable('config', NULL);


-- run some statements
INSERT INTO config VALUES ('foo', 'bar');
INSERT INTO config VALUES ('true', false);

-- 'wait' an hour
UPDATE config_log SET _log_start = _log_start - interval '1 hour', _log_end = _log_end - interval '1 hour';

-- run some more statements
INSERT INTO config VALUES ('answer', 42);
UPDATE config SET value=true WHERE key='true';


-- cleanup (should return 0)
SELECT recall_cleanup('config');

-- and check the log data (there should be 4 rows)
SELECT key, value, _log_end IS NULL AS is_current FROM config_log;

ROLLBACK;
