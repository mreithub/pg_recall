
SVG_FILES=$(patsubst %.dot,target/%.svg,$(wildcard *.dot))
PNG_FILES=$(patsubst %.dot,target/%.png,$(wildcard *.dot))

all: target/ pics slides

pics: target/ ${SVG_FILES} ${PNG_FILES}

slidesToPdf: slides
	chromium file://$$PWD/target/presentation.slides.html?print-pdf

slides: target/presentation.slides.html

target/:
	@mkdir -p target/

target/%.svg: %.dot
	dot -Tsvg -o $@ $<

target/%.png: %.dot
	dot -Tpng -o $@ $<

target/%.slides.html: %.ipynb
	# for some reason subslides are hidden, so let's convert them to proper slides
	sed s/subslide/slide/g < $< > target/$<
	cd target/; jupyter-nbconvert --to slides $< --reveal-prefix https://cdn.jsdelivr.net/reveal.js/2.6.2
	# fix image URLs
	sed -i 's| src="target/| src="|g;s/.png/.svg/g' $@
