-- for each managed table, this will contain an entry specifying when the table was added to pg_recall and the amount of time outdated log entries are kept
-- TODO it might be better to use relation IDs instead of the table name.
CREATE TABLE _recall_config (
	tblid REGCLASS NOT NULL PRIMARY KEY,
	ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	backlog INTERVAL NOT NULL,
	pkey_cols name[] NOT NULL
);

-- define it as config table (to include its data in pg_dump)
SELECT pg_catalog.pg_extension_config_dump('_recall_config', '');


--
-- installer function
-- 
CREATE FUNCTION recall_enable(tbl REGCLASS, backlogInterval INTERVAL) RETURNS VOID AS $$
DECLARE
	pkeyCols name[];
	pkeysEscaped text[]; -- list of escaped primary key column names (can be joined to a string using array_to_string(pkeysEscaped, ','))
	k name;
BEGIN
	-- fetch primary keys from the table schema (source: https://wiki.postgresql.org/wiki/Retrieve_primary_key_columns )
	SELECT ARRAY(
		SELECT a.attname INTO pkeyCols FROM pg_index i JOIN pg_attribute a ON (a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey))
		WHERE  i.indrelid = tbl AND i.indisprimary
	);

	-- init pkeysEscaped
	FOREACH k IN ARRAY pkeyCols
	LOOP
		pkeysEscaped = array_append(pkeysEscaped, format('%I', k));
	END LOOP;


	-- create the _tpl table (without constraints)
	EXECUTE format('CREATE TABLE %I (LIKE %I)', tbl||'_tpl', tbl);

	-- create the _log table
	EXECUTE format('CREATE TABLE %I (
		_log_start_ts TIMESTAMPTZ NOT NULL DEFAULT now(),
		_log_end_ts TIMESTAMPTZ,
		PRIMARY KEY (%s, _log_start_ts)
	) INHERITS (%I)', tbl||'_log', array_to_string(pkeysEscaped, ', '), tbl||'_tpl');

	-- make the _tpl table the default of the data table
	EXECUTE format('ALTER TABLE %I INHERIT %I', tbl, tbl||'_tpl');

	-- set the trigger
	EXECUTE format('CREATE TRIGGER trig_recall AFTER INSERT OR UPDATE OR DELETE ON %I
		FOR EACH ROW EXECUTE PROCEDURE recall_trigfn()', tbl);

	-- add config table entry
	INSERT INTO _recall_config (tblid, backlog, pkey_cols) VALUES (tbl, backlogInterval, pkeyCols);

	-- TODO insert current database state into the log table
END;
$$ LANGUAGE plpgsql;


--
-- uninstaller function
--
CREATE FUNCTION recall_disable(tbl REGCLASS) RETURNS VOID AS $$
BEGIN
	-- remove inheritance
	EXECUTE format('ALTER TABLE %I NO INHERIT %I', tbl, tbl||'_tpl');

	-- drop extra tables
	EXECUTE format('DROP TABLE %I', tbl||'_log');
	EXECUTE format('DROP TABLE %I', tbl||'_tpl');

	-- delete trigger
	EXECUTE format('DROP TRIGGER trig_recall ON %I', tbl);

	-- remove config table entry
	DELETE FROM _recall_config WHERE tblid = tbl;
END;
$$ LANGUAGE plpgsql;

--
-- Trigger function
--
CREATE OR REPLACE FUNCTION recall_trigfn() RETURNS TRIGGER AS $$
DECLARE
	pkeyCols TEXT[];
	pkeys TEXT[];
	cols TEXT[];
	vals TEXT[];
	k TEXT;
	v TEXT;
BEGIN
	IF TG_OP IN ('UPDATE', 'DELETE') THEN
		-- Get the primary key columns from the config table
		SELECT pkey_cols INTO pkeyCols FROM _recall_config WHERE tblid = TG_RELID;

		-- build WHERE clauses in the form of 'pkeyCol = OLD.pkeyCol' for each of the primary key columns
		-- (they will later be joined with ' AND ' inbetween
		FOREACH k IN ARRAY pkeyCols
		LOOP
			pkeys = array_append(pkeys, format('%I = $1.%I', k, k));
		END LOOP;

		-- mark old log entries as outdated
		EXECUTE format('UPDATE %I SET _log_end_ts = now() WHERE %s AND _log_end_ts IS NULL', TG_TABLE_NAME||'_log', array_to_string(pkeys, ' AND ')) USING OLD;
	END IF;
	IF TG_OP IN ('INSERT', 'UPDATE') THEN
		-- construct the column and value strings
		FOR k,v IN SELECT format('%I', key) AS k, format('%L', value) AS v FROM each(hstore(NEW))
		LOOP
			cols = array_append(cols, k);
			vals = array_append(vals, v);
		END LOOP;

		-- create the log entry
		EXECUTE format('INSERT INTO %I (%s) VALUES (%s)',
			TG_TABLE_NAME||'_log',
			array_to_string(cols, ', '),
			array_to_string(vals, ', '));
	END IF;
	RETURN new;
END;
$$ LANGUAGE plpgsql;


--
-- Cleanup functions (return the number of deleted rows)
--
CREATE FUNCTION recall_cleanup(tbl REGCLASS) RETURNS INTEGER AS $$
DECLARE
	backlog INTERVAL;
	rc INTEGER;
BEGIN
	-- get the backlog interval
	SELECT c.backlog INTO backlog FROM _recall_config c WHERE tblId = tbl;

	RAISE NOTICE 'recall: Cleaning up table %', tbl;
	-- Remove old entries
	EXECUTE format('DELETE FROM %I WHERE _log_end_ts < now() - $1', tbl||'_log') USING backlog;

	GET DIAGNOSTICS rc = ROW_COUNT;
	RETURN rc;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION recall_cleanup_all() RETURNS VOID AS $$
DECLARE
	tbl REGCLASS;
BEGIN
	FOR tbl in SELECT tblid FROM _recall_config
	LOOP
		PERFORM recall_cleanup(tbl);
	END LOOP;
END;
$$ LANGUAGE plpgsql;

