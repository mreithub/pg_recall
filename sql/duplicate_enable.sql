--
-- Creates a simple table and enables logging twice (the second call should update the interval)
--

BEGIN;
CREATE EXTENSION recall;

CREATE TABLE config (
	key VARCHAR(100) PRIMARY KEY,
	value TEXT NOT NULL
);

-- enable logging
SELECT recall_enable('config', '2 months');

-- run a cleanup to make sure last_cleanup is set
SELECT recall_cleanup_all();

-- check the config table
SELECT tblid, log_interval, now() - last_cleanup FROM _recall_config;


-- a new call to recall_enable should trigger a notice, update the interval
-- and reset last_cleanup
SELECT recall_enable('config', '3 months');
SELECT tblid, log_interval, now() - last_cleanup FROM _recall_config;

ROLLBACK;
