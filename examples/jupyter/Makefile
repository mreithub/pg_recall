
all: blog_tables.png blog_tables.svg

%.svg: %.dot
	dot -Tsvg -o $@ $<

%.png: %.dot
	dot -Tpng -o $@ $<
