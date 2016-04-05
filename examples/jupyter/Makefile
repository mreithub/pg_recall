
SVG_FILES=$(patsubst %.dot,target/%.svg,$(wildcard *.dot))
PNG_FILES=$(patsubst %.dot,target/%.png,$(wildcard *.dot))

all: target/ ${SVG_FILES} ${PNG_FILES}

target/:
	@mkdir -p target/

target/%.svg: %.dot
	dot -Tsvg -o $@ $<

target/%.png: %.dot
	dot -Tpng -o $@ $<
