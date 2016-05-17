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
CREATE VIEW @extschema@._tablemapping AS
SELECT t.oid AS id, n.nspname AS schema, t.relname AS name
FROM pg_class t INNER JOIN pg_namespace n ON (t.relnamespace = n.oid);

--
-- installer function
-- 
CREATE FUNCTION enable(tbl REGCLASS, logInterval INTERVAL, tgtSchema NAME) RETURNS VOID AS $$
DECLARE
	pkeyCols NAME[];
	overlapPkeys TEXT[]; -- list of pkey checks (in the form of 'colName WITH =') to be used in the EXCLUDE constraint of the log table
	cols TEXT[];
	k NAME;

	tblSchema NAME; tblName NAME;
	prefix NAME;
	tplTable REGCLASS;
	logTable REGCLASS;
BEGIN
	-- get the schema and local table name for tbl (and construct tplTable and logTable from them)
	SELECT schema, name INTO tblSchema, tblName FROM @extschema@._tablemapping WHERE id = tbl;
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

	-- update existing entry if exists (and return in that case)
	UPDATE @extschema@._config SET log_interval = logInterval, pkey_cols = pkeyCols, last_cleanup = NULL WHERE tblid = tbl;
	IF FOUND THEN
		RAISE NOTICE '@extschema@.enable(%, %) called on an already managed table. Updating log_interval and pkey_cols, clearing last_cleanup', tbl, logInterval;
		RETURN;
	END IF;

	-- init overlapPkeys
	FOREACH k IN ARRAY pkeyCols
	LOOP
		overlapPkeys = array_append(overlapPkeys, format('%I WITH =', k));
	END LOOP;

	-- create the _tpl table (without constraints)
	EXECUTE format('CREATE TABLE %I.%I (LIKE %s)', tgtSchema, prefix||'_tpl', tbl);
	tplTable := format('%I.%I', tgtSchema, prefix||'_tpl');

	-- create the _log table
	EXECUTE format('CREATE TABLE %I.%I (
		_log_time TSTZRANGE NOT NULL DEFAULT tstzrange(now(), NULL),
		EXCLUDE USING gist (%s, _log_time WITH &&),
		CHECK (NOT isempty(_log_time))
		) INHERITS (%s)',
		tgtSchema, prefix||'_log',
		array_to_string(overlapPkeys, ', '),
		tplTable
	);
	logTable := format('%I.%I', tgtSchema, prefix||'_log');

	-- make the _tpl table the parent of the data table
	EXECUTE format('ALTER TABLE %s INHERIT %s', tbl, tplTable);

	-- set the trigger
	EXECUTE format('CREATE TRIGGER trig_recall AFTER INSERT OR UPDATE OR DELETE ON %s
		FOR EACH ROW EXECUTE PROCEDURE @extschema@._trigfn()', tbl);

	-- add config table entry
	INSERT INTO @extschema@._config (tblid, log_interval, pkey_cols, tpl_table, log_table) VALUES (tbl, logInterval, pkeyCols, tplTable, logTable);

	-- get list of columns and insert current database state into the log table
	SELECT ARRAY(
		SELECT format('%I', attname) INTO cols FROM pg_attribute WHERE attrelid = tplTable AND attnum > 0 AND attisdropped = false
	);

	EXECUTE format('INSERT INTO %s (%s) SELECT %s FROM %s',
		logTable,
		array_to_string(cols, ', '),
		array_to_string(cols, ', '),
		tbl);
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION enable(tbl REGCLASS, logInterval INTERVAL) RETURNS VOID AS $$
BEGIN
	PERFORM @extschema@.enable(tbl, logInterval, '@extschema@');
END;
$$ LANGUAGE plpgsql;

--
-- uninstaller function
--
CREATE FUNCTION disable(tbl REGCLASS) RETURNS VOID AS $$
DECLARE
	tplTable REGCLASS;
	logTable REGCLASS;

BEGIN
	-- remove config table entry (and raise an exception if there was none)
	DELETE FROM @extschema@._config WHERE tblid = tbl RETURNING tpl_table, log_table INTO tplTable, logTable;
	IF NOT FOUND THEN
		RAISE EXCEPTION 'The table "%" is not managed by pg_recall', tbl;
	END IF;

	-- drop temp view created by @extschema@.at (if it exists)
	EXECUTE format('DROP VIEW IF EXISTS %I', tbl||'_past');

	-- remove inheritance
	EXECUTE format('ALTER TABLE %s NO INHERIT %s', tbl, tplTable);

	-- drop extra tables
	EXECUTE format('DROP TABLE %s', logTable);
	EXECUTE format('DROP TABLE %s', tplTable);

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

	pkeyCols TEXT[];
	pkeyChecks TEXT[]; -- array of 'colName = $1.colName' strings
	assignments TEXT[]; -- array of 'colname = $2.colName' strings (for the UPDATE statement)
	cols TEXT[]; -- will be filled with escaped column names (in the same order as the vals below)
	vals TEXT[]; -- will contain the equivalent of NEW.<colName> for each of the columns in the _tpl table
	col TEXT; -- loop variable
	rowCount INTEGER;
	startTs TIMESTAMPTZ; -- contains the timestamp that marks the end of the old as well as the start of the new log entry; will be now() if possible or clock_timestamp() if newer log entries already exist (see #19)
BEGIN
	startTs := now();

	if TG_OP = 'UPDATE' AND OLD = NEW THEN
		RAISE INFO 'pg_recall: row unchanged, no need to write to log';
		RETURN NEW;
	END IF;

	-- Fetch the table's config
	SELECT pkey_cols, tpl_table, log_table INTO pkeyCols, tplTable, logTable FROM @extschema@._config WHERE tblid = TG_RELID;

	IF TG_OP IN ('UPDATE', 'DELETE') THEN
		-- build WHERE clauses in the form of 'pkeyCol = OLD.pkeyCol' for each of the primary key columns
		-- (they will later be joined with ' AND ' inbetween)
		FOREACH col IN ARRAY pkeyCols
		LOOP
			pkeyChecks = array_append(pkeyChecks, format('%I = $1.%I', col, col));
		END LOOP;

		-- mark old log entries as outdated
		EXECUTE format('UPDATE %s SET _log_time = tstzrange(LOWER(_log_time), now()) WHERE %s AND upper_inf(_log_time) AND LOWER(_log_time) < now()',
			logTable, array_to_string(pkeyChecks, ' AND ')) USING OLD;
		GET DIAGNOSTICS rowCount = ROW_COUNT;
		IF rowCount = 0 THEN
			-- in rare cases LOWER(_log_time) of existing entries is greater than this transaction's now() (see #19)
			-- That's why I've added the less-than check above. If no entries have been updated above, run the same statement again but use clock_timestamp() instead of now()
			-- special case: LOWER(_log_time) = now(), which indicates multiple updates within the same transaction. In that case we don't want an update here (hence the > in the above and the < in the below statement)
			startTs := clock_timestamp();
			EXECUTE format('UPDATE %s SET _log_time = tstzrange(LOWER(_log_time), $2) WHERE %s AND upper_inf(_log_time) AND LOWER(_log_time) > now()',
				logTable, array_to_string(pkeyChecks, ' AND ')) USING OLD, startTs;
			GET DIAGNOSTICS rowCount = ROW_COUNT;
			IF rowCount = 0 THEN
				-- ok, false alarm. no need to use clock_timestamp() for this log entry. Revert back to now()
				startTs := now();
			END IF;
		END IF;
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

		rowCount := 0;
		IF TG_OP = 'UPDATE' THEN
			-- We might already have created a log entry for the current transaction. In that case, update the existing one (see #16)
			EXECUTE format('UPDATE %s SET %s WHERE %s AND LOWER(_log_time) = now()',
				logTable, 
				array_to_string(assignments, ', '),
				array_to_string(pkeyChecks, ' AND ')
			) USING OLD, NEW;
			GET DIAGNOSTICS rowCount = ROW_COUNT;
		END IF;

		IF rowCount = 0 THEN
			-- create the log entry (as there was nothing to update)
			EXECUTE format('INSERT INTO %s (%s, _log_time) VALUES (%s, tstzrange($2,NULL))',
				logTable,
				array_to_string(cols, ', '),
				array_to_string(vals, ', ')
			) USING NEW, startTs;
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
BEGIN
	-- get the log table and interval (and update last_cleanup while we're at it)
	UPDATE @extschema@._config SET last_cleanup = now() WHERE tblId = tbl RETURNING log_interval, log_table INTO logInterval, logTable;

	RAISE NOTICE 'recall: Cleaning up table %', tbl;
	-- Remove old entries
	EXECUTE format('DELETE FROM %s WHERE UPPER(_log_time) < now() - $1', logTable) USING logInterval;

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
	tblName TEXT;
	tplTable REGCLASS;
	logTable REGCLASS;

	viewName NAME;
	cols TEXT[]; -- escaped list
BEGIN
	-- initialize vars
	SELECT tpl_table, log_table INTO tplTable, logTable FROM @extschema@._config WHERE tblid = tbl;
	SELECT name INTO tblName FROM @extschema@._tablemapping WHERE id = tbl;

	viewName := tblName||'_past';

	-- get (escaped) list of columns
	SELECT ARRAY(
		SELECT format('%I', attname) INTO cols FROM pg_attribute WHERE attrelid = tplTable AND attnum > 0 AND attisdropped = false
	);

	EXECUTE format('CREATE OR REPLACE TEMPORARY VIEW %I AS SELECT %s FROM %s WHERE _log_time @> %L::timestamptz',
		viewName,
		array_to_string(cols, ', '),
		logTable,
		ts
	);

	return viewName;
END;
$$ LANGUAGE plpgsql;

