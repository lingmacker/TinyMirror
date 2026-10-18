.DEFAULT_GOAL := build
# Configurations share one app bundle; serialize top-level goals.
.NOTPARALLEL:
.PHONY: clean build run install

CONFIGURATION ?= debug
INSTALL_DIR ?= /Applications

build:
	./scripts/bootstrap.sh
	CONFIGURATION="$(CONFIGURATION)" ./scripts/build-app.sh

run: build
	@if pgrep -x TinyMirror >/dev/null; then \
		echo "Quit the running TinyMirror before starting a new build." >&2; exit 1; \
	fi
	open "dist/TinyMirror.app"

install:
	$(MAKE) build CONFIGURATION=debug
	./scripts/install-app.sh "$(INSTALL_DIR)"

clean:
	rm -rf .build dist native/build
