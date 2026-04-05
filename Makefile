# ── Platform detection ─────────────────────────────────────────────────────────
OS := $(shell uname -s)

DAEMON_BIN  := $(shell pwd)/daemon/bin/heimdallr

ifeq ($(OS),Darwin)
  FLUTTER_DEVICE   := macos
  FLUTTER_BUILD    := flutter_app/build/macos/Build/Products
  APP_BUNDLE       := $(FLUTTER_BUILD)/Release/Heimdallr.app
  # Detect local Developer ID Application certificate automatically
  SIGNING_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')
else
  FLUTTER_DEVICE   := linux
  FLUTTER_BUILD    := flutter_app/build/linux/x64/release
  APP_BUNDLE       := $(FLUTTER_BUILD)/bundle
endif

.PHONY: build-daemon build-app test dev dev-daemon dev-stop \
        release-local package-macos install-service verify-linux run-linux clean

# ── Build ─────────────────────────────────────────────────────────────────────

build-daemon:
	cd daemon && make build

build-app:
	cd flutter_app && flutter build $(FLUTTER_DEVICE) --release

# ── Test ──────────────────────────────────────────────────────────────────────

test:
	cd daemon && make test
	cd flutter_app && flutter test

# ── Local development ─────────────────────────────────────────────────────────
#
# make dev         — build daemon + run Flutter in debug mode
# make dev-daemon  — run daemon only (for API debugging)
# make dev-stop    — stop the running daemon

dev: build-daemon dev-stop
	@echo "▶  Lanzando Heimdallr..."
	cd flutter_app && HEIMDALLR_DAEMON_PATH=$(DAEMON_BIN) flutter run -d $(FLUTTER_DEVICE)

dev-daemon: build-daemon dev-stop
	@echo "▶  Daemon en http://localhost:7842 (Ctrl-C para parar)"
	GITHUB_TOKEN="$${GITHUB_TOKEN}" $(DAEMON_BIN)

dev-stop:
	@pkill -f "$(DAEMON_BIN)" 2>/dev/null && echo "↓  Daemon parado" || true
	@UI_PID_FILE="$$HOME/.local/share/heimdallr/ui.pid"; \
	 if [ -f "$$UI_PID_FILE" ]; then \
	   UI_PID=$$(cat "$$UI_PID_FILE"); \
	   kill "$$UI_PID" 2>/dev/null && echo "↓  UI parada (PID $$UI_PID)" || true; \
	   rm -f "$$UI_PID_FILE"; \
	 fi

# ── Local release (macOS only: sign + notarize + DMG + GitHub release) ───────
#
# Builds a fully signed, notarized .dmg and creates a GitHub release.
# Uses the Developer ID Application certificate from your local Keychain.
#
# Usage:
#   make release-local                    # auto-detect next semver from git log
#   make release-local VERSION=v1.2.3     # explicit version
#
# Prerequisites:
#   - Apple Developer Program membership
#   - Developer ID Application certificate installed in Keychain
#   - App-specific password stored in Keychain:
#       xcrun notarytool store-credentials "heimdallr-notary" \
#         --apple-id YOUR@EMAIL.COM --team-id TEAMID --password APP_SPECIFIC_PWD
#   - gh CLI authenticated: gh auth login

VERSION ?= $(shell \
	LAST=$$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0"); \
	VER=$${LAST\#v}; \
	MAJ=$$(echo $$VER | cut -d. -f1); \
	MIN=$$(echo $$VER | cut -d. -f2); \
	PAT=$$(echo $$VER | cut -d. -f3); \
	echo "v$$MAJ.$$MIN.$$((PAT+1))")

release-local: _check-macos _check-signing _check-gh build-daemon
	@echo ""
	@echo "╔══════════════════════════════════════════════╗"
	@echo "║  Heimdallr local release                     ║"
	@echo "╠══════════════════════════════════════════════╣"
	@echo "║  Version  : $(VERSION)"
	@echo "║  Identity : $(SIGNING_IDENTITY)"
	@echo "╚══════════════════════════════════════════════╝"
	@echo ""

	# ── 1. Flutter release build (Xcode uses your local signing config) ───────
	@echo "▶  Building Flutter app (release)..."
	cd flutter_app && flutter build macos --release \
	  --build-name="$$(echo $(VERSION) | sed 's/^v//')" \
	  --build-number="$$(date +%Y%m%d%H%M)"

	# ── 2. Embed daemon inside .app ───────────────────────────────────────────
	@echo "▶  Embedding daemon..."
	cp $(DAEMON_BIN) "$(APP_BUNDLE)/Contents/MacOS/heimdalld"
	chmod +x "$(APP_BUNDLE)/Contents/MacOS/heimdalld"

	# ── 3. Sign daemon binary with Developer ID ───────────────────────────────
	@echo "▶  Signing daemon binary..."
	codesign --force --options runtime \
	  --sign "$(SIGNING_IDENTITY)" \
	  "$(APP_BUNDLE)/Contents/MacOS/heimdalld"

	# ── 4. Re-sign the full .app bundle ──────────────────────────────────────
	@echo "▶  Signing .app bundle..."
	codesign --force --deep --options runtime \
	  --sign "$(SIGNING_IDENTITY)" \
	  "$(APP_BUNDLE)"

	@echo "▶  Verifying signature..."
	codesign --verify --verbose=2 "$(APP_BUNDLE)"
	spctl --assess --verbose "$(APP_BUNDLE)" 2>&1 || \
	  echo "⚠  spctl warning (expected before notarization)"

	# ── 5. Create DMG with create-dmg (nice installer UI) ────────────────────
	@echo "▶  Creating DMG..."
	@command -v create-dmg >/dev/null || (echo "Installing create-dmg..."; brew install create-dmg)
	mkdir -p dist
	$(eval DMG_ARGS := \
	  --volname "Heimdallr $(VERSION)" \
	  --window-pos 200 120 --window-size 660 400 \
	  --icon-size 128 \
	  --icon "Heimdallr.app" 165 185 \
	  --hide-extension "Heimdallr.app" \
	  --app-drop-link 495 185)
	$(if $(wildcard assets/dmg-background.png), \
	  $(eval DMG_ARGS := --background assets/dmg-background.png $(DMG_ARGS)))
	create-dmg $(DMG_ARGS) "dist/Heimdallr-$(VERSION).dmg" "$(APP_BUNDLE)"

	# ── 6. Notarize DMG ───────────────────────────────────────────────────────
	@echo "▶  Submitting for notarization (this takes a few minutes)..."
	xcrun notarytool submit "dist/Heimdallr-$(VERSION).dmg" \
	  --keychain-profile "heimdallr-notary" \
	  --wait
	xcrun stapler staple "dist/Heimdallr-$(VERSION).dmg"
	@echo "✓  Notarization complete"

	# ── 7. Create git tag ─────────────────────────────────────────────────────
	@echo "▶  Creating tag $(VERSION)..."
	git tag -a "$(VERSION)" -m "Release $(VERSION)"
	git push origin "$(VERSION)"

	# ── 8. Publish GitHub release ─────────────────────────────────────────────
	@echo "▶  Publishing GitHub release..."
	gh release create "$(VERSION)" \
	  "dist/Heimdallr-$(VERSION).dmg" \
	  --title "Heimdallr $(VERSION)" \
	  --generate-notes \
	  --verify-tag
	@echo ""
	@echo "✅  Released Heimdallr $(VERSION)"
	@echo "    https://github.com/$$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/$(VERSION)"

# ── Guards ────────────────────────────────────────────────────────────────────

_check-macos:
	@if [ "$$(uname -s)" != "Darwin" ]; then \
	  echo "❌  This target requires macOS."; \
	  exit 1; \
	fi

_check-signing:
	@if [ -z "$(SIGNING_IDENTITY)" ]; then \
	  echo ""; \
	  echo "❌  No Developer ID Application certificate found in Keychain."; \
	  echo ""; \
	  echo "    Install your certificate from:"; \
	  echo "    https://developer.apple.com/account/resources/certificates/list"; \
	  echo ""; \
	  exit 1; \
	fi
	@echo "✓  Signing identity: $(SIGNING_IDENTITY)"

_check-gh:
	@if ! gh auth status >/dev/null 2>&1; then \
	  echo "❌  gh CLI not authenticated. Run: gh auth login"; \
	  exit 1; \
	fi
	@echo "✓  gh CLI authenticated"

# ── Install LaunchAgent service (macOS) ───────────────────────────────────────

install-service: build-daemon
	$(DAEMON_BIN) install

# ── CI packaging (used by GitHub Actions) ─────────────────────────────────────

package-macos: _check-macos build-daemon build-app
	cp $(DAEMON_BIN) "$(APP_BUNDLE)/Contents/MacOS/heimdalld"
	codesign --force --deep --sign - "$(APP_BUNDLE)"
	mkdir -p dist
	hdiutil create \
	  -volname "Heimdallr" \
	  -srcfolder "$(APP_BUNDLE)" \
	  -ov -format UDZO \
	  "dist/Heimdallr.dmg"

# ── Docker-based Linux build verification ─────────────────────────────────────
#
# Runs the full CI-equivalent pipeline inside a Docker container:
# daemon tests → flutter pub get → flutter test →
# daemon build → flutter build linux --release → verify output artifacts
#
# Works from any OS (macOS or Linux) as long as Docker is available.
#
# Usage:
#   make verify-linux

verify-linux:
	@command -v docker >/dev/null || { echo "❌  Docker is required. Install it from https://docs.docker.com/get-docker/"; exit 1; }
	@echo "▶  Building Linux verification image (this may take a few minutes on first run)..."
	docker build -f Dockerfile.linux-verify -t heimdallr-verify .
	@echo ""
	@echo "✅  Linux build verification passed"

# ── Run the Linux app from Docker (manual testing) ───────────────────────────
#
# Launches the release-built app from the heimdallr-verify Docker image,
# forwarding X11, D-Bus, and GPU so it renders on your desktop.
#
# Requires:
#   - heimdallr-verify image (run 'make verify-linux' first)
#   - X11 display (DISPLAY env var set — XWayland counts)
#
# GPU acceleration is used when /dev/dri exists; otherwise the app falls
# back to software rendering (llvmpipe) automatically.
#
# --net=host is required so the container can reach the X11 unix socket
# and the host D-Bus session bus without complex network plumbing.
# --ipc=host is required for MIT-SHM (X11 shared memory transport),
# without which GTK falls back to slow network-style rendering.
#
# The container runs as the current user (not root) to avoid file
# ownership issues with the persisted config directory.
#
# Config is persisted to ~/.config/heimdallr between runs.
# Pass GITHUB_TOKEN to connect to GitHub:
#   GITHUB_TOKEN=ghp_... make run-linux
#
# Usage:
#   make run-linux

LINUX_BUNDLE := /app/flutter_app/build/linux/x64/release/bundle

run-linux:
	@command -v docker >/dev/null || { echo "❌  Docker is required."; exit 1; }
	@test -n "$$DISPLAY" || { echo "❌  No DISPLAY set — need X11 (or XWayland)."; exit 1; }
	@docker image inspect heimdallr-verify >/dev/null 2>&1 || \
	  { echo "❌  Image 'heimdallr-verify' not found. Run 'make verify-linux' first."; exit 1; }
	@mkdir -p "$$HOME/.config/heimdallr"
	@# Remove stale container from a previous interrupted run (if any).
	@docker rm -f heimdallr-run 2>/dev/null || true
	@# --- Single shell block so the EXIT trap covers everything -----------
	@ENV_FILE=$$(mktemp) ; \
	cleanup() { \
	  xhost -local:docker 2>/dev/null || true ; \
	  rm -f "$$ENV_FILE" ; \
	} ; \
	trap cleanup EXIT ; \
	\
	echo "DISPLAY=$$DISPLAY" > "$$ENV_FILE" ; \
	echo "HEIMDALLR_DAEMON_PATH=/app/daemon/bin/heimdallr" >> "$$ENV_FILE" ; \
	if [ -n "$$GITHUB_TOKEN" ]; then \
	  echo "GITHUB_TOKEN=$$GITHUB_TOKEN" >> "$$ENV_FILE" ; \
	fi ; \
	UID_VAL=$$(id -u) ; \
	GID_VAL=$$(id -g) ; \
	if [ -e /run/user/$$UID_VAL/bus ]; then \
	  DBUS_ARGS="-v /run/user/$$UID_VAL/bus:/run/user/$$UID_VAL/bus:ro" ; \
	  echo "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$$UID_VAL/bus" >> "$$ENV_FILE" ; \
	fi ; \
	GPU_ARGS="" ; \
	if [ -e /dev/dri ]; then \
	  GPU_ARGS="--device /dev/dri" ; \
	else \
	  echo "⚠  /dev/dri not found — using software rendering (llvmpipe)." ; \
	fi ; \
	\
	echo "▶  Launching Heimdallr (Linux) via Docker..." ; \
	echo "   Close the app window or press Ctrl-C to stop." ; \
	xhost +local:docker 2>/dev/null || true ; \
	\
	docker run --rm \
	  --name heimdallr-run \
	  --env-file "$$ENV_FILE" \
	  --user "$$UID_VAL:$$GID_VAL" \
	  -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
	  -v /run/dbus:/run/dbus:ro \
	  $$DBUS_ARGS \
	  -v "$$HOME/.config/heimdallr:$$HOME/.config/heimdallr" \
	  $$GPU_ARGS \
	  --ipc=host \
	  --net=host \
	  heimdallr-verify \
	  $(LINUX_BUNDLE)/heimdallr

clean:
	cd daemon && make clean
	cd flutter_app && flutter clean
