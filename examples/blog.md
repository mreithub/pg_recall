Example: Blog
=============

This example should demonstrate a few use cases for pg_recall.
It's written in markdoen with inline SQL (all the executed statements are indented by four spaces, so you can actually run it and play around with it yourself:

```
grep '^    ' blog.md | psql <dbName>
```

To make this work, I added pipes (`|`) to the start of some output lines, but you should hardly notice that.

### But now down to business:  
We'll create three tables, two of which will be managed by pg_recall.  
Between the INSERTs/UPDATEs I've added `pg_sleep()` calls to artificially slow down the execution and to make the resulting timestamps a little more meaningful.

    CREATE EXTENSION IF NOT EXISTS recall;

    CREATE TABLE account (
      uid SERIAL PRIMARY KEY,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    
      name VARCHAR(200) NOT NULL,
      login VARCHAR(100) NOT NULL,
      password VARCHAR(200) NOT NULL,
      email VARCHAR(200) NOT NULL
    );
    CREATE UNIQUE INDEX idx_account_login ON account(lower(login));
    
    CREATE TABLE account_settings (
    uid INTEGER NOT NULL,
    key VARCHAR(100) NOT NULL,
    value TEXT NOT NULL,
    
    PRIMARY KEY (uid, key),
    FOREIGN KEY (uid) REFERENCES account(uid)
    );
    
    CREATE TABLE blog_entry (
    entry_id SERIAL PRIMARY KEY,
    creator INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    
    title VARCHAR(200) NOT NULL,
    content TEXT NOT NULL,
    
    FOREIGN KEY (creator) REFERENCES account(uid)
    );

For blog entries, we want users to be able to have a look at the canges (and revert them if needed)

    SELECT recall_enable('blog_entry', '6 months');

For account settings we use pg_recall to allow support agents to see
which settings were changed when to simplify the support process.

    SELECT recall_enable('account_settings', '1 year');


### Ok, let's pretend to be a new user who registers and creates some content (for simplicity we set the sequence values explicitly):

    INSERT INTO account (uid, name, login, password, email)
    VALUES (12, 'John Doe', 'jdoe', 'very secure password', 'jdoe@example.com')
    RETURNING uid;
    
    INSERT INTO account_settings (uid, key, value) VALUES
    (12, 'get_newsletter', true),
    (12, 'enable_spellcheck', false);
    
    
    INSERT INTO blog_entry (entry_id, creator, title, content) VALUES
    (123, 12, 'Welcome to my new bog', 'This is sooooo super exciting!'),
    (124, 12, 'House warming party', 'I want to invite you all to my house warming party next tuesday at 123 Some Place')
    RETURNING entry_id;
    
    SELECT pg_sleep(2);

argh, typo...

    UPDATE blog_entry SET title = 'Welcome to my new blog' WHERE entry_id = 123;
    SELECT pg_sleep(2);

spell check would've helped me there...

    UPDATE account_settings SET value = true WHERE uid = 12 AND key = 'enable_spellcheck';
    SELECT pg_sleep(2);

Maybe not the best idea to invite the whole internet, let's forget about it...

    DELETE FROM blog_entry WHERE entry_id = 124;
    SELECT pg_sleep(2);


### Ok, by now we've gathered some data. Let's have a look at the tables and their contents:

```
# SELECT * FROM account;
 uid |          created_at           |   name   | login |       password       |      email       
-----+-------------------------------+----------+-------+----------------------+------------------
  12 | 2016-02-29 11:55:35.372086+01 | John Doe | jdoe  | very secure password | jdoe@example.com
(1 row)

# SELECT * FROM account_settings;
 uid |        key        | value 
-----+-------------------+-------
  12 | get_newsletter    | true
  12 | enable_spellcheck | true
(2 rows)

# SELECT * FROM blog_entry;
 entry_id | creator |          created_at          |         title          |            content             
----------+---------+------------------------------+------------------------+--------------------------------
|     123 |      12 | 2016-02-29 11:55:35.37828+01 | Welcome to my new blog | This is sooooo super exciting!
(1 row)
```

### And now for the fun stuff:

```
# SELECT * FROM account_settings_log;
 uid |        key        | value |          _log_start           |           _log_end            
-----+-------------------+-------+-------------------------------+-------------------------------
  12 | get_newsletter    | true  | 2016-02-29 11:55:35.374178+01 | 
  12 | enable_spellcheck | false | 2016-02-29 11:55:35.374178+01 | 2016-02-29 11:55:39.391432+01
  12 | enable_spellcheck | true  | 2016-02-29 11:55:39.391432+01 | 
(3 rows)
```

You can see that the enable_spellcheck setting has changed roughly four seconds after it was created.

All the log entries with `_log_end IS NULL` are still active, all the others have been replaced by newer ones (or deleted, as we can see in the `blog_entry` log)

```
# SELECT * FROM blog_entry_log;
 entry_id | creator |          created_at          |         title          |                                      content                                      |          _log_start           |           _log_end            
----------+---------+------------------------------+------------------------+-----------------------------------------------------------------------------------+-------------------------------+-------------------------------
|     123 |      12 | 2016-02-29 11:55:35.37828+01 | Welcome to my new bog  | This is sooooo super exciting!                                                    | 2016-02-29 11:55:35.37828+01  | 2016-02-29 11:55:37.388632+01
|     123 |      12 | 2016-02-29 11:55:35.37828+01 | Welcome to my new blog | This is sooooo super exciting!                                                    | 2016-02-29 11:55:37.388632+01 | 
|     124 |      12 | 2016-02-29 11:55:35.37828+01 | House warming party    | I want to invite you all to my house warming party next tuesday at 123 Some Place | 2016-02-29 11:55:35.37828+01  | 2016-02-29 11:55:41.395559+01
(3 rows)
```

So far so good, but let's have a look at the `blog_entry` table as it was four seconds ago (right after we fixed the typo):

```
# SELECT * FROM blog_entry_log WHERE _log_start <= now() - interval '4 seconds' AND (_log_end IS NULL OR _log_end > now() - interval '4 seconds');
 entry_id | creator |          created_at          |         title          |                                      content                                      |          _log_start           |           _log_end            
----------+---------+------------------------------+------------------------+-----------------------------------------------------------------------------------+-------------------------------+-------------------------------
|     123 |      12 | 2016-02-29 11:55:35.37828+01 | Welcome to my new blog | This is sooooo super exciting!                                                    | 2016-02-29 11:55:37.388632+01 | 
|     124 |      12 | 2016-02-29 11:55:35.37828+01 | House warming party    | I want to invite you all to my house warming party next tuesday at 123 Some Place | 2016-02-29 11:55:35.37828+01  | 2016-02-29 11:55:41.395559+01
(2 rows)
```

### The `_recall_config` table keeps track of the managed tables:

```
# select * from _recall_config;
|     tblid       |              ts               | log_interval | last_cleanup | pkey_cols  
------------------+-------------------------------+--------------+--------------+------------
 blog_entry       | 2016-02-29 11:55:35.33653+01  | 6 mons       |              | {entry_id}
 account_settings | 2016-02-29 11:55:35.351522+01 | 1 year       |              | {uid,key}
(2 rows)
```

- `tblid` defines the database table in question
- `ts` is the time when `recall_enable()` was called first
- `log_interval` defines how long log entries are kept after they've become outdated (`recall_cleanup()` will delete all of them where `_log_end < now() - log_interval`).  
  In essence this defines how far back in time you can go.
- `last_cleanup` is set by each call to `recall_cleanup()` and helps you keep track of when each table was cleaned up.
- `pkey_cols` caches the table's primary key column names so that they don't have to be queried each time the trigger function runs.  
  In the unlikely case that you change the primary key on a table, a call to `recall_enable()` will update this (but you're pretty much on yourself if you try that. It hasn't been tested!)


You shouldn't need to edit that table yourself. The contents of `log_interval`, `last_cleanup` and `pkey_cols` are updated automatically every time you call `recall_enable()` on them (which can also be used to update the log interval).

Cleanup
-------

To clean up after you've run this example, issue the following commands:

```sql
SELECT recall_disable('account_settings'); SELECT recall_disable('blog_entry');
DROP TABLE account_settings, blog_entry, account;
DROP EXTENSION recall;
```