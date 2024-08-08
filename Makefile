GLEAM := $(shell which gleam)
BIN := ./gleamfonts
SRCS := $(wildcard src/**/*.gleam)

export ESQLITE_USE_SYSTEM ?= 1

.PHONY: clean check-format format test build

all: $(BIN)

$(BIN): build
	$(GLEAM) run -m gleescript

build: deps
	$(GLEAM) build -t erlang

test: deps
	$(GLEAM) test -t erlang

deps:
	$(GLEAM) deps download

clean:
	$(GLEAM) clean
	rm -f $(BIN)

check-format:
	$(GLEAM) format --check src test

format:
	$(GLEAM) format src test
