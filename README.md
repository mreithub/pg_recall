pg_recall
=========

`pg_recall` is a relatively small PostgreSQL extension that keeps track of changes in a separate `_log` table (one `_log` table for each managed data table). 

For CRUD queries (`SELECT`, `INSERT`, `UPDATE` and `DELETE`) this works transparently. Schema changes have to be adapted though.


What it was designed for
--------

The main goal of `pg_recall` is to provide a quick and transparent way to keep track of changes to user-edited data (to eliminate the risk of accidential deletion or modification and to provide a safe way for them to try out different settings while being able to revert to the old state if necessary).

It allows to query the individual table rows or the entire table for arbitrary timestamps (within the `logInterval` you specify for each table).

You could also see `pg_recall` as the reference implementation (the one as PostgreSQL extension) of the general `*_recall` idea.  
Apart from using (the convenient, but not mandatory) table inheritance, it should be applicable for a range of different DBMS and higher level frameworks (such as JPA/Hibernate or other ORMs), as long as they have half-decent row level trigger support.  
I'd love to see ports for other databases.

Installation and Usage
----------------------

### Requirements

All you should need is PostgreSQL (TODO: find out minimum version).

Most of the code is pretty standard pl/pgsql code so it should be platform independent.

### Installation

The extension can be installed by issuing `make install` (you'll have to run that as root in most cases).

After that the extension has to be enabled for each database you want to use it on:

```sql
CREATE EXTENSION IF NOT EXISTS recall;
```

### Activation

As there are some resource impacts to using `pg_recall`, you have to enable it for each table you want to use it on:

    SELECT recall_enable('tableName', 'retain_interval');

so for example

    SELECT recall_enable('accounts', '6 months');

After that a trigger has been added to your `accounts` table and all changes will be logged to the automatically created `accounts_log` table.

You can work with your data as you did before, no changes to the CRUD queries are necessary.

#### What happens behind the scenes?

`recall_enable()` creates a `*_tpl` and a `*_log` table for each of the tables you call it for (`*` being the name of the original data table).

The `_tpl` table serves as parent table for both the `_log` table and the original data table (See [PostgreSQL's Inheritance Documentation][1] for details).
It's created without constraints and won't contain any data (it only serves as the one table you have to apply schema changes to).

The `_log` table  pretty much is created like this:

```SQL
CREATE TABLE <name>_log (
  _log_start TIMESTAMPTZ NOT NULL DEFAULT now(),
  _log_end TIMESTAMPTZ,
  PRIMARY KEY (<primary key cols of the original data table>, _log_start)
) INHERITS <name>_tpl;
```

Apart from a primary key (which contains the same columns as the one in the data table but also adds `_log_start`), no constraints are defined for the `_log` table (no foreign keys and no unique or check constraints).

That means that primary key lookups are reasonably fast, but if you plan on doing more complex things on a regular basis, you might want to add your own private keys.

It also means it won't stop you from deleting previously referenced data (let's say you have an `account` and a `contract` table (and each contract references the account that created it). If you enable `pg_recall` on contract but not on account (or the log interval in account is shorter than that in contract), it's possible you have references to account IDs in contract_log that point to data that's been deleted from account and are therefore not restorable).

### Querying historic data

As mentioned before, querying current data doesn't change, but if you want to have a look at past records (within the `logInterval` of course), you have to query the corresponding `_log` table.

Below are some common usage examples, but basically they boil down to adding the following query condition (`:ts` being the timestamp you want to query for):

    ... AND _log_start <= :ts AND (_log_end IS NULL OR _log_end > :ts)

#### Querying for a key in the past

    SELECT * FROM my_table_log WHERE some_key = 'some_value' AND _log_start <= :ts AND (_log_end IS NULL OR _log_end > :ts)

#### Querying the complete past state of a table

    SELECT * FROM my_table_log WHERE _log_start <= :ts AND (_log_end IS NULL OR _log_end > :ts)

#### Listing all the changes to one key

    SELECT * FROM my_table_log WHERE some_key = 'some value' ORDER BY start_ts DESC;

### Cleanup

Every now and then you should run `recall_cleanup('tableName')` or the more convenient

    SELECT recall_cleanup_all();

It will cycle through all managed log tables and remove records with a `_log_end` before `now() - logInterval` (logInterval is the interval you specified as second parameter of `recall_enable()`).

It is up to you how you want to run this cleanup job. If you don't run it, the log tables will simply keep growing. Depending on your application a simple background task might do the trick. Alternatively you could write a cron job.

### Deactivation

To disable logging for a table, simply call

    SELECT recall_disable('tableName');
    
Note: This will restore the original state of that table and drop the `*_log` table, so **all the log data for that table will be lost!**


Caveats
-------

- timestamps are used to identify revisions. `now()` however will always return the same value within a transaction which has certain advantages (you can easily identify changes that have been made at the same time), but you can't modify the same records twice in the same transaction.
- It's not schema-transparent. It adds two extra tables for each data table you enable it on (and an extra `_recall_config` table). Subsequent column changes (i.e. `ALTER TABLE`s that add/modify or delete columns) have to be done on the `_tpl` table.
- The log table doesn't inherit the constraints (and foreign keys) of the data table and won't have any indexes other than the primary key. So if you want fast access to the log table, you'd have to define those yourself.
- The cleanup function has to be run manually (e.g. using a background task in your app or a cronjob)
- You shouldn't use it on tables that contain columns that change a lot (as it creates copies of the whole record every time it changes). You might want to think about splitting those columns to a separate table in that case.
- For the same reason it's not well suited for tables with large data blobs.
- It doesn't protect the log table, so it won't protect you from accidentally (or an adversary from intentionally) tampering with the log tables.
- You might wanna think twice before changing the primary key of a table.
- **`pg_recall` does NOT replace database backups, but that should go without saying.**


Wanna help?
-----------

Have a look at the [github issues page][2] and feel free to issue pull requests.

Also, if you plan on porting recall to another database/framework, let me know.

License
-------

This project is licensed under the terms of the PostgreSQL license (see the COPYING file for details).

[1]: http://www.postgresql.org/docs/current/static/ddl-inherit.html
[2]: https://github.com/mreithub/pg_recall/issues
