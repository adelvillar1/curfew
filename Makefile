# Curfew — an internal tool. No release pipeline, no notarisation, no cask (D21).

BIN := curfew
# SwiftPM cannot build from a sandboxed agent session without these (KI-019).
export CLANG_MODULE_CACHE_PATH ?= $(CURDIR)/.build/modulecache
PREFIX ?= $(HOME)/.local/bin
# SwiftPM cannot build from a sandboxed agent session: see KI-019.
SWIFT := swift build --disable-sandbox --cache-path .build/spm-cache --config-path .build/spm-config

.PHONY: build release test check install uninstall app run-app clean

build:
	$(SWIFT)

release:
	$(SWIFT) -c release

test:
	swift test --disable-sandbox --cache-path .build/spm-cache --config-path .build/spm-config

## Everything that must pass before a change is believed.
check: test
	python3 scripts/ledger_check.py
	.build/debug/curfew catalog validate
	./scripts/crash-test.sh

## Put it on PATH. One user, one machine — no .app, no cask, no signature.
install: release
	mkdir -p $(PREFIX)
	cp .build/release/$(BIN) $(PREFIX)/$(BIN)
	@echo "installed $(PREFIX)/$(BIN)"
	@echo "catalog lookup uses ./catalog, so run it from the project directory or pass --dir"

uninstall:
	rm -f $(PREFIX)/$(BIN)

## The menu bar app. No Developer ID: an ad-hoc signature is enough for a status item on this machine
## (D21 — nothing is distributed, so nothing is notarised).
APP := build/Curfew.app

app:
	$(SWIFT) -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/curfew-menubar $(APP)/Contents/MacOS/Curfew
	cp scripts/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)
	@echo "built $(APP) — run it with: open $(APP)"

run-app: app
	open $(APP)

clean:
	rm -rf .build
