--
-- Trigger function (added the old=new check)
--
CREATE OR REPLACE FUNCTION recall_trigfn() RETURNS TRIGGER AS $$
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


