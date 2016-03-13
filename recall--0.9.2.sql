-- for each managed table, this will contain an entry specifying when the table was added to pg_recall and the amount of time outdated log entries are kept
CREATE TABLE _config (
	tblid REGCLASS NOT NULL PRIMARY KEY,
	ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	log_interval INTERVAL,
	last_cleanup TIMESTAMPTZ,
	pkey_cols name[] NOT NULL,
	tpl_table REGCLASS NOT NULL,
	log_table REGCLASS NOT NULL
);

-- define it as config table (to include its data in pg_dump)
SELECT pg_catalog.pg_extension_config_dump('_config', '');

--
-- helper functions (and views)
--
CREATE VIEW recall._tablemapping AS
SELECT t.relfilenode AS id, n.nspname AS schema, t.relname AS name
FROM pg_class t INNER JOIN pg_namespace n ON (t.relnamespace = n.oid);

--
-- installer function
-- 
CREATE FUNCTION enable(tbl REGCLASS, logInterval INTERVAL, tgtSchema NAME) RETURNS VOID AS $$
DECLARE
	pkeyCols NAME[];
	pkeysEscaped TEXT[]; -- list of escaped primary key column names (can be joined to a string using array_to_string(pkeysEscaped, ','))
	cols TEXT[];
	k NAME;

	tblSchema NAME;
	tblName NAME;
	prefix NAME;
	tplTable REGCLASS;
	logTable REGCLASS;
BEGIN
	-- get the schema and local table name for tbl (and construct tplTable and logTable from them)
	SELECT schema, name INTO tblSchema, tblName FROM recall._tablemapping WHERE id = tbl;
	IF tblSchema = 'public' OR tblSchema = tgtSchema THEN
		prefix := tblName;
	ELSE
		prefix := tblSchema||'__'||tblName;
	END IF;

	-- fetch the table's primary key columns (source: https://wiki.postgresql.org/wiki/Retrieve_primary_key_columns )
	SELECT ARRAY(
		SELECT a.attname INTO pkeyCols FROM pg_index i JOIN pg_attribute a ON (a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey))
		WHERE  i.indrelid = tbl AND i.indisprimary
	);
	IF COALESCE(array_ndims(pkeyCols), 0) < 1 THEN
		RAISE EXCEPTION 'You need a primary key on your table if you want to use pg_recall (table: %)!', tbl;
	END IF;

	-- init pkeysEscaped
	FOREACH k IN ARRAY pkeyCols
	LOOP
		pkeysEscaped = array_append(pkeysEscaped, format('%I', k));
	END LOOP;

	-- update existing entry if exists (and return in that case)
	UPDATE @extschema@._config SET log_interval = logInterval, pkey_cols = pkeyCols, last_cleanup = NULL WHERE tblid = tbl;
	IF FOUND THEN
		RAISE NOTICE '@extschema@.enable(%, %) called on an already managed table. Updating log_interval and pkey_cols, clearing last_cleanup', tbl, logInterval;
		RETURN;
	END IF;

	-- create the _tpl table (without constraints)
	EXECUTE format('CREATE TABLE %I.%I (LIKE %I.%I)', tgtSchema, prefix||'_tpl', tblSchema, tblName);

	-- create the _log table
	EXECUTE format('CREATE TABLE %I.%I (
		_log_start TIMESTAMPTZ NOT NULL DEFAULT now(),
		_log_end TIMESTAMPTZ,
		PRIMARY KEY (%s, _log_start)
	) INHERITS (%I.%I)', tgtSchema, prefix||'_log', array_to_string(pkeysEscaped, ', '), tgtSchema, prefix||'_tpl');

	-- make the _tpl table the parent of the data table
	EXECUTE format('ALTER TABLE %I.%I INHERIT %I.%I', tblSchema, tblName, tgtSchema, prefix||'_tpl');

	-- set the trigger
	EXECUTE format('CREATE TRIGGER trig_recall AFTER INSERT OR UPDATE OR DELETE ON %I.%I
		FOR EACH ROW EXECUTE PROCEDURE @extschema@._trigfn()', tblSchema, tblName);

	-- add config table entry
	tplTable = format('%I.%I', tgtSchema, prefix||'_tpl');
	logTable = format('%I.%I', tgtSchema, prefix||'_log');
	INSERT INTO @extschema@._config (tblid, log_interval, pkey_cols, tpl_table, log_table) VALUES (tbl, logInterval, pkeyCols, tplTable, logTable);

	-- get list of columns and insert current database state into the log table
	SELECT ARRAY(
		SELECT format('%I', attname) INTO cols FROM pg_attribute WHERE attrelid = tplTable AND attnum > 0 AND attisdropped = false
	);

	EXECUTE format('INSERT INTO %I.%I (%s) SELECT %s FROM %I.%I',
		tgtSchema, prefix||'_log',
		array_to_string(cols, ', '),
		array_to_string(cols, ', '),
		tblSchema, tblName);
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION enable(tbl REGCLASS, duration INTERVAL) RETURNS VOID AS $$
BEGIN
	PERFORM @extschema@.enable(tbl, duration, '@extschema@');
END;
$$ LANGUAGE plpgsql;

--
-- uninstaller function
--
CREATE FUNCTION disable(tbl REGCLASS) RETURNS VOID AS $$
DECLARE
	tplTable REGCLASS;
	logTable REGCLASS;

	tblSchema NAME; tblName NAME;
	tplSchema NAME; tplName NAME;
	logSchema NAME; logName NAME;
BEGIN
	-- remove config table entry (and raise an exception if there was none)
	DELETE FROM @extschema@._config WHERE tblid = tbl RETURNING tpl_table, log_table INTO tplTable, logTable;
	IF NOT FOUND THEN
		RAISE EXCEPTION 'The table "%" is not managed by pg_recall', tbl;
	END IF;

	-- get schema and table names
	SELECT schema, name INTO tblSchema, tblName FROM recall._tablemapping WHERE id = tbl;
	SELECT schema, name INTO tplSchema, tplName FROM recall._tablemapping WHERE id = tplTable;
	SELECT schema, name INTO logSchema, logName FROM recall._tablemapping WHERE id = logTable;

	-- drop temp view created by @extschema@.at (if it exists)
	EXECUTE format('DROP VIEW IF EXISTS %I', tbl||'_past');

	-- remove inheritance
	EXECUTE format('ALTER TABLE %I.%I NO INHERIT %I.%I', tblSchema, tblName, tplSchema, tplName);

	-- drop extra tables
	EXECUTE format('DROP TABLE %I.%I', logSchema, logName);
	EXECUTE format('DROP TABLE %I.%I', tplSchema, tplName);

	-- delete trigger
	EXECUTE format('DROP TRIGGER trig_recall ON %I', tbl);
END;
$$ LANGUAGE plpgsql;


--
-- Trigger function
--
CREATE FUNCTION _trigfn() RETURNS TRIGGER AS $$
DECLARE
	tplTable REGCLASS;
	logTable REGCLASS;

	tblSchema NAME; tblName NAME;
	logSchema NAME; logName NAME;

	pkeyCols TEXT[];
	pkeyChecks TEXT[]; -- array of 'colName = $1.colName' strings
	assignments TEXT[]; -- array of 'colname = $2.colName' strings (for the UPDATE statement)
	cols TEXT[]; -- will be filled with escaped column names (in the same order as the vals below)
	vals TEXT[]; -- will contain the equivalent of NEW.<colName> for each of the columns in the _tpl table
	col TEXT; -- loop variable
	updateCount INTEGER;
BEGIN
	if TG_OP = 'UPDATE' AND OLD = NEW THEN
		RAISE INFO 'pg_recall: row unchanged, no need to write to log';
		RETURN NEW;
	END IF;

	-- Fetch the table's config
	SELECT pkey_cols, tpl_table, log_table INTO pkeyCols, tplTable, logTable FROM @extschema@._config WHERE tblid = TG_RELID;

	-- fetch table schema and names
	SELECT schema, name INTO tblSchema, tblName FROM recall._tablemapping WHERE id = TG_RELID;
	SELECT schema, name INTO logSchema, logName FROM recall._tablemapping WHERE id = logTable;

	IF TG_OP IN ('UPDATE', 'DELETE') THEN
		-- build WHERE clauses in the form of 'pkeyCol = OLD.pkeyCol' for each of the primary key columns
		-- (they will later be joined with ' AND ' inbetween)
		FOREACH col IN ARRAY pkeyCols
		LOOP
			pkeyChecks = array_append(pkeyChecks, format('%I = $1.%I', col, col));
		END LOOP;

		-- mark old log entries as outdated
		EXECUTE format('UPDATE %I.%I SET _log_end = now() WHERE %s AND _log_end IS NULL AND _log_start != now()',
			logSchema, logName,
			array_to_string(pkeyChecks, ' AND ')) USING OLD;
	END IF;
	IF TG_OP IN ('INSERT', 'UPDATE') THEN
		-- get all columns of the _tpl table and put them into the cols and vals arrays
		-- (source: http://dba.stackexchange.com/a/22420/85760 )
		FOR col IN SELECT attname FROM pg_attribute WHERE attrelid = tplTable AND attnum > 0 AND attisdropped = false
		LOOP
			-- for the INSERT
			cols = array_append(cols, format('%I', col));
			vals = array_append(vals, format('$1.%I', col));

			-- for the UPDATE
			assignments = array_append(assignments, format('%I = $2.%I', col, col));
		END LOOP;

		-- for UPDATE statements, check if the value's been changed before (see #16)
		updateCount := 0;
		IF TG_OP = 'UPDATE' THEN
			-- we can reuse pkeyChecks here
			EXECUTE format('UPDATE %I.%I SET %s WHERE %s AND _log_start = now()',
				logSchema, logName,
				array_to_string(assignments, ', '),
				array_to_string(pkeyChecks, ' AND ')
			) USING OLD, NEW;
			GET DIAGNOSTICS updateCount = ROW_COUNT;
		END IF;

		IF updateCount = 0 THEN
			-- create the log entry (as there was nothing to update)
			EXECUTE format('INSERT INTO %I.%I (%s) VALUES (%s)',
				logSchema, logName,
				array_to_string(cols, ', '),
				array_to_string(vals, ', ')
			) USING NEW;
		END IF;

	END IF;
	RETURN new;
END;
$$ LANGUAGE plpgsql;


--
-- Cleanup functions (return the number of deleted rows)
--
CREATE FUNCTION cleanup(tbl REGCLASS) RETURNS INTEGER AS $$
DECLARE
	logInterval INTERVAL;
	rc INTEGER;

	logTable REGCLASS;
	logSchema NAME;
	logName NAME;
BEGIN
	-- get the log table and interval (and update last_cleanup while we're at it)
	UPDATE @extschema@._config SET last_cleanup = now() WHERE tblId = tbl RETURNING log_interval, log_table INTO logInterval, logTable;

	-- resolve the log table's schema and name
	SELECT schema, name INTO logSchema, logName FROM recall._tablemapping WHERE id = logTable;

	RAISE NOTICE 'recall: Cleaning up table %', tbl;
	-- Remove old entries
	EXECUTE format('DELETE FROM %I.%I WHERE _log_end < now() - $1', logSchema, logName) USING logInterval;

	GET DIAGNOSTICS rc = ROW_COUNT;
	RETURN rc;
END;
$$ LANGUAGE plpgsql;

-- convenience cleanup function
CREATE FUNCTION cleanup_all() RETURNS VOID AS $$
DECLARE
	tbl REGCLASS;
BEGIN
	FOR tbl in SELECT tblid FROM @extschema@._config
	LOOP
		PERFORM @extschema@.cleanup(tbl);
	END LOOP;
END;
$$ LANGUAGE plpgsql;

--
-- Query past state
--
CREATE FUNCTION at(tbl REGCLASS, ts TIMESTAMPTZ) RETURNS REGCLASS AS $$
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

