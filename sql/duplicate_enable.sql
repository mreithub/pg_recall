--
-- Creates a simple table and enables logging twice (the second call should update the interval)
--

BEGIN;

CREATE TABLE config (
	key VARCHAR(100) PRIMARY KEY,
	value TEXT NOT NULL
);

-- enable logging
SELECT recall.enable('config', '2 months');

-- run a cleanup to make sure last_cleanup is set
SELECT recall.cleanup_all();

-- check the config table
SELECT tblid, log_interval, now() - last_cleanup FROM recall._config;


-- a new call to recall.enable should trigger a notice, update the interval
-- and reset last_cleanup
SELECT recall.enable('config', '3 months');
SELECT tblid, log_interval, now() - last_cleanup FROM recall._config;

ROLLBACK;
