--
-- changes:
-- - fixed PostgreSQL 9.1 compatibility (by replacing cardinality() in recall_enable())
-- - added recall_at() (and corresponding cleanup code in recall_disable()


--
-- installer function
-- 
CREATE OR REPLACE FUNCTION recall_enable(tbl REGCLASS, logInterval INTERVAL) RETURNS VOID AS $$
DECLARE
	pkeyCols name[];
	pkeysEscaped text[]; -- list of escaped primary key column names (can be joined to a string using array_to_string(pkeysEscaped, ','))
	cols text[];
	k name;
BEGIN
	-- fetch primary keys from the table schema (source: https://wiki.postgresql.org/wiki/Retrieve_primary_key_columns )
	SELECT ARRAY(
		SELECT a.attname INTO pkeyCols FROM pg_index i JOIN pg_attribute a ON (a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey))
		WHERE  i.indrelid = tbl AND i.indisprimary
	);

--	raise notice 'foo: %, %', pkeyCols, array_length(pkeyCols, 1);
	IF COALESCE(array_ndims(pkeyCols), 0) < 1 THEN
		RAISE EXCEPTION 'You need a primary key on your table if you want to use pg_recall (table: %)!', tbl;
	END IF;

	-- init pkeysEscaped
	FOREACH k IN ARRAY pkeyCols
	LOOP
		pkeysEscaped = array_append(pkeysEscaped, format('%I', k));
	END LOOP;

	-- update existing entry (and return if that was one)
	UPDATE _recall_config SET log_interval = logInterval, pkey_cols = pkeyCols, last_cleanup = NULL WHERE tblid = tbl;
	IF FOUND THEN
		RAISE NOTICE 'recall_enable(%, %) called on an already managed table. Updating log_interval and pkey_cols, clearing last_cleanup', tbl, logInterval;
		RETURN;
	END IF;

	-- add config table entry
	INSERT INTO _recall_config (tblid, log_interval, pkey_cols) VALUES (tbl, logInterval, pkeyCols);

	-- create the _tpl table (without constraints)
	EXECUTE format('CREATE TABLE %I (LIKE %I)', tbl||'_tpl', tbl);

	-- create the _log table
	EXECUTE format('CREATE TABLE %I (
		_log_start TIMESTAMPTZ NOT NULL DEFAULT now(),
		_log_end TIMESTAMPTZ,
		PRIMARY KEY (%s, _log_start)
	) INHERITS (%I)', tbl||'_log', array_to_string(pkeysEscaped, ', '), tbl||'_tpl');

	-- make the _tpl table the default of the data table
	EXECUTE format('ALTER TABLE %I INHERIT %I', tbl, tbl||'_tpl');

	-- set the trigger
	EXECUTE format('CREATE TRIGGER trig_recall AFTER INSERT OR UPDATE OR DELETE ON %I
		FOR EACH ROW EXECUTE PROCEDURE recall_trigfn()', tbl);


	-- get list of columns and insert current database state into the log table
	SELECT ARRAY(
		SELECT format('%I', attname) INTO cols FROM pg_attribute WHERE attrelid = (tbl||'_tpl')::regclass AND attnum > 0 AND attisdropped = false
	);

	EXECUTE format('INSERT INTO %I (%s) SELECT %s FROM %I',
		tbl||'_log',
		array_to_string(cols, ', '),
		array_to_string(cols, ', '),
		tbl);
END;
$$ LANGUAGE plpgsql;


--
-- uninstaller function
--
CREATE OR REPLACE FUNCTION recall_disable(tbl REGCLASS) RETURNS VOID AS $$
BEGIN
	-- remove config table entry (and raise an exception if there was none)
	DELETE FROM _recall_config WHERE tblid = tbl;
	IF NOT FOUND THEN
		RAISE EXCEPTION 'The table "%" is not managed by pg_recall', tbl;
	END IF;

	-- drop temp view created by recall_at (if it exists)
	EXECUTE format('DROP VIEW IF EXISTS %I', tbl||'_past');

	-- remove inheritance
	EXECUTE format('ALTER TABLE %I NO INHERIT %I', tbl, tbl||'_tpl');

	-- drop extra tables
	EXECUTE format('DROP TABLE %I', tbl||'_log');
	EXECUTE format('DROP TABLE %I', tbl||'_tpl');

	-- delete trigger
	EXECUTE format('DROP TRIGGER trig_recall ON %I', tbl);
END;
$$ LANGUAGE plpgsql;


--
-- Query past state
--
CREATE OR REPLACE FUNCTION recall_at(tbl REGCLASS, ts TIMESTAMPTZ) RETURNS REGCLASS AS $$
DECLARE
	viewName TEXT;
	cols TEXT[];
BEGIN
	viewName = tbl||'_past';

	-- get (escaped) list of columns
	SELECT ARRAY(
		SELECT format('%I', attname) INTO cols FROM pg_attribute WHERE attrelid = (tbl||'_tpl')::regclass AND attnum > 0 AND attisdropped = false
	);

	EXECUTE format('CREATE OR REPLACE TEMPORARY VIEW %I AS SELECT %s FROM %I WHERE _log_start <= %L AND (_log_end IS NULL OR _log_end > %L)',
		viewName,
		array_to_string(cols, ', '),
		tbl||'_log',
		ts, ts
	);

	return viewName;
END;
$$ LANGUAGE plpgsql;

