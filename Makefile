MODULES = 
EXTENSION = recall
DATA = recall--0.1.sql
#DOCS = README.md
REGRESS = crud cleanup

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
