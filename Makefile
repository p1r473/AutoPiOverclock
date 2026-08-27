SHELL := /usr/bin/env bash
SHELLCHECK_FILES := autopioverclock $(wildcard lib/*.sh profiles/*.sh workers/*.sh tools/*.sh examples/*.sh tests/*.sh assets/batocera/*.sh) assets/batocera/AutoPiOverclockWatchdog

PREFIX ?= /usr/local
DESTDIR ?=
INSTALL_ROOT := $(DESTDIR)$(PREFIX)/lib/autopioverclock
INSTALL_BIN := $(DESTDIR)$(PREFIX)/bin

.PHONY: test lint check package install

test:
	./tests/run.sh

lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo 'shellcheck is required for make lint' >&2; exit 1; }
	shellcheck -x $(SHELLCHECK_FILES)

check: test lint

package:
	./tools/package.sh

install:
	install -d "$(INSTALL_ROOT)/lib" "$(INSTALL_ROOT)/profiles" "$(INSTALL_ROOT)/workers" "$(INSTALL_ROOT)/tools" "$(INSTALL_ROOT)/assets/batocera" "$(INSTALL_BIN)"
	install -m 755 autopioverclock "$(INSTALL_ROOT)/autopioverclock"
	install -m 644 VERSION "$(INSTALL_ROOT)/VERSION"
	install -m 644 lib/*.sh "$(INSTALL_ROOT)/lib/"
	install -m 644 profiles/*.sh "$(INSTALL_ROOT)/profiles/"
	install -m 755 workers/*.sh "$(INSTALL_ROOT)/workers/"
	install -m 755 tools/*.sh "$(INSTALL_ROOT)/tools/"
	install -m 755 assets/batocera/* "$(INSTALL_ROOT)/assets/batocera/"
	ln -sfn ../lib/autopioverclock/autopioverclock "$(INSTALL_BIN)/autopioverclock"
