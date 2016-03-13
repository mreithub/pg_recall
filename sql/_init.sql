--
-- creates some helper functions used by the other tests
--

CREATE FUNCTION pretendToWait(intv INTERVAL) RETURNS VOID AS $$
BEGIN
	UPDATE recall.config_log SET _log_time = tstzrange(LOWER(_log_time) - intv, UPPER(_log_time) - intv);
END;
$$ LANGUAGE plpgsql;


