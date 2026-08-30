# 7z Drop — macOS drag & drop compressor
#
#   make test     run the whole suite (unit + end-to-end against the bundled 7zz)
#   make app      build build/7Zip Drop.app (release, ad-hoc signed)
#   make run      build and launch it
#   make install  copy it into /Applications
#   make tips     check the settings rows really have system tooltips installed
#   make mutate   check that the test suite actually detects injected defects
#   make clean    remove build products

SHELL := /bin/bash
.DEFAULT_GOAL := help
APP := build/7Zip Drop.app

.PHONY: help
help:
	@grep -E '^#   ' Makefile | sed 's/^#   //'

.PHONY: vendor
vendor:
	@./scripts/fetch-7zz.sh

.PHONY: build
build: vendor
	swift build

.PHONY: test
test: vendor
	swift test

.PHONY: app
app: vendor
	@CONFIG=release ./scripts/make-app.sh

.PHONY: run
run: app
	@open "$(APP)"

.PHONY: install
install: app
	@rm -rf "/Applications/7Zip Drop.app"
	@cp -R "$(APP)" /Applications/
	@echo "installed: /Applications/7Zip Drop.app"

.PHONY: tips
tips:
	@./scripts/check-tooltips.sh

.PHONY: mutate
mutate:
	@./scripts/mutation-check.sh

.PHONY: audit
audit:
	@./scripts/security-audit.sh

.PHONY: clean
clean:
	swift package clean
	rm -rf build
