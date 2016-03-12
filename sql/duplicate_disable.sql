--
-- Creates a simple table, enables logging but then disables it twice (which should raise an exception)
--

BEGIN;

CREATE TABLE config (
	key VARCHAR(100) PRIMARY KEY,
	value TEXT
);

SELECT recall.enable('config', '2 months');

SELECT recall.disable('config');

-- ok, everything should have worked as planned so far, but this next call should trigger an exception
SELECT recall.disable('config');

ROLLBACK;
