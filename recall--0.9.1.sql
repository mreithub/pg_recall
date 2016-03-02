-- for each managed table, this will contain an entry specifying when the table was added to pg_recall and the amount of time outdated log entries are kept
-- TODO it might be better to use relation IDs instead of the table name.
CREATE TABLE _recall_config (
	tblid REGCLASS NOT NULL PRIMARY KEY,
	ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	log_interval INTERVAL,
	last_cleanup TIMESTAMPTZ,
	pkey_cols name[] NOT NULL
);

-- define it as config table (to include its data in pg_dump)
SELECT pg_catalog.pg_extension_config_dump('_recall_config', '');


--
-- installer function
-- 
CREATE FUNCTION recall_enable(tbl REGCLASS, logInterval INTERVAL) RETURNS VOID AS $$
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
CREATE FUNCTION recall_disable(tbl REGCLASS) RETURNS VOID AS $$
BEGIN
	-- remove config table entry (and raise an exception if there was none)
	DELETE FROM _recall_config WHERE tblid = tbl;
	IF NOT FOUND THEN
		RAISE EXCEPTION 'The table "%" is not managed by pg_recall', tbl;
	END IF;

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
-- Trigger function
--
CREATE FUNCTION recall_trigfn() RETURNS TRIGGER AS $$
DECLARE
	pkeyCols TEXT[];
	pkeys TEXT[];
	cols TEXT[]; -- will be filled with escaped column names (in the same order as the vals below)
	vals TEXT[]; -- will contain the equivalent of NEW.<colName> for each of the columns in the _tpl table
	col TEXT; -- loop variable
BEGIN
	if TG_OP = 'UPDATE' AND OLD = NEW THEN
		RAISE INFO 'pg_recall: row unchanged, no need to write to log';
		RETURN NEW;
	END IF;
	IF TG_OP IN ('UPDATE', 'DELETE') THEN
		-- Get the primary key columns from the config table
		SELECT pkey_cols INTO pkeyCols FROM _recall_config WHERE tblid = TG_RELID;

		-- build WHERE clauses in the form of 'pkeyCol = OLD.pkeyCol' for each of the primary key columns
		-- (they will later be joined with ' AND ' inbetween)
		FOREACH col IN ARRAY pkeyCols
		LOOP
			pkeys = array_append(pkeys, format('%I = $1.%I', col, col));
		END LOOP;

		-- mark old log entries as outdated
		EXECUTE format('UPDATE %I SET _log_end = now() WHERE %s AND _log_end IS NULL', TG_TABLE_NAME||'_log', array_to_string(pkeys, ' AND ')) USING OLD;
	END IF;
	IF TG_OP IN ('INSERT', 'UPDATE') THEN
		-- get all columns of the _tpl table and put them into the cols and vals arrays
		-- (source: http://dba.stackexchange.com/a/22420/85760 )
		FOR col IN SELECT attname FROM pg_attribute WHERE attrelid = (TG_TABLE_NAME||'_tpl')::regclass AND attnum > 0 AND attisdropped = false
		LOOP
			cols = array_append(cols, format('%I', col));
			vals = array_append(vals, format('$1.%I', col));
		END LOOP;

		-- create the log entry
		EXECUTE format('INSERT INTO %I (%s) VALUES (%s)',
			TG_TABLE_NAME||'_log',
			array_to_string(cols, ', '),
			array_to_string(vals, ', ')) USING NEW;
	END IF;
	RETURN new;
END;
$$ LANGUAGE plpgsql;


--
-- Cleanup functions (return the number of deleted rows)
--
CREATE FUNCTION recall_cleanup(tbl REGCLASS) RETURNS INTEGER AS $$
DECLARE
	logInterval INTERVAL;
	rc INTEGER;
BEGIN
	-- get the log interval (and update last_cleanup while we're at it)
	UPDATE _recall_config SET last_cleanup = now() WHERE tblId = tbl RETURNING log_interval INTO logInterval;
	--SELECT log_interval INTO logInterval FROM _recall_config c WHERE tblId = tbl;

	RAISE NOTICE 'recall: Cleaning up table %', tbl;
	-- Remove old entries
	EXECUTE format('DELETE FROM %I WHERE _log_end < now() - $1', tbl||'_log') USING logInterval;

	GET DIAGNOSTICS rc = ROW_COUNT;
	RETURN rc;
END;
$$ LANGUAGE plpgsql;

-- convenience cleanup function
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

