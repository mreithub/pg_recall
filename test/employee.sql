-- Creates an 'employee' table that's already in the right format

BEGIN;

CREATE TABLE employee_tpl (
	uid SERIAL NOT NULL,
	name VARCHAR(100) NOT NULL,
	hire_date TIMESTAMP NOT NULL DEFAULT now(),
	salary INTEGER
);

-- actual data table
CREATE TABLE employee (
	PRIMARY KEY (uid)
) INHERITS(employee_tpl);

-- log table
CREATE TABLE employee_log (
	_log_ts TIMESTAMP NOT NULL DEFAULT now(),
	_log_end_ts TIMESTAMP, -- default: NULL

	PRIMARY KEY (uid, _log_ts)
) INHERITS (employee_tpl);

-- create trigger
DROP TRIGGER IF EXISTS trig_employee_log ON employee;
CREATE TRIGGER trig_employee_log AFTER INSERT OR UPDATE OR DELETE ON employee
FOR EACH ROW EXECUTE PROCEDURE trigfn_chronos();

-- first insert a few records
INSERT INTO employee(name, salary) VALUES ('John Doe', 12);
INSERT INTO employee(name, salary) VALUES ('Jane Doe', 23);

-- give john a raise
UPDATE employee SET salary = 13 WHERE name = 'John Doe';

-- employ a temp
INSERT INTO employee(name, salary) VALUES ('Tem P.', 1);

-- fix a typo
UPDATE employee SET name = 'Tom P.' WHERE name = 'Tem P.';

-- fire the temp
DELETE FROM employee WHERE name = 'Tom P.';

ROLLBACK;
