pg_recall
=========

`pg_recall` is a PostgreSQL extension that keeps track of changes in a separate `_log` table (one `_log` table for each managed data table). 

For CRUD queries (`SELECT`, `INSERT`, `UPDATE` and `DELETE`) this works transparently. DDL changes have to be adapted though.

To see it in action, have a look at the [`examples/`][5] directory.


What it was designed for
--------

The main goal of `pg_recall` is to provide a quick and transparent way to keep track of changes to user-edited data (to eliminate the risk of accidential deletion or modification and to provide a safe way for them to try out different settings while being able to revert to the old state if necessary).

It allows to query the individual table rows or the entire table for arbitrary timestamps (within the `logInterval` you specify for each table).

You could think of it as kind of a safety net for you and your customers (but NOT as a replacement for backups)

I'd love to see ports for other databases.

Installation and Usage
----------------------

### Requirements

- PostgreSQL (9.2 or newer, as it uses range data types)
- the `btree_gist` extension (that one requires superuser database access!)

The code is pretty standard pl/pgsql code so it should be platform independent.

### Installation

The extension can be installed by issuing `make install` (you'll have to run that as root in most cases).

After that the extension has to be enabled for each database you want to use it on:

```sql
CREATE EXTENSION IF NOT EXISTS recall WITH VERSION '0.9.5';
```

I recommend specifying the version (if you don't, the most recent version will be installed), especially before we hit 1.0 or if you're using database migration software,

### Activation

As there are some resource impacts to using `pg_recall`, you have to enable it for each table you want to use it on:

    SELECT recall.enable('tableName', 'log_interval', 'targetSchema');
    SELECT recall.enable('tableName', 'log_interval'); -- targetSchema defaults to 'recall'

so for example

    SELECT recall.enable('accounts', '6 months');

After that a trigger has been added to your `accounts` table and all changes will be logged to the automatically created `recall.accounts_log` table.

You can work with your data as you did before, no changes to the CRUD queries are necessary.

And if you want to change the log interval later on, simply invoke `recall.enable()` again (with the new interval of course). This will also update the cached primary key columns for that table and will reset the `last_cleanup` field to NULL.

#### What happens behind the scenes?

`recall.enable()` creates a `*_tpl` and a `*_log` table for each of the tables you call it for (`*` being the name of the original data table).  
Those two tables will be stored in `targetSchema` (defaults to `recall`)

The `_tpl` table serves as parent table for both the `_log` table and the original data table (See [PostgreSQL's Inheritance Documentation][1] for details).
It's created without constraints and won't contain any data (it only serves as the one table you have to apply schema changes to).

The `_log` table looks like this:

```SQL
CREATE TABLE <prefix>_log (
  _log_time TSTZRANGE NOT NULL DEFAULT tstzrange(now(), null),
  EXCLUDE USING gist (id WITH =, _log_time WITH &&) -- automatically includes all your pkey columns and prevents overlaps in your log data
  CHECK (NOT isempty(_log_time))
) INHERITS <prefix>_tpl;
```

Other than the GiST index that checks for overlaps no index constraints are defined for the `_log` table (no foreign keys and no unique or check constraints).

The GiST index will be used for all pkey- and/or timestamp related queries, so they'll be reasonably fast, but if you plan on querying based on non-primary key columns, you'll have to add your own indexes.

Not having any foreign keys also means it won't stop you from deleting previously referenced data (let's say you have an `account` and a `contract` table (and each contract references the account that created it). If you enable `pg_recall` on contract but not on account (or the log interval in account is shorter than that in contract), it's possible you have references to account IDs in contract_log that point to data that's been deleted from account and are therefore not restorable).

### Querying historic data

As mentioned before, you don't have to change any queries for current data, but if you want to have a look at past records (within the `logInterval` of course), you have to query the corresponding `_log` table.

There currently is one convenience function,  `recall.at()`. It creates a temporary view resembling the data table at any given time in the past.

But if you want to do something not covered by that function, you'll have to query the `_log` table yourself (`:ts` being the timestamp you want to query for):

    ... AND _log_time @> :ts

See PostgreSQL's [range operators][12] for details on how to query based on time.

In the following examples, `my_table` is the name of the original data table.

#### Querying past data

pg_recall provides a convenience function for querying log data from a certain moment in time: `recall.at(tblName, timestamp)`.

It'll create a temporary view with the suffix `_past` added to your data table's name that you can query exactly like the original data table.

    SELECT recall.at('my_table', now() - interval '2 months');
    SELECT * FROM my_table_past WHERE ...;

As mentioned before, the `_past` view is temporary, so it'll only be visible from the current database session (which allows you to use `recall.at()` simultaneously on the same table from different sessions).

Also, as it just creates a view, using `recall.at()` should perform roughly the same as if you were querying the `_log` table yourself.

`recall.at()` returns the name of the temporary view.

##### Querying for a key in the past

    SELECT recall.at('my_table', now() - interval '1 minute');
    SELECT * FROM my_table_past WHERE id = 5;

or alternatively (also includes the `_log_time` column)

    SELECT * FROM my_table_log WHERE id = 5 AND _log_time @> now() - interval '1 minute';


#### Listing all the changes to one key (ordered by the time they occured)

    SELECT * FROM my_table_log WHERE some_key = 'some value' ORDER BY LOWER(_log_time) DESC;

### Cleanup

Every now and then you should run `recall.cleanup('tableName')` or the more convenient

    SELECT recall.cleanup_all();

It will cycle through all managed log tables and remove all outdated log entries (with `UPPER(_log_time) < now() - logInterval` - logInterval is the interval you specified as second parameter of `recall.enable()`).

It is up to you how you want to run this cleanup job. If you don't run it, the log tables will simply keep growing. Depending on your application a simple background task might do the trick. Alternatively you could write a cron job.

### Deactivation

To disable logging for a table, simply call

    SELECT recall.disable('tableName');
    
Note: This will restore the original state of that table and drop the `*_log` table, so **all the log data for that table will be lost!**


Caveats
-------

- It adds two extra tables for each data table you enable it on. Subsequent DDL changes (i.e. `ALTER TABLE`s that add/modify or delete columns) have to be done on the `_tpl` table.
- The log table doesn't inherit the constraints (and foreign keys). So make sure you also enable recall on all referenced tables (with at least the same log interval) to avoid ending up with log entries pointing to nothing.
- The cleanup function has to be run manually (e.g. using a background task in your app or a cronjob)
- It creates copies of the whole record every time it changes, so you might not want to use it on tables that have a high churn rate or contain large BLOB data.  
  However:
  - The trigger function detects unchanged records (`UPDATE ... SET value = value`), so feel free to bulk-update larger quantities of records without filtering out unchanged ones beforehand.
  - The main issue when using pg_recall on those tables is storage. If you're ok with the storage implications, there's no reason not to use pg_recall on those tables.
- It doesn't protect the log table, so it won't protect you from accidentally (or an adversary from intentionally) tampering with the log tables.
- You might wanna think twice before changing the primary key of a table (changing their value should work, but adding/removing columns from/to the primary key is untested and will most likely break things).
- **`pg_recall` does NOT replace database backups, but that should go without saying.**  
  It can however be a reasonable simple tool to allow you or your users to view and manage changes to pretty much arbitrary data.


Wanna help?
-----------

Have a look at the [github issues page][2] and feel free to issue pull requests.

Note that I'm running the regression tests (`make installcheck`) on a 9.5 server (other versions may trigger different notices (9.1 for example prints implicit primary key creation notices))

If you plan on porting recall to another database/framework, let me know.

### Project structure

`pg_recall` tries to follow the generic structure of PostgreSQL Extensions.  
Read the [Extension manual][3] and the [Extension Build Infrastructure][4] for further details.

- `expected/*`: contains the expected output of the regression tests
- `sql/*`: contains the regression tests
- `examples/`: example projects
- `recall--0.9.5.sql`: the actual implementation
- `recall--0.9*--0.9*.sql`: update script(s)
- `recall.control`: extension control file
- `Makefile`: PGXS make file (noteworthy targets: `make install` and `make installcheck` to run the regression tests)
- `README.md`: this file
- `COPYING`: license file

License
-------

This project is licensed under the terms of the PostgreSQL license (which is similar to the MIT license; see the COPYING file for details).

Related
-------

This is a list of other projects I found doing similar things.  
Keep in mind though that for most of these I only had a quick look at how they're implemented/used, so don't count on any of the following facts to be objective or true :)

### PostgreSQL

- [TimeTravel for PostgreSQL][6] (GNU GPLv3): Similar project, everything's in the `tt` database schema, seems to store the log data a little differently though (can't really say much more about them because I've just skimmed through their documentation PDF)
- [A PL/pgSQL Trigger Procedure For Auditing][7] in the PostgreSQL docs

### Others

- Temporal queries in SQL:2011
- [Oracle FlashBack][8]
- [CouchDB's Revisions][9] Revision support is a first class citicen of CouchDB land. Revisions are identified by sequential IDs, old data can be cleaned up by "compaction"
- [EclipseLink JPA History][10]: Higher level implementation in EclipseLink (but using a lot of the same ideas).

- ...

Contact
-------

Create GitHub issues/merge requests where appropriate.

For everything else contact me on [Twitter][11] or per mail (first name @ last name .net)


[1]: http://www.postgresql.org/docs/current/static/ddl-inherit.html
[2]: https://github.com/mreithub/pg_recall/issues
[3]: http://www.postgresql.org/docs/9.4/static/extend-extensions.html
[4]: http://www.postgresql.org/docs/9.1/static/extend-pgxs.html
[5]: examples/
[6]: http://www.databtech.com/eng/index_timetravel.htm
[7]: http://www.postgresql.org/docs/current/static/plpgsql-trigger.html#PLPGSQL-TRIGGER-AUDIT-EXAMPLE
[8]: https://docs.oracle.com/cd/B28359_01/appdev.111/b28424/adfns_flashback.htm
[9]: http://docs.couchdb.org/en/1.6.1/intro/api.html#revisions
[10]: https://wiki.eclipse.org/EclipseLink/Examples/JPA/History
[11]: https://twitter.com/mreithub
[12]: http://www.postgresql.org/docs/9.2/static/functions-range.html#RANGE-OPERATORS-TABLE
