SHELL := /usr/bin/env bash
SHELLCHECK_FILES := autopioverclock $(wildcard lib/*.sh profiles/*.sh workers/*.sh tools/*.sh examples/*.sh tests/*.sh)

.PHONY: test lint check package

test:
	./tests/run.sh

lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo 'shellcheck is required for make lint' >&2; exit 1; }
	shellcheck -x $(SHELLCHECK_FILES)

check: test lint

package:
	./tools/package.sh
