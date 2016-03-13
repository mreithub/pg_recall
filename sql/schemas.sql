--
-- Creates a test schema and a couple of tables, then enables recall on them (some of them locally,
-- some of them in the recall schema) and makes sure they're prefixed correctly
--

CREATE SCHEMA mySchema;

CREATE TABLE foo (
	id SERIAL PRIMARY KEY
);

CREATE TABLE hello (
	world SERIAL PRIMARY KEY
);

CREATE TABLE mySchema.bar (
	otherId SERIAL PRIMARY KEY
);

CREATE TABLE mySchema.account (
	uid SERIAL PRIMARY KEY
);

-- The first two log tables will be stored to the 'recall' schema implicitly
SELECT recall.enable('foo', '3 months');
SELECT recall.enable('mySchema.bar', '4 months');

-- The other two will be stored locally
SELECT recall.enable('hello', '5 months', 'public');
SELECT recall.enable('mySchema.account', '6 months', 'myschema');

-- expected log table name (same goes for the _tpl table):
-- - foo:     recall.foo_log
-- - hello:   hello_log
-- - bar:     recall.mySchema__bar_log
-- - account: mySchema.account_log
\dt

\dt mySchema.*

\dt recall.*


-- check the contents of the recall._config table:
SELECT tblid, log_interval, last_cleanup, pkey_cols, tpl_table, log_table FROM recall._config;
