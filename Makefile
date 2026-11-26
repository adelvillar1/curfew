# Curfew — an internal tool. No release pipeline, no notarisation, no cask (D21).

BIN := curfew
# SwiftPM cannot build from a sandboxed agent session without these (KI-019).
export CLANG_MODULE_CACHE_PATH ?= $(CURDIR)/.build/modulecache
PREFIX ?= $(HOME)/.local/bin
# SwiftPM cannot build from a sandboxed agent session: see KI-019.
SWIFT := swift build --disable-sandbox --cache-path .build/spm-cache --config-path .build/spm-config

.PHONY: build release test check install uninstall app run-app install-app clean hygiene hygiene-live wrapup wrapup-live mirror hooks

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
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/curfew-menubar $(APP)/Contents/MacOS/Curfew
	cp scripts/Info.plist $(APP)/Contents/Info.plist
	@# The build identity, so "is this the new one?" is answerable from inside the app.
	@plutil -replace CFBundleVersion -string "$$(git rev-parse --short HEAD) built $$(date '+%H:%M')" \
		$(APP)/Contents/Info.plist
	@# The repo this build came from, so the Hygiene pane can read its build directories (D45).
	@plutil -replace CurfewRepoPath -string "$$(pwd)" $(APP)/Contents/Info.plist
	# The catalogue ships inside the bundle: a login-launched app gets `/` as its cwd, so a
	# cwd-relative lookup finds nothing. It must be copied BEFORE signing — adding a sealed resource
	# afterwards invalidates the signature and macOS then refuses to launch the app, silently.
	cp -R catalog $(APP)/Contents/Resources/catalog
	codesign --force --sign - $(APP)
	codesign -v $(APP)
	@echo "built and signed $(APP) — run it with: open $(APP)"

run-app: app
	open $(APP)

## Install where it survives: ~/Applications, with the catalogue inside the bundle and a login opener.
## A login-launched app gets `/` as its working directory, so a cwd-relative catalogue would be empty —
## the catalogue ships in Contents/Resources and the app looks there (CURFEW_CATALOG overrides).
APP_INSTALL := $(HOME)/Applications/Curfew.app
AGENT := com.adelvillar1.curfew-menubar

install-app: app
	mkdir -p $(HOME)/Applications $(HOME)/Library/LaunchAgents
	rm -rf $(APP_INSTALL)
	cp -R $(APP) $(APP_INSTALL)
	codesign -v $(APP_INSTALL)
	# register the bundle so `open -a` works for a manual launch too; the agent itself execs the binary
	-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $(APP_INSTALL)
	cp scripts/$(AGENT).plist $(HOME)/Library/LaunchAgents/$(AGENT).plist
	-launchctl bootout gui/$(shell id -u)/$(AGENT) 2>/dev/null
	@# the old instance takes a moment to release the job; bootstrapping too soon returns 5
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		launchctl print gui/$(shell id -u)/$(AGENT) >/dev/null 2>&1 || break; sleep 0.3; \
	done
	launchctl bootstrap gui/$(shell id -u) $(HOME)/Library/LaunchAgents/$(AGENT).plist
	@echo "installed $(APP_INSTALL) and the login opener"
	@echo "restore the status item with: launchctl kickstart gui/$$(id -u)/$(AGENT)"
	@# The login opener starts the app with --background, which by design shows no window — so an
	@# install otherwise leaves nothing on screen and looks like it did nothing. Ask the instance that
	@# holds the lock to show itself; `open -a` only starts a second process, which the guard exits.
	@open -a $(APP_INSTALL) || true

## Gitea is the master; GitHub is a mirror (D49). This pushes Gitea first, then mirrors, then proves both
## ends hold the same commit. The pre-push hook refuses the reverse order, so the only way GitHub gets ahead
## is if this target is bypassed with --no-verify.
mirror:
	@git push origin main
	@git push github main
	@a=$$(git ls-remote origin refs/heads/main | cut -f1); \
	 b=$$(git ls-remote github refs/heads/main | cut -f1); \
	 if [ "$$a" = "$$b" ] && [ -n "$$a" ]; then \
	   echo "mirrored: gitea $$a = github $$b"; \
	 else \
	   echo "MISMATCH: gitea $${a:-none} · github $${b:-none}" >&2; exit 1; \
	 fi

## The pre-push guard lives in the repo; this makes git use it.
hooks:
	@git config core.hooksPath .githooks && echo "core.hooksPath = .githooks"

## The hygiene pass, ported from fleet: prune regenerable artifacts from a stale repo, and stop
## keep-alive processes whose parent is gone. Both are reports unless you ask for --live.
hygiene:
	@scripts/repo-hygiene.sh --report
	@echo ""
	@scripts/reap-orphans.sh

hygiene-live:
	@scripts/repo-hygiene.sh --live
	@echo ""
	@scripts/reap-orphans.sh --live

## The session-close leg (D44): the processes a run spawned, the orphans, the disk, and the records
## Curfew itself grew. Reports by default; --live applies legs 1 and 3 only. Records are never deleted.
wrapup:
	@scripts/session-close-hygiene.sh

wrapup-live:
	@scripts/session-close-hygiene.sh --live

uninstall-app:
	-launchctl bootout gui/$(shell id -u)/$(AGENT) 2>/dev/null
	rm -f $(HOME)/Library/LaunchAgents/$(AGENT).plist
	rm -rf $(APP_INSTALL)
	@echo "removed the app and its opener"

clean:
	rm -rf .build
