--
-- Creates a simple data table with the very short backlog of only '2 hours' and performs some CRUD operations on it.
-- Every now and then it'll call 'recall_cleanup_all() and check if only data that's too old 
--
-- To have somewhat predictable output, we'll run the whole test inside a transaction (which causes now() to always return the same value).
-- To simulate different batches of changes, log entries will be pushed back by an hour between changes.
--

-- Create simple key/value table
CREATE TABLE config (
	key VARCHAR(100) NOT NULL PRIMARY KEY,
	value TEXT NOT NULL
);
SELECT recall_enable('config', '2 hours');

-- start transaction
BEGIN;

-- first batch (will end up being now() - 3 hours)
INSERT INTO config (key, value) VALUES ('keyA', 'valA');
INSERT INTO config (key, value) VALUES ('keyB', 'valB');

-- 'wait' an hour
UPDATE config_log SET _log_start_ts = _log_start_ts - interval '1 hour', _log_end_ts = _log_end_ts - interval '1 hour';

-- clean up (should't affect the log data yet, so recall_cleanup() should return 0)
SELECT recall_cleanup('config');

SELECT key, value, now() - _log_start_ts AS _start, now() - _log_end_ts AS _end FROM config_log ORDER BY _log_start_ts, key;


-- second batch (will be now() - 2 hours in the end)
INSERT INTO config (key, value) VALUES ('keyC', 'valC');
UPDATE config SET value = 'valueB' WHERE key = 'keyB';

-- 'wait' another hour
UPDATE config_log SET _log_start_ts = _log_start_ts - interval '1 hour', _log_end_ts = _log_end_ts - interval '1 hour';

-- clean up again and check the data (should still return 0)
SELECT recall_cleanup('config');

SELECT key, value, now() - _log_start_ts AS _start, now() - _log_end_ts AS _end FROM config_log ORDER BY _log_start_ts, key;


-- third batch (will be now() - 1 hour)
INSERT INTO config (key, value) VALUES ('keyD', 'valD');
DELETE FROM config WHERE key = 'keyC';

-- 'wait' another hour
UPDATE config_log SET _log_start_ts = _log_start_ts - interval '1 hour', _log_end_ts = _log_end_ts - interval '1 hour';

-- clean up again and check the data (it's supposed to delete the entries where end_ts is > 2 hours, so even though some are at '2 hours' yet, it should still return 0)
SELECT recall_cleanup('config');
SELECT key, value, now() - _log_start_ts AS _start, now() - _log_end_ts AS _end FROM config_log ORDER BY _log_start_ts, key;

-- 'wait' just one more minute
UPDATE config_log SET _log_start_ts = _log_start_ts - interval '1 minute', _log_end_ts = _log_end_ts - interval '1 minute';

-- clean up again and check the data (the log entry for the record changed in the first batch should've been deleted, so we expect a return value of 1 here)
SELECT recall_cleanup('config');
SELECT key, value, now() - _log_start_ts AS _start, now() - _log_end_ts AS _end FROM config_log ORDER BY _log_start_ts, key;


ROLLBACK;
