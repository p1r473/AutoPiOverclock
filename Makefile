SHELL := /usr/bin/env bash
SHELLCHECK_FILES := autopioverclock $(wildcard lib/*.sh profiles/*.sh workers/*.sh tools/*.sh examples/*.sh tests/*.sh assets/batocera/*.sh) assets/batocera/AutoPiOverclockWatchdog
SHELLCHECK_SHALLOW_FILES := tests/test_simple_cli_parse.sh tests/test_simple_cli_resume.sh tests/test_simple_cli_edge.sh tests/test_simple_cli_manual.sh
BATOCERA_ASSETS := \
	assets/batocera/AutoPiOverclockWatchdog \
	assets/batocera/install_watchdog.sh \
	assets/batocera/watchdog_keeper.py

PREFIX ?= /usr/local
DESTDIR ?=
INSTALL_ROOT := $(DESTDIR)$(PREFIX)/lib/autopioverclock
INSTALL_BIN := $(DESTDIR)$(PREFIX)/bin

.PHONY: test lint check package install

test:
	./tests/run.sh

lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo 'shellcheck is required for make lint' >&2; exit 1; }
	@for shell_file in $(SHELLCHECK_FILES); do \
		printf 'shellcheck: %s\n' "$$shell_file"; \
		case " $(SHELLCHECK_SHALLOW_FILES) " in \
			*" $$shell_file "*) shellcheck "$$shell_file" || exit $$? ;; \
			*) shellcheck -x "$$shell_file" || exit $$? ;; \
		esac; \
	done

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
	install -m 755 $(BATOCERA_ASSETS) "$(INSTALL_ROOT)/assets/batocera/"
	ln -sfn ../lib/autopioverclock/autopioverclock "$(INSTALL_BIN)/autopioverclock"
