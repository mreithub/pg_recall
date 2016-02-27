MODULES = 
EXTENSION = recall
DATA = recall--0.1.sql
#DOCS = README.md
REGRESS = crud cleanup copy_data duplicate_enable missing_primarykey null_logInterval

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
