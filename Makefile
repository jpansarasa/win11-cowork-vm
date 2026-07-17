SHELL := /bin/bash
SCRIPTS := $(wildcard scripts/*.sh) install.sh recover.sh lib/common.sh lib/generators.sh

.PHONY: lint test
lint:
	shellcheck -x $(SCRIPTS)
test:
	bats tests/
