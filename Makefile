DAEMON_BIN  := $(shell pwd)/daemon/bin/heimdallr
FLUTTER_APP := flutter_app/build/macos/Build/Products

.PHONY: build-daemon build-app test dev dev-daemon dev-stop package-macos install-service clean

# ── Build ────────────────────────────────────────────────────────────────────

build-daemon:
	cd daemon && make build

build-app:
	cd flutter_app && flutter build macos --release

# ── Test ─────────────────────────────────────────────────────────────────────

test:
	cd daemon && make test
	cd flutter_app && flutter test

# ── Local development ────────────────────────────────────────────────────────
#
# make dev  — compila el daemon y lanza la app Flutter.
#             La app detecta las credenciales (gh auth token / Keychain),
#             escribe la config y arranca el daemon sola.
#             Solo muestra Settings si no hay ningún token disponible.
#
# make dev-daemon — arranca solo el daemon (para debugging de la API)
# make dev-stop   — para el daemon

dev: build-daemon dev-stop
	@echo "▶  Lanzando Heimdallr..."
	cd flutter_app && HEIMDALLR_DAEMON_PATH=$(DAEMON_BIN) flutter run -d macos

dev-daemon: build-daemon dev-stop
	@echo "▶  Daemon en http://localhost:7842 (Ctrl-C para parar)"
	GITHUB_TOKEN="$${GITHUB_TOKEN}" $(DAEMON_BIN)

dev-stop:
	@pkill -f "$(DAEMON_BIN)" 2>/dev/null && echo "↓  Daemon parado" || true

# ── Packaging ────────────────────────────────────────────────────────────────

package-macos: build-daemon build-app
	cp $(DAEMON_BIN) \
	  "$(FLUTTER_APP)/Release/heimdallr.app/Contents/MacOS/heimdallr"
	create-dmg \
	  --volname "Heimdallr" \
	  --window-size 540 380 \
	  --icon-size 128 \
	  --app-drop-link 380 185 \
	  "dist/heimdallr.dmg" \
	  "$(FLUTTER_APP)/Release/heimdallr.app"

install-service: build-daemon
	$(DAEMON_BIN) install

clean:
	cd daemon && make clean
	cd flutter_app && flutter clean
