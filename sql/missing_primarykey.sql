--
-- Tries to enable pg_recall on a table without primary key (which should trigger an exception)
--

BEGIN;

CREATE TABLE config (
	key VARCHAR(100) NOT NULL,
	value TEXT NOT NULL
);

SELECT recall_enable('config', null);

COMMIT;
