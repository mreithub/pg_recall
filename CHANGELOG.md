Changelog
=========

0.9.5
-----

- version jump to indicate this version will break existing code (I really didn't want to do this, but there are a lot
  of advantages. And I've decided to put all the proposed breaking changes into a single version jump to simplify upgrades)
- The upgrade script is able to upgrade all the managed tables and functions, but you'll have to modify your code
- now requires PostgreSQL 9.2 or newer (due to the usage of range types)
- Added schema support:
  - The extension itself has been moved to the `recall` schema (and the `recall_` prefix has been removed)
  - `_log` and `_tpl` tables will now be placed into the `recall` schema (to help keeping table listings cleaner)
  - `recall.enable()` added an optional `tgtSchema` parameter (defaults to `recall`) specifying where the `_log` and `_tpl` tables will be stored.
  - `recall.enable()` prepends the data table's schema to the `_tpl` and `_log` table's names unless the data table is in `public` (or matches `tgtSchema`).  
    So `recall.enable('abc.foo', 'some interval', 'abc')` creates `abc.foo_log`, while `recall.enable('abc.foo', 'some interval')` creates `recall.abc__foo_log')
- The `now()` issue has been fixed (The trigger function is now able to update
- candidate for 1.0

Under the hood:
- replaced the two `timestamptz` columns in log tables with the single column `_log_time` of type `tstzrange`
- The OIDs of the `_log` and `_tpl` tables are now stored to `recall._config`, so you can move the tables (pg_recall will still find them)
- Added a no-overlap constraint to the `_log` tables. The resulting GiST index replaces the primary key (used up until now).  
  The GiST index allows fast lookups based on key, timestamps or both (also speeds up the `cleanup()` process)
- Added a CHECK constraint preventing empty interval log entries (which could mess up querying)

When updating:
- The extension still shows up to be installed into the `public` schema (when listing extensions e.g. using `\dx` in psql)
  even though everything's in the `recall` schema (there should be no practical differences between a fresh 0.9.5 installation
  and an upgraded one)
- all your `_log` and `_tpl` tables will be moved to the `recall` schema (the update script assumes that they've been in the `public` schema
  before as there's no real schema support in previous versions)
- replace all the function calls to any of the extension's functions
- If you rely on the log tables to have private keys (e.g. if you want to reference the log table using a foreign key - for whatever reason), add them yourselve


0.9.2
-----

- fixed PostgreSQL 9.1 compatibility (by removing a call to 9.4's cardinality() function)
- added recall_at()

0.9.1
-----

- only logging changes (i.e. checking if anything has changed and abort if it hasn't)

0.9
---

- First upgradable version
