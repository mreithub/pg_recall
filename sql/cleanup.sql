--
-- Creates a simple data table with the very short log interval of only '2 hours' and performs some CRUD operations on it.
-- Every now and then it'll call 'recall.cleanup_all() and check if only data that's too old 
--
-- To have somewhat predictable output, we'll run the whole test inside a transaction (which causes now() to always return the same value).
-- To simulate different batches of changes, log entries will be pushed back by an hour between changes.
--

-- start transaction
BEGIN;

-- Create simple key/value table
CREATE TABLE config (
	key VARCHAR(100) NOT NULL PRIMARY KEY,
	value TEXT NOT NULL
);
SELECT recall.enable('config', '2 hours');

-- query the config table for completeness
SELECT tblid, now() - ts AS ts, log_interval, last_cleanup, pkey_cols  from recall._config;

-- first batch (will end up being now() - 3 hours)
INSERT INTO config (key, value) VALUES ('keyA', 'valA');
INSERT INTO config (key, value) VALUES ('keyB', 'valB');

-- 'wait' an hour
UPDATE recall.config_log SET _log_start = _log_start - interval '1 hour', _log_end = _log_end - interval '1 hour';

-- clean up (should't affect the log data yet, so recall.cleanup() should return 0)
SELECT recall.cleanup('config');

SELECT key, value, now() - _log_start AS _start, now() - _log_end AS _end FROM recall.config_log ORDER BY _log_start, key;


-- second batch (will be now() - 2 hours in the end)
INSERT INTO config (key, value) VALUES ('keyC', 'valC');
UPDATE config SET value = 'valueB' WHERE key = 'keyB';

-- 'wait' another hour
UPDATE recall.config_log SET _log_start = _log_start - interval '1 hour', _log_end = _log_end - interval '1 hour';

-- clean up again and check the data (should still return 0)
SELECT recall.cleanup('config');

SELECT key, value, now() - _log_start AS _start, now() - _log_end AS _end FROM recall.config_log ORDER BY _log_start, key;


-- third batch (will be now() - 1 hour)
INSERT INTO config (key, value) VALUES ('keyD', 'valD');
DELETE FROM config WHERE key = 'keyC';

-- 'wait' another hour
UPDATE recall.config_log SET _log_start = _log_start - interval '1 hour', _log_end = _log_end - interval '1 hour';

-- clean up again and check the data (it's supposed to delete the entries where end_ts is > 2 hours, so even though some are at '2 hours' yet, it should still return 0)
SELECT recall.cleanup('config');
SELECT key, value, now() - _log_start AS _start, now() - _log_end AS _end FROM recall.config_log ORDER BY _log_start, key;

-- 'wait' just one more minute
UPDATE recall.config_log SET _log_start = _log_start - interval '1 minute', _log_end = _log_end - interval '1 minute';

-- clean up again and check the data (the log entry for the record changed in the first batch should've been deleted, so we expect a return value of 1 here)
SELECT recall.cleanup('config');
SELECT key, value, now() - _log_start AS _start, now() - _log_end AS _end FROM recall.config_log ORDER BY _log_start, key;


-- check if the last_cleanup field was updated correctly (expects to return '@ 0')
SELECT now() - last_cleanup FROM recall._config;

ROLLBACK;
