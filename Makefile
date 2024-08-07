GLEAM := $(shell which gleam)
BIN := ./gleamfonts
SRCS := $(wildcard src/**/*.gleam)

.PHONY: clean check-format format test build

all: $(BIN)

$(BIN): deps
	$(GLEAM) run -m gleescript

build: deps
	$(GLEAM) build

test: deps
	$(GLEAM) test

deps:
	$(GLEAM) deps download

clean:
	$(GLEAM) clean
	rm -f $(BIN)

check-format:
	$(GLEAM) format --check src test

format:
	$(GLEAM) format src test
