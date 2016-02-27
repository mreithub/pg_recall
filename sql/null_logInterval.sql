--
-- Creates a managed table with a NULL log interval and makes sure it's not affected 
-- by cleanup() calls
--

CREATE TABLE config (
	name VARCHAR(100) PRIMARY KEY,
	value TEXT NOT NULL
);

SELECT recall_enable('config', NULL);


-- run some statements
INSERT INTO config VALUES ('foo', 'bar');
INSERT INTO config VALUES ('true', false);
INSERT INTO config VALUES ('answer', 42);

UPDATE config SET value=true WHERE key='true';


-- cleanup (should return 0)
SELECT recall_cleanup('config');

-- and check the log data (there should be 4 rows)
SELECT key, value, _log_end IS NULL AS is_current FROM config_log;

