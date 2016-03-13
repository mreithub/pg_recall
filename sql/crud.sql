--
-- This test creates a simple table and performs some INSERT/UPDATE/DELETE statements on it.
-- After each of those statements it checks the contents of the config and the config_log tables
--

-- we'll do all of this in a transaction to have somewhat predictable now() values
-- whenever we UPDATE values, we'll first move _log_start and _log_end one hour in the past in the log table.
BEGIN;


-- create a simple key/value table
CREATE TABLE config (
	key VARCHAR(100) PRIMARY KEY,
	value TEXT NOT NULL
);

-- enable pg_recall and configure it to store data for three months
SELECT recall.enable('config', '3 months');

-- insert a few values
INSERT INTO config (key, value) VALUES ('enable_something', 'true');
INSERT INTO config (key, value) VALUES ('some_number', '42');

-- check the data; log table:
--  - there has to be exactly one entry for each data table entry
--  - _start is '@ 0' in both cases
--  - _end is null
SELECT key, value FROM config ORDER BY key;
SELECT key, value, now() - _log_start AS _start, now() - _log_end AS _end FROM recall.config_log ORDER BY _log_start, key;


-- update value (to work around the now() issue manually set the log values back one hour)
UPDATE recall.config_log SET _log_start = _log_start - interval '1 hour', _log_end = _log_end - interval '1 hour';
UPDATE config SET value = 'false' WHERE key = 'enable_something';

-- if we didn't check for duplicates, this would fail (due to the same record being logged twice at the same time)
UPDATE config SET value = 'false' WHERE key = 'enable_something';

-- check data and log tables. The log table...
--  - now has three entries (two for the 'enable_something' key)
--  - start is '@ 0' for the new log entry and '1 hour' for the others
--  - end is '@ 0' for the old 'enable_something' value and NULL for all the others
SELECT key, value FROM config ORDER BY key;
SELECT key, value, now() - _log_start AS _start, now() - _log_end AS _end FROM recall.config_log ORDER BY _log_start, key;


-- do a bulk key update (the equivalent to deleting all entries and creating new ones)
UPDATE recall.config_log SET _log_start = _log_start - interval '1 hour', _log_end = _log_end - interval '1 hour';
UPDATE config SET key = key||'_';

SELECT key, value FROM config ORDER BY key;
SELECT key, value, now() - _log_start AS _start, now() - _log_end AS _end FROM recall.config_log ORDER BY _log_start, key;


-- delete an entry (again after pushing log entries back one hour)
UPDATE recall.config_log SET _log_start = _log_start - interval '1 hour', _log_end = _log_end - interval '1 hour';
DELETE FROM config WHERE key = 'some_number_';

SELECT key, value FROM config ORDER BY key;
SELECT key, value, now() - _log_start AS _start, now() - _log_end AS _end FROM recall.config_log ORDER BY _log_start, key;


-- query the log table for the current state (for an easy way to compare it to the data table)
SELECT key, value FROM recall.config_log WHERE _log_start <= now() AND (_log_end IS NULL OR _log_end > now()) ORDER BY key;
SELECT key, value FROM config ORDER BY key;

-- query the log table for the state of one hour ago:
SELECT key, value FROM recall.config_log WHERE _log_start <= now() - interval '1 hour' AND (_log_end IS NULL OR _log_end > now() - interval '1 hour') ORDER BY key;

-- query the log table for the state of one hour and one minute ago:
SELECT key, value FROM recall.config_log WHERE _log_start <= now() - interval '61 minutes' AND (_log_end IS NULL OR _log_end > now() - interval '61 minutes') ORDER BY key;

-- list all the changes to the 'enable_something' record
SELECT key, value, now() - _log_start AS _start, now() - _log_end AS _end FROM recall.config_log WHERE key = 'enable_something' ORDER BY _log_start, key;
ROLLBACK;
