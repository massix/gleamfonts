GLEAM := $(shell which gleam)
TERMUX_PREFIX ?= /data/data/com.termux/files
RUN_SCRIPT := ./scripts/gleamfonts
DIST_TAR := gleamfonts.tgz
ENTRYPOINT := ./build/erlang-shipment/entrypoint.sh

export ESQLITE_USE_SYSTEM ?= 1

all: package
package: erlang-shipment

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

erlang-shipment: $(SRCS)
	$(GLEAM) export erlang-shipment

install: package
	sed -i 's|#!/bin/sh|#!$(TERMUX_PREFIX)/usr/bin/sh|' $(ENTRYPOINT)
	mkdir -p $(TERMUX_PREFIX)/usr/opt/gleamfonts
	cp -r ./build/erlang-shipment/* $(TERMUX_PREFIX)/usr/opt/gleamfonts/
	install -m 0775 $(RUN_SCRIPT) $(TERMUX_PREFIX)/usr/bin/gleamfonts

dist: package
	sed -i 's|#!/bin/sh|#!$(TERMUX_PREFIX)/usr/bin/sh|' $(ENTRYPOINT)
	mkdir -p ./tmp/usr/opt/gleamfonts
	mkdir -p ./tmp/usr/bin
	cp -r ./build/erlang-shipment/* ./tmp/usr/opt/gleamfonts/
	install -m 0775 $(RUN_SCRIPT) ./tmp/usr/bin/gleamfonts
	cp ./LICENSE ./tmp
	tar -czf $(DIST_TAR) -C ./tmp usr LICENSE
	rm -fr ./tmp

