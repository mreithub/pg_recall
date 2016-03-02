--
-- This test represents q pretty minimal setup to trigger the now() issue
-- (that prevents two or more changes to the same record within one transaction)
--
-- NOTE: This test is currently disabled because the raised error prints the current
--      timestamp (which obviously changes all the time).
--      If any of you reading this has a brilliant idea how to nicely work around this
--      feel free to contribute
--

BEGIN;

-- create table
CREATE TABLE foo (
	id INTEGER NOT NULL PRIMARY KEY,
	value TEXT NOT NULL
);

-- enable logging
SELECT recall_enable('foo', null);

-- trigger the issue (by doing an insert and an update to the same record in the same transaction)
INSERT INTO foo VALUES (1, 'hello');

UPDATE foo SET value='world' WHERE id=1;

ROLLBACK;
