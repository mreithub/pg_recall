Specification
=============

There are several different approaches to keeping track of database changes. This document describes the one chosen for `pg_recall` and also tries to explain why certain choices were made.

`pg_recall` was designed to provide a simple way to keep track of changes between and jump between changes to user created data (i.e. data that only changes infrequently - what infrequently means in this context depends on how much storage you want to spend on keeping logs. Several changes a day (on a single record) shouldn't be too big a problem though)

One of the main goals of `pg_recall` is to be transparent to queries (which works well for data queries but only a certain extent for schema queries).

Most of the methods described in this document can be applied to other databases or even at a higher level (like JPA/Hibernate or other ORMs). I'd love to see ports for other databases/frameworks.

Basic Principles
----------------

- The historic data will be stored to a `_log` table (so if you enable `pg_recall` on a table named `account`, it will create an additional `account_log` table for historic data).
    - The alternative here would be to store log data inline (as in: simply add a timestamp field), but that messes up constraint validation
- The `_log` table resembles the original data table except:
    - It has two additional timestamp fields: `_log_start_ts` (not null) and `_log_end_ts` (null as long as this log entry is up to date). The advantage to using just one timestamp is that it simplifies the cleanup process and that `DELETE` statements can be represented in a cleaner way.
    - It doesn't have foreign keys and other constraints, but `NOT NULL`s are preserved.  
      That way you can remove data from referenced tables as long as there are only historic references to it (but keep in mind that you won't be able to restore a historic state referencing non-existing data).
- `pg_recall` adds a trigger function to the data table (on insert, update and delete) which automatically writes the changes to the log table
    - Update and delete will set the `_log_end_ts` of the previous matching log entry.  
      That means that for every record in the data table, there's exactly one in the log table where `_log_end_ts IS NULL`.
    - Insert and update also result in an `INSERT` to the log table
- It creates a `_recall_config` table and stores how long log entries should be retained (amongst amongst some other information).

- For PostgreSQL, it will use table inheritance: A `_tpl` table is created and serves as base table for the original data table as well as the `_log` table.
    - Column changes (adding and removing columns or changing their data type) can be done in one place (at the `_tpl` table).
    - Constraints (`UNIQUE`, `FOREIGN KEY`, `CHECK` etc.) should be applied to the  data table.


Operations
----------

- `SELECT`/`INSERT`/`UPDATE`/`DELETE` (CRUD statements) don't have to be rewritten.  
  Insert, update and delete will however alter the log table (for obvious reasons)
- `recall_enable(tableName, interval)`: Creates a `_tpl` and a `_log` table, sets the `_tpl` table as base table of the data and `_log` tables.
- `disableLog(tableName)`: drops the `_log` and `_tpl` tables of that data table (the actual data table remains mostly unaffected)
- `cleanupLog(interval)`: removes log entries that have been obsolete for longer than interval.
- `recall(timestamp, condition)`: Queries the past state of the data table (by using the log table internally).

Caveats
-------

- alter table has to be done to the `_tpl` table, if you drop columns, the log data of that column is also lost
- timestamps are used to identify revisions. `now()` however will always return the same value within a transaction which has certain advantages (you can easily identify changes that have been made at the same time), but you can't modify the same records twice in the same transaction.
- The log table doesn't inherit the constraints (and foreign keys) of the data table and won't have any indexes other than the primary key. So if you want fast access to the log table, you'd have to define those yourself.
- There's (currently?) no way to define how long log data will be stored for each table.
- The cleanup function has to be run manually (e.g. using a background task in your app or a cronjob)
- This approach doesn't work too well with data that changes a lot (which is why you have to enable it for each table you want to use it on). So if you have single fields that change a lot but want to keep track of changes on the rest of a table, you'd need to decouple those into separate tables.
- It will always store table rows, so if you have large blob columns that won't change a lot next to others that will, you might wanna think about your data model.
- modifying the primary key columns gets tricky (I'm talking about the schema, not the data)
- `pg_recall` does NOT replace database backups, but that should go without saying.

