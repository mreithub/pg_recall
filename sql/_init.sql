--
-- creates some helper functions used by the other tests
--

CREATE FUNCTION pretendToWait(intv INTERVAL) RETURNS VOID AS $$
BEGIN
	UPDATE recall.config_log SET _log_start = _log_start - intv, _log_end = _log_end - intv;
END;
$$ LANGUAGE plpgsql;


