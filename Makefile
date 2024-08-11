GLEAM := $(shell which gleam)
SRCS := $(wildcard src/**/*.gleam)
PACKAGE := ./build/erlang-shipment/entrypoint.sh
RUN_SCRIPT := ./scripts/gleamfonts
TERMUX_PREFIX := /data/data/com.termux/files
DIST_TAR := gleamfonts.tgz

export ESQLITE_USE_SYSTEM ?= 1

.PHONY: clean check-format format test build install package all dist

all: package

build: deps
	$(GLEAM) build -t erlang

test: deps
	$(GLEAM) test -t erlang

deps:
	$(GLEAM) deps download

clean:
	$(GLEAM) clean
	rm -f $(DIST_TAR)
	rm -f ./tmp

check-format:
	$(GLEAM) format --check src test

format:
	$(GLEAM) format src test

$(PACKAGE): $(SRCS)
	$(GLEAM) export erlang-shipment

package: $(PACKAGE)

install: $(TERMUX_PREFIX)/usr/bin/gleamfonts

dist: $(DIST_TAR)

$(TERMUX_PREFIX)/usr/bin/gleamfonts: $(PACKAGE) $(RUN_SCRIPT)
	sed -i 's|#!/bin/sh|#!$(TERMUX_PREFIX)/usr/bin/sh|' $(PACKAGE)
	mkdir -p $(TERMUX_PREFIX)/usr/opt/gleamfonts
	cp -r ./build/erlang-shipment/* $(TERMUX_PREFIX)/usr/opt/gleamfonts/
	install -m 0775 ./scripts/gleamfonts $(TERMUX_PREFIX)/usr/bin/gleamfonts

$(DIST_TAR): $(PACKAGE)
	sed -i 's|#!/bin/sh|#!$(TERMUX_PREFIX)/usr/bin/sh|' $(PACKAGE)
	mkdir -p ./tmp/usr/opt/gleamfonts
	mkdir -p ./tmp/usr/bin
	cp -r ./build/erlang-shipment/* ./tmp/usr/opt/gleamfonts/
	install -m 0775 ./scripts/gleamfonts ./tmp/usr/bin/gleamfonts
	tar -czf $(DIST_TAR) -C ./tmp usr
	rm -fr ./tmp

