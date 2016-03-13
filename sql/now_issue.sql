--
-- This tests if the trigger function works properly in the case of multiple changes to the same record
-- within the same transaction (and therefore with the same timestamp)
--
-- It'll create two records, then do a few kinds of upadte on them and print the results
--

BEGIN;

-- create table
CREATE TABLE foo (
	id INTEGER NOT NULL PRIMARY KEY,
	value TEXT NOT NULL,
	enabled BOOLEAN NOT NULL
);

-- enable logging
SELECT recall.enable('foo', null);

-- create records
INSERT INTO foo VALUES (1, 'hello', true);
INSERT INTO foo VALUES (2, 'world', false);

-- check log data
SELECT id, value, enabled, now()-_log_start AS _start, now() - _log_end AS _end FROM recall.foo_log ORDER BY id, _log_start;


-- update the first record (both columns in one go)
UPDATE foo SET value = 'hallo', enabled = false WHERE id = 1;

-- check log data (there should still be only one log entry for ID 1)
SELECT id, value, enabled, now()-_log_start AS _start, now() - _log_end AS _end FROM recall.foo_log WHERE id = 1 ORDER BY id, _log_start;


-- update the second record (each column separately)
UPDATE foo SET value = 'welt' WHERE id = 2;
UPDATE foo SET enabled = true WHERE id = 2;

-- check log data (there should still be only one log entry for ID 2)
SELECT id, value, enabled, now()-_log_start AS _start, now() - _log_end AS _end FROM recall.foo_log WHERE id = 2 ORDER BY id, _log_start;


-- do a global UPDATE
UPDATE foo SET enabled = NOT enabled;

-- check log data (still only two records, both of them still active)
SELECT id, value, enabled, now()-_log_start AS _start, now() - _log_end AS _end FROM recall.foo_log ORDER BY id, _log_start;


-- do a key update (in my tests this was run in order and caused no duplicate pkey issues. But if PostgreSQL somehow decided
-- to update oldId=2 before oldId=1, the UPDATE would fail. Let me know if that happens to you - I'll rewrite the test then)
UPDATE foo SET id = id-1;

-- check log data (we expect the same table as above, but the IDs decremented by one)
SELECT id, value, enabled, now()-_log_start AS _start, now() - _log_end AS _end FROM recall.foo_log ORDER BY id, _log_start;


ROLLBACK;
