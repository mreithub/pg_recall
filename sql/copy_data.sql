--
-- Creates a table, inserts some data and only then calls recall.enable()
-- Then checks if all the data has been copied to the _log table correctly
--

BEGIN;

-- create simple table
CREATE TABLE config (
	key VARCHAR(100) PRIMARY KEY,
	value TEXT
);

-- fill it with some data
INSERT INTO config VALUES ('key', 'value');
INSERT INTO config VALUES ('hello', 'world');
INSERT INTO config VALUES ('answer', 42);
UPDATE config SET value = 'newValue' WHERE key = 'key';

-- enable logging
SELECT recall.enable('config', '1 day');

-- check the data
SELECT key, value, now() - _log_start AS _start, now() - _log_end AS _end FROM recall.config_log;

ROLLBACK;
