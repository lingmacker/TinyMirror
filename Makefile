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
	@if pgrep -x MirrorDeck >/dev/null; then \
		echo "Quit the running MirrorDeck before starting a new build." >&2; exit 1; \
	fi
	open "dist/MirrorDeck.app"

install:
	$(MAKE) build CONFIGURATION=debug
	./scripts/install-app.sh "$(INSTALL_DIR)"

clean:
	@if [ -f native/build/CMakeCache.txt ]; then \
		cmake --build native/build --target clean; \
	fi
	rm -rf .build
