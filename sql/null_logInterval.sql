--
-- Creates a managed table with a NULL log interval and makes sure it's not affected 
-- by cleanup() calls
--

BEGIN;

CREATE TABLE config (
	key VARCHAR(100) PRIMARY KEY,
	value TEXT NOT NULL
);

SELECT recall.enable('config', NULL);


-- run some statements
INSERT INTO config VALUES ('foo', 'bar');
INSERT INTO config VALUES ('true', false);

-- 'wait' an hour
SELECT pretendToWait('1 hour');

-- run some more statements
INSERT INTO config VALUES ('answer', 42);
UPDATE config SET value=true WHERE key='true';


-- cleanup (should return 0)
SELECT recall.cleanup('config');

-- and check the log data (there should be 4 rows)
SELECT key, value, UPPER(_log_time) IS NULL AS is_current FROM recall.config_log;

ROLLBACK;
