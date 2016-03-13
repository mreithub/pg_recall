MODULES = 
EXTENSION = recall
DATA = recall--0.9.2.sql recall--0.9--0.9.1.sql recall--0.9.1--0.9.2.sql
#DOCS = README.md
REGRESS = crud cleanup copy_data duplicate_enable duplicate_disable missing_primarykey now_issue null_logInterval
REGRESS_OPTS = --load-extension recall

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
