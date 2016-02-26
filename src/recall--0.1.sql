-- for each managed table, this will contain an entry specifying when the table was added to pg_recall and the amount of time outdated log entries are kept
-- TODO it might be better to use relation IDs instead of the table name.
CREATE TABLE _recall_config (
	table_name VARCHAR(100) NOT NULL,
	ts TIMESTAMP NOT NULL DEFAULT NOW(),
	backlog INTERVAL NOT NULL
);

-- define it as config table (to include its data in pg_dump)
SELECT pg_catalog.pg_extension_config_dump('_recall_config', '');

--
-- installer function
-- 
CREATE FUNCTION enable_recall(tblName TEXT, backlogInterval INTERVAL) RETURNS VOID AS $$
DECLARE
	pkeys TEXT[];
BEGIN
	-- get the original table's pkey cols

	-- create the _tpl table (without constraints)
	EXECUTE format('CREATE TABLE %I (LIKE %I)', tblName||'_tpl', tblName);

	-- create the _log table
	EXECUTE format('CREATE TABLE %I (
		_log_start_ts TIMESTAMP NOT NULL DEFAULT now(),
		_log_end_ts TIMESTAMP
	) INHERITS (%I)', tblName||'_log', tblName||'_tpl');

	-- make the _tpl table the default of the data table
	EXECUTE format('ALTER TABLE %I INHERIT %I', tblName, tblName||'_tpl');

	-- set the trigger
	EXECUTE format('CREATE TRIGGER trig_recall AFTER INSERT OR UPDATE OR DELETE ON %I
		FOR EACH ROW EXECUTE PROCEDURE trigfn_recall()', tblName);

	-- add config table entry
	INSERT INTO _recall_config (table_name, backlog) VALUES (tblName, backlogInterval);

	-- TODO add current database state
END;
$$ LANGUAGE plpgsql;


--
-- Trigger function
--
CREATE OR REPLACE FUNCTION trigfn_recall() RETURNS TRIGGER AS $$
DECLARE
	pkeyCols TEXT[];
	pkeys TEXT[];
	cols TEXT[];
	vals TEXT[];
	k TEXT;
	v TEXT;
BEGIN
	IF TG_OP IN ('UPDATE', 'DELETE') THEN
		-- get primary key columns (TODO move the information_schema stuff into installer function)
		IF TG_NARGS > 0 THEN
			-- Use the columns given as trigger arguments
			pkeyCols = TG_ARGV;
		ELSE
			-- fetch primary keys from the table schema (source: https://wiki.postgresql.org/wiki/Retrieve_primary_key_columns )
			SELECT ARRAY(
				SELECT a.attname INTO pkeyCols FROM pg_index i JOIN pg_attribute a ON (a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey))
				WHERE i.indrelid = TG_RELID AND i.indisprimary
			);
		END IF;

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

