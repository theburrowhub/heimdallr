# Native Linux Install Target — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `install-linux` and `uninstall-linux` Makefile targets that install Heimdallm user-local (`~/.local/…`) on Linux. The install target reuses the existing `verify-linux` Docker build — no host Flutter toolchain required.

**Architecture:** Two new Make targets plus one shared preflight guard (`_check-linux`), all added to `Makefile`. `install-linux` depends on `_check-linux verify-linux`; its recipe extracts the Flutter bundle and Go daemon from the `heimdallm-verify` Docker image via `docker create` + `docker cp` + `docker rm`, then stages them into `~/.local/opt/heimdallm/`. `uninstall-linux` supports a `PURGE=1` flag to also wipe user config/data, mirroring Debian's `apt purge` convention. Layout mirrors the CI `.deb` under the user's `~/.local/` so `DaemonLifecycle.defaultBinaryPath()` finds `heimdalld` next to the Flutter binary with no app-code change.

**Tech Stack:** GNU Make, POSIX shell, Docker CLI. No new files, no new build tools. Spec: `docs/superpowers/specs/2026-04-21-install-linux-design.md` (Revision 2026-04-21 pivoted from host-native build to Docker-reuse).

---

## File Structure

Only one file is touched by this plan.

- **Modify: `Makefile`**
  - Add `install-linux uninstall-linux _check-linux` to the `.PHONY` list (original line 19–22 before Task 1 shifted line numbers).
  - Add a `_check-linux` guard recipe alongside the existing `_check-macos` (original line 206 region).
  - Add a new "Native Linux install / uninstall" section after the existing `run-linux` recipe and before `clean:` so all Linux-related targets live together. The section introduces:
    - `EXTRACT_DIR := /tmp/heimdallm-install-extract` — Make variable used by the install recipe as the temporary staging location for artifacts copied out of the Docker image.
    - `install-linux` recipe.
    - `uninstall-linux` recipe.

No new files. No changes to `daemon/`, `flutter_app/`, `docker/`, or CI workflows — the runtime contract (`heimdalld` next to `heimdallm`) is already satisfied by the layout this plan creates.

> **Makefile syntax reminder (read before editing):** Recipe bodies MUST be indented with a literal TAB character, never spaces. `$` in shell code must be written as `$$` in the Makefile so it survives Make's own variable expansion and reaches the shell intact. Multi-line shell statements within a single recipe line use `\` for line continuation AND must be joined into a single shell invocation with `;` or `&&` — each logical line in a recipe runs in a fresh subshell otherwise.

---

## Task 1: Add `_check-linux` guard and register targets in `.PHONY`

**Files:**
- Modify: `Makefile:19-22` (`.PHONY` list)
- Modify: `Makefile` (add `_check-linux` recipe near line 206, next to `_check-macos`)

- [ ] **Step 1: Extend the `.PHONY` list**

Open `Makefile` and replace the block at lines 19–22:

```make
.PHONY: build-daemon build-app test test-docker dev dev-daemon dev-stop \
        release-local package-macos install-service verify-linux run-linux \
        setup up up-build up-daemon up-build-daemon down logs logs-daemon \
        ps restart clean _check-docker _check-env
```

with:

```make
.PHONY: build-daemon build-app test test-docker dev dev-daemon dev-stop \
        release-local package-macos install-service verify-linux run-linux \
        install-linux uninstall-linux \
        setup up up-build up-daemon up-build-daemon down logs logs-daemon \
        ps restart clean _check-docker _check-env _check-linux
```

- [ ] **Step 2: Add the `_check-linux` guard recipe**

Find the existing `_check-macos` recipe (starts around line 206):

```make
_check-macos:
	@if [ "$$(uname -s)" != "Darwin" ]; then \
	  echo "❌  This target requires macOS."; \
	  exit 1; \
	fi
```

Immediately after it (before `_check-signing`), add:

```make
_check-linux:
	@if [ "$$(uname -s)" != "Linux" ]; then \
	  echo "❌  This target requires Linux."; \
	  echo "    On macOS, use 'make release-local' or 'make run-linux'."; \
	  exit 1; \
	fi
```

**Indent with a TAB** — the `@if` line and its continuations.

- [ ] **Step 3: Verify the guard on Linux**

On a Linux machine:

```bash
make _check-linux
```

Expected: no output, exit code 0.

```bash
echo $?
```

Expected: `0`.

- [ ] **Step 4: Verify the guard on macOS (optional — skip if no Mac available)**

On macOS:

```bash
make _check-linux
```

Expected: `❌  This target requires Linux.\n    On macOS, use 'make release-local' or 'make run-linux.'`, exit code 1.

- [ ] **Step 5: Commit**

```bash
git add Makefile
git commit -m "$(cat <<'EOF'
feat(make): add _check-linux guard and reserve install/uninstall-linux phony

Prerequisite for the upcoming install-linux and uninstall-linux targets.
Mirrors the existing _check-macos guard.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add the `install-linux` target (reuses `verify-linux` Docker build)

**Files:**
- Modify: `Makefile` — add a new section between the end of the `run-linux` recipe and the start of `clean:`. Do not rely on hard-coded line numbers; Task 1 shifted them. Locate anchors by content:
  - End of `run-linux` is the line containing `$(LINUX_BUNDLE)/heimdallm` (last command of its `docker run` pipeline).
  - `clean:` is a target declaration — grep for it.

- [ ] **Step 1: Insert the section header and recipe**

Insert immediately after `run-linux`'s last line (with one leading blank line before the section-header comment), and immediately before `clean:`:

```make

# ── Native Linux install / uninstall (user-local, no sudo) ────────────────────
#
# Extracts the Flutter bundle and Go daemon from the heimdallm-verify Docker
# image (built by `make verify-linux`) and stages them into ~/.local/ so the
# app launches like any other desktop Linux application. No host Flutter
# toolchain required; Docker does the build.
#
# Layout written:
#   ~/.local/opt/heimdallm/                  # bundle root (matches CI .deb)
#     heimdallm                              # Flutter binary
#     heimdalld                              # Go daemon (copied from /app/daemon/bin/heimdallm in image, renamed)
#   ~/.local/bin/heimdallm                   # → symlink into the bundle
#   ~/.local/share/applications/com.theburrowhub.heimdallm.desktop
#   ~/.local/share/icons/hicolor/{48,128,256,512}x{same}/apps/heimdallm.png
#
# The Flutter app (DaemonLifecycle.defaultBinaryPath in
# flutter_app/lib/core/daemon/daemon_lifecycle.dart) resolves the daemon as
# "heimdalld" next to its own binary, so the rename at install time is what
# makes the spawn work without any env var override.
#
# Binary compatibility: the heimdallm-verify image is ubuntu:22.04, so the
# binaries link dynamically against that distro's glibc/gtk versions. Works
# on any reasonably current Debian/Ubuntu/Fedora/Arch; hosts with a much
# older libc may see missing-symbol errors at first launch.
#
# Usage:
#   make install-linux
#
# To remove: see `uninstall-linux` below.

EXTRACT_DIR := /tmp/heimdallm-install-extract

install-linux: _check-linux verify-linux
	@command -v docker >/dev/null 2>&1 || { echo "❌  Docker is required. Install from https://docs.docker.com/get-docker/"; exit 1; }
	@echo "▶  Extracting Heimdallm artifacts from heimdallm-verify image..."
	@rm -rf "$(EXTRACT_DIR)"
	@mkdir -p "$(EXTRACT_DIR)"
	@CID=$$(docker create heimdallm-verify) ; \
	 trap 'docker rm "$$CID" >/dev/null 2>&1 || true' EXIT ; \
	 docker cp "$$CID:/app/flutter_app/build/linux/x64/release/bundle/." "$(EXTRACT_DIR)/bundle/" && \
	 docker cp "$$CID:/app/daemon/bin/heimdallm" "$(EXTRACT_DIR)/daemon"
	@echo "▶  Staging Heimdallm into $$HOME/.local/opt/heimdallm..."
	rm -rf "$$HOME/.local/opt/heimdallm"
	mkdir -p "$$HOME/.local/opt/heimdallm"
	cp -r "$(EXTRACT_DIR)/bundle/." "$$HOME/.local/opt/heimdallm/"
	cp "$(EXTRACT_DIR)/daemon" "$$HOME/.local/opt/heimdallm/heimdalld"
	chmod +x "$$HOME/.local/opt/heimdallm/heimdalld"
	@# Fork-bomb guard: same check CI's release pipeline runs.
	@# If both binaries are byte-identical, the "spawn heimdalld" call from
	@# DaemonLifecycle would re-exec the Flutter app and hundreds of instances
	@# would spawn on first launch.
	@if cmp -s "$$HOME/.local/opt/heimdallm/heimdallm" "$$HOME/.local/opt/heimdallm/heimdalld"; then \
	  echo "❌  Both binaries are identical — case-collision fork-bomb state. Aborting."; \
	  exit 1; \
	fi
	rm -rf "$(EXTRACT_DIR)"
	mkdir -p "$$HOME/.local/bin"
	ln -sf "$$HOME/.local/opt/heimdallm/heimdallm" "$$HOME/.local/bin/heimdallm"
	@for SIZE in 48 128 256 512; do \
	  ICON_DIR="$$HOME/.local/share/icons/hicolor/$${SIZE}x$${SIZE}/apps"; \
	  mkdir -p "$$ICON_DIR"; \
	  cp "flutter_app/assets/icons/$${SIZE}.png" "$$ICON_DIR/heimdallm.png"; \
	done
	@DESKTOP_DIR="$$HOME/.local/share/applications"; \
	mkdir -p "$$DESKTOP_DIR"; \
	printf '%s\n' \
	  '[Desktop Entry]' \
	  'Name=Heimdallm' \
	  'Comment=AI-powered GitHub PR review agent' \
	  "Exec=$$HOME/.local/opt/heimdallm/heimdallm" \
	  'Icon=heimdallm' \
	  'Type=Application' \
	  'Categories=Development;' \
	  'StartupWMClass=com.theburrowhub.heimdallm' \
	  'StartupNotify=true' \
	  > "$$DESKTOP_DIR/com.theburrowhub.heimdallm.desktop"
	@# Best-effort launcher cache refresh (silent no-op if tools missing).
	@command -v update-desktop-database >/dev/null 2>&1 && \
	  update-desktop-database "$$HOME/.local/share/applications/" 2>/dev/null || true
	@command -v gtk-update-icon-cache >/dev/null 2>&1 && \
	  gtk-update-icon-cache -q -t "$$HOME/.local/share/icons/hicolor/" 2>/dev/null || true
	@echo ""
	@echo "✅  Heimdallm installed:"
	@echo "    Bundle:  $$HOME/.local/opt/heimdallm/"
	@echo "    Symlink: $$HOME/.local/bin/heimdallm"
	@echo "    Desktop: $$HOME/.local/share/applications/com.theburrowhub.heimdallm.desktop"
	@echo "    Icons:   $$HOME/.local/share/icons/hicolor/<size>x<size>/apps/heimdallm.png"
	@echo ""
	@echo "    Launch with: heimdallm  (or via your app launcher)"
	@case ":$$PATH:" in \
	  *":$$HOME/.local/bin:"*) ;; \
	  *) echo ""; \
	     echo "⚠  $$HOME/.local/bin is not on your PATH."; \
	     echo "   Add this to ~/.bashrc or ~/.zshrc:"; \
	     echo "     export PATH=\"\$$HOME/.local/bin:\$$PATH\"" ;; \
	esac
```

**Critical formatting:**
- Every recipe line (anything indented under `install-linux:`) begins with a literal **TAB**. Single TAB per line, no spaces.
- `$$VAR` (double-dollar) in Makefile = `$VAR` in shell (e.g. `$$HOME`, `$$PATH`, `$${SIZE}`, `$$(docker create …)`, `$$CID`).
- `$(EXTRACT_DIR)` is a **Make** variable reference (single dollar) — defined once at the top of the block so both the recipe body and any future consumers reference the same path.
- The `docker create` / `docker cp` / `docker rm` block is one multi-line shell statement joined with `\` so the `trap` installs the cleanup handler that runs even if either `cp` fails. Do NOT break it into separate recipe lines — each Make recipe line is a fresh shell, and the trap wouldn't span them.
- The `&&` between the two `docker cp` calls ensures that if the first `cp` fails, the second does not run and the trap still fires to remove the container. If you write `;` instead of `&&`, a failing first `cp` would cascade into a confusing second-cp error.
- Inside the `docker create` block, `$$CID` (double-dollar) captures the container ID in a shell variable; the subsequent `"$$CID:/app/..."` references interpolate it. Writing `$(CID)` instead would make Make look for a non-existent Make variable and silently produce an empty string.

- [ ] **Step 2: Dry-run the target to catch syntax errors**

```bash
make -n install-linux
```

Expected: Make prints commands for `verify-linux` (docker build), the Docker-extract block, and the staging steps. No `*** missing separator` or `*** recipe commences before first target` errors. The `$(EXTRACT_DIR)` references should have expanded to `/tmp/heimdallm-install-extract` in the dry-run output.

If you see a Make syntax error, it's almost always TAB vs. spaces — re-check the recipe body with `sed -n '<line-range>p' Makefile | cat -A` and confirm every body line starts with `^I`.

- [ ] **Step 3: Run the target end-to-end on Linux**

```bash
make install-linux
```

Expected sequence:
1. `verify-linux` runs. If the `heimdallm-verify` image doesn't exist yet, Docker builds it now — this takes ~5 minutes the first time (pulling ubuntu:22.04, installing deps, Go 1.21, Flutter, then running tests + building). Subsequent runs are seconds (Docker layer cache).
2. `▶  Extracting Heimdallm artifacts from heimdallm-verify image...` — the `docker create`/`cp`/`rm` block runs. The `docker cp` lines are silent because they're under `@`.
3. `▶  Staging Heimdallm into $HOME/.local/opt/heimdallm...` — the staging `rm -rf`/`mkdir`/`cp`/`chmod` lines echo to the terminal.
4. Final report:
   ```
   ✅  Heimdallm installed:
       Bundle:  /home/<user>/.local/opt/heimdallm/
       Symlink: /home/<user>/.local/bin/heimdallm
       Desktop: /home/<user>/.local/share/applications/com.theburrowhub.heimdallm.desktop
       Icons:   /home/<user>/.local/share/icons/hicolor/<size>x<size>/apps/heimdallm.png

       Launch with: heimdallm  (or via your app launcher)
   ```

- [ ] **Step 4: Verify install artifacts on disk**

```bash
ls -la ~/.local/opt/heimdallm/heimdallm ~/.local/opt/heimdallm/heimdalld
ls -la ~/.local/bin/heimdallm
cat ~/.local/share/applications/com.theburrowhub.heimdallm.desktop
ls ~/.local/share/icons/hicolor/{48x48,128x128,256x256,512x512}/apps/heimdallm.png
ls /tmp/heimdallm-install-extract 2>&1 | head -1
```

Expected:
- Both `heimdallm` and `heimdalld` present, executable (`-rwxr-xr-x`), and **different file sizes** (collision guard passed).
- `~/.local/bin/heimdallm` is a symlink (first column starts with `l`) pointing at `~/.local/opt/heimdallm/heimdallm`.
- The `.desktop` file has `Exec=` with an absolute path into the bundle.
- All four icon files exist.
- `/tmp/heimdallm-install-extract` does NOT exist (cleaned up by step 7 of the install spec). If it does, the cleanup step misfired — check the recipe.

Confirm no orphaned Docker containers from the install:

```bash
docker ps -a --filter "ancestor=heimdallm-verify" --format "{{.ID}} {{.Status}}"
```

Expected: empty output — the trap removed the extraction container.

- [ ] **Step 5: Launch the app**

```bash
heimdallm &
sleep 5
curl -s http://localhost:7842/health
```

Expected: Flutter window opens. `curl` returns `{"status":"ok"}`.

Close the app window before moving on.

- [ ] **Step 6: Verify idempotence**

```bash
make install-linux
```

Expected: `verify-linux` re-runs (fast — layer cache hits); extract + stage rerun cleanly; same final report. The recipe's `rm -rf` on both the extract dir and the bundle dir ensures overwrites are clean.

- [ ] **Step 7: Commit**

```bash
git add Makefile
git commit -m "$(cat <<'EOF'
feat(make): add install-linux (reuses verify-linux Docker build)

install-linux: _check-linux verify-linux

Extracts the Flutter bundle and Go daemon from the heimdallm-verify
image (verify-linux builds it) via docker create + docker cp + docker rm,
then stages into ~/.local/opt/heimdallm/ with a ~/.local/bin symlink,
a desktop entry with an absolute Exec= path, and the four icon sizes
under ~/.local/share/icons/hicolor/. Fills the host-install gap left
by verify-linux (Docker-only) and run-linux (in-container runtime).

Layout mirrors the CI .deb so DaemonLifecycle's "heimdalld next to
heimdallm" lookup works unchanged. No host Flutter toolchain required.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add the `uninstall-linux` target

**Files:**
- Modify: `Makefile` (append below `install-linux`, still before `clean`)

- [ ] **Step 1: Insert the `uninstall-linux` recipe**

Directly after the end of the `install-linux` recipe from Task 2 (the last line of the `case` block), insert:

```make

# ── Native Linux uninstall ────────────────────────────────────────────────────
#
# Removes everything install-linux created under ~/.local/, but preserves
# user configuration (~/.config/heimdallm) and runtime data
# (~/.local/share/heimdallm) by default.
#
# Usage:
#   make uninstall-linux              # app only — config and data preserved
#   make uninstall-linux PURGE=1      # also wipes ~/.config + ~/.local/share state
#
# The PURGE flag mirrors Debian's `apt remove` vs. `apt purge` distinction.

uninstall-linux: _check-linux
	@echo "▶  Uninstalling Heimdallm from $$HOME/.local/..."
	@# Stop running instances (best-effort — ignored if nothing is running,
	@# prevents "Text file busy" on the bundle on step 5).
	@pkill -f "$$HOME/.local/opt/heimdallm/heimdallm" 2>/dev/null || true
	@pkill -f "$$HOME/.local/opt/heimdallm/heimdalld" 2>/dev/null || true
	@rm -f "$$HOME/.local/share/heimdallm/ui.pid"
	rm -f "$$HOME/.local/share/applications/com.theburrowhub.heimdallm.desktop"
	@for SIZE in 48 128 256 512; do \
	  rm -f "$$HOME/.local/share/icons/hicolor/$${SIZE}x$${SIZE}/apps/heimdallm.png"; \
	done
	@# Only remove the PATH shim if it's our symlink — never clobber an
	@# unrelated file that happens to share the name.
	@if [ -L "$$HOME/.local/bin/heimdallm" ]; then \
	  TARGET=$$(readlink "$$HOME/.local/bin/heimdallm"); \
	  case "$$TARGET" in \
	    "$$HOME/.local/opt/heimdallm/"*) \
	      rm -f "$$HOME/.local/bin/heimdallm"; \
	      echo "↓  Removed $$HOME/.local/bin/heimdallm" ;; \
	    *) \
	      echo "⚠  $$HOME/.local/bin/heimdallm points to $$TARGET — leaving it alone." ;; \
	  esac; \
	elif [ -e "$$HOME/.local/bin/heimdallm" ]; then \
	  echo "⚠  $$HOME/.local/bin/heimdallm exists but is not a symlink — leaving it alone."; \
	fi
	rm -rf "$$HOME/.local/opt/heimdallm"
	@# Refresh launcher caches so the stale entry disappears from menus.
	@command -v update-desktop-database >/dev/null 2>&1 && \
	  update-desktop-database "$$HOME/.local/share/applications/" 2>/dev/null || true
	@command -v gtk-update-icon-cache >/dev/null 2>&1 && \
	  gtk-update-icon-cache -q -t "$$HOME/.local/share/icons/hicolor/" 2>/dev/null || true
	@if [ "$(PURGE)" = "1" ]; then \
	  echo ""; \
	  echo "⚠  PURGE=1 — wiping user config and runtime data..."; \
	  rm -rf "$$HOME/.config/heimdallm"; \
	  rm -rf "$$HOME/.local/share/heimdallm"; \
	  echo "    Removed $$HOME/.config/heimdallm"; \
	  echo "    Removed $$HOME/.local/share/heimdallm"; \
	  echo ""; \
	  echo "✅  Heimdallm fully uninstalled (config and data wiped)."; \
	else \
	  echo ""; \
	  echo "✅  Heimdallm uninstalled (config and data preserved)."; \
	  echo ""; \
	  echo "    Config: $$HOME/.config/heimdallm/"; \
	  echo "    Data:   $$HOME/.local/share/heimdallm/"; \
	  echo ""; \
	  echo "    To wipe these too: make uninstall-linux PURGE=1"; \
	fi
```

Same tab-indentation rule as Task 2.

- [ ] **Step 2: Dry-run the target**

```bash
make -n uninstall-linux
```

Expected: Make prints the commands it would run, no `*** missing separator` errors.

- [ ] **Step 3: Run uninstall after a prior install**

Assuming Task 2 ran `make install-linux` and did not run the cleanup, now run:

```bash
make uninstall-linux
```

Expected:
```
▶  Uninstalling Heimdallm from /home/<user>/.local/...
↓  Removed /home/<user>/.local/bin/heimdallm

✅  Heimdallm uninstalled (config and data preserved).

    Config: /home/<user>/.config/heimdallm/
    Data:   /home/<user>/.local/share/heimdallm/

    To wipe these too: make uninstall-linux PURGE=1
```

- [ ] **Step 4: Verify app artifacts are gone but state survives**

```bash
ls ~/.local/opt/heimdallm/ 2>&1                                     # should: No such file
ls ~/.local/bin/heimdallm 2>&1                                       # should: No such file
ls ~/.local/share/applications/com.theburrowhub.heimdallm.desktop 2>&1  # should: No such file
ls ~/.local/share/icons/hicolor/128x128/apps/heimdallm.png 2>&1     # should: No such file
ls -ld ~/.config/heimdallm 2>&1                                      # should: directory exists (if app was ever launched)
ls -ld ~/.local/share/heimdallm 2>&1                                 # should: directory exists
```

Note on config/data: if you never launched the app, `~/.config/heimdallm/` may not exist — that's fine. The target does not create it; it only preserves it if present.

- [ ] **Step 5: Test the `PURGE=1` path**

Reinstall and then purge:

```bash
make install-linux
# launch briefly so daemon creates its state, then quit
heimdallm &
sleep 5
pkill -f ~/.local/opt/heimdallm/heimdallm || true

ls ~/.config/heimdallm ~/.local/share/heimdallm
# both exist

make uninstall-linux PURGE=1
```

Expected output includes:
```
⚠  PURGE=1 — wiping user config and runtime data...
    Removed /home/<user>/.config/heimdallm
    Removed /home/<user>/.local/share/heimdallm

✅  Heimdallm fully uninstalled (config and data wiped).
```

Verify:
```bash
ls ~/.config/heimdallm 2>&1         # should: No such file
ls ~/.local/share/heimdallm 2>&1    # should: No such file
```

- [ ] **Step 6: Test the never-installed scenario**

On a machine (or the current one post-purge) where nothing was installed:

```bash
make uninstall-linux
```

Expected: runs without errors. No "file not found" messages (all `rm` commands use `-f`, and the `pkill`s are `|| true`). Final report prints the "app uninstalled" message even though nothing was there to remove — this is acceptable and matches the spec's "harmless no-op" contract.

- [ ] **Step 7: Test the unrelated-file guard**

```bash
# Simulate an unrelated file at the PATH shim location
rm -f ~/.local/bin/heimdallm
echo '#!/bin/sh' > ~/.local/bin/heimdallm
chmod +x ~/.local/bin/heimdallm

make uninstall-linux
```

Expected: the target does NOT delete the dummy file; it prints:
```
⚠  /home/<user>/.local/bin/heimdallm exists but is not a symlink — leaving it alone.
```

Verify:
```bash
cat ~/.local/bin/heimdallm   # still prints: #!/bin/sh
rm -f ~/.local/bin/heimdallm # cleanup test fixture
```

- [ ] **Step 8: Commit**

```bash
git add Makefile
git commit -m "$(cat <<'EOF'
feat(make): add uninstall-linux with PURGE flag for native install removal

uninstall-linux            # app only — config and data preserved
uninstall-linux PURGE=1    # also wipes ~/.config + ~/.local/share state

Symmetric with install-linux. Symlink-check on ~/.local/bin/heimdallm
prevents accidental removal of unrelated files. PURGE mirrors Debian's
`apt remove` vs. `apt purge` distinction.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: End-to-end manual walk-through on a clean environment

This task runs every scenario in the spec's §5 testing plan back-to-back. Purpose: catch any cross-interaction between install and uninstall that the per-task tests missed.

**Prerequisites:** Linux host with Docker installed and running (same requirement as `make verify-linux` / `make run-linux`). No Flutter / Go / GTK dev toolchain needed — the Docker build handles everything.

**First-run note:** if `heimdallm-verify` image does not exist yet, `make install-linux` will build it. Budget ~5 minutes for the first run. Subsequent runs hit Docker's layer cache and finish in seconds.

- [ ] **Step 1: Capture clean-state baseline**

```bash
ls -la ~/.local/opt/heimdallm ~/.local/bin/heimdallm ~/.local/share/applications/com.theburrowhub.heimdallm.desktop 2>&1 | head -20
```

Record which (if any) are already present. If `install-linux` never ran on this machine, none should exist.

- [ ] **Step 2: Fresh install**

```bash
make install-linux
```

Verify all four path groups from the spec §5 test 1.

- [ ] **Step 3: Launch from terminal + launcher integration**

```bash
heimdallm &
sleep 5
curl -s http://localhost:7842/health
```

Expected: `{"status":"ok"}`. Close the app window.

Check that the app appears in your OS app launcher (GNOME overview, KDE app menu, etc.). If `update-desktop-database` wasn't on your system, you may need to re-login for the launcher to pick it up.

- [ ] **Step 4: Reinstall idempotence**

```bash
make install-linux
```

Expected: runs cleanly, identical final report, app still works.

- [ ] **Step 5: Uninstall (app only)**

```bash
make uninstall-linux
```

Verify app paths gone, config/data preserved (spec §5 test 5).

- [ ] **Step 6: Reinstall + purge**

```bash
make install-linux
heimdallm &
sleep 5
pkill -f ~/.local/opt/heimdallm/heimdallm || true
make uninstall-linux PURGE=1
```

Verify all app paths AND config/data are gone (spec §5 test 6).

- [ ] **Step 7: Uninstall on clean machine**

```bash
make uninstall-linux
```

Verify no errors (spec §5 test 7).

- [ ] **Step 8: Unrelated-binary at PATH location**

```bash
echo '#!/bin/sh' > ~/.local/bin/heimdallm
chmod +x ~/.local/bin/heimdallm
make uninstall-linux
cat ~/.local/bin/heimdallm    # still contains #!/bin/sh
rm -f ~/.local/bin/heimdallm
```

Verify the warning appears and the file is untouched (spec §5 test 8).

- [ ] **Step 9: No commit**

This task is validation-only. If all steps passed, the branch is ready for PR. If any step failed, pause and decide whether to:
- Fix forward (amend the responsible task's commits on this branch).
- Roll back (`git revert` the responsible commit and redesign).

Do not introduce "manual-testing" commits — nothing changed in the tree.

---

## Self-review checklist — completed

- **Spec coverage.**
  - §1 layout → covered by Task 2's recipe (bundle, symlink, desktop entry, icon paths all match).
  - §2 install steps 1–12 (including the new Docker-extract steps 2–3 and the extraction-dir cleanup at step 7) → covered by Task 2 step 1 recipe body, in order.
  - §3 uninstall steps 1–8 (+ PURGE) → covered by Task 3 step 1 recipe body.
  - §4 error handling → `_check-linux` (Task 1), Docker preflight (Task 2 recipe), `verify-linux` failure surface (inherited from that target), trap-based container cleanup (Task 2 recipe), case-collision guard (Task 2 recipe), PATH warning (Task 2 recipe), symlink-only removal (Task 3 recipe).
  - §5 manual test plan → covered step-by-step by Task 4.
- **Placeholder scan.** No TBD/TODO/"implement later". Every recipe body is complete code, every verification step names the expected output.
- **Type / name consistency.**
  - Target name `install-linux` and `uninstall-linux` consistent across `.PHONY`, recipe definitions, commit messages, and manual-test commands.
  - `EXTRACT_DIR := /tmp/heimdallm-install-extract` defined once in the install block and referenced via `$(EXTRACT_DIR)` throughout the recipe.
  - Image name `heimdallm-verify` consistent with `verify-linux` and `run-linux`.
  - Symlink target path `$HOME/.local/opt/heimdallm/heimdallm` consistent between install (creates it), uninstall (checks it with `readlink`), and spec.
  - Desktop entry filename `com.theburrowhub.heimdallm.desktop` identical in install, uninstall, and CI staging (verified in spec).
  - Icon sizes `{48, 128, 256, 512}` identical in install loop, uninstall loop, and the source `flutter_app/assets/icons/` directory (verified with `ls`).
