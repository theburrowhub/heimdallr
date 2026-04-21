# Native Linux Install Target — Design Spec

**Date**: 2026-04-21
**Scope**: New `install-linux` and `uninstall-linux` Makefile targets for building and installing Heimdallm natively on Linux, user-local, outside a container.

---

## Context

The repo currently offers two Linux-related Makefile targets:

- `verify-linux` — builds the `heimdallm-verify` Docker image (runs the full CI pipeline inside).
- `run-linux` — launches the Flutter bundle *from inside that image* over host X11/DBus.

CI (`.github/workflows/release.yml` → `build-linux`) produces `.deb`, `.rpm`, and `.AppImage` for end users, and `LLM-HOW-TO-INSTALL.md` documents the download-and-install flow against those release artifacts.

Missing: a path for developers who have this repo cloned, have the Linux build toolchain installed, and want to compile + install natively without Docker. `build-daemon` and `build-app` produce artifacts in `daemon/bin/` and `flutter_app/build/linux/…`, but nothing embeds the daemon into the bundle, places binaries on the system, or creates launcher integration.

This spec fills that gap.

---

## Decisions

The design questions answered during brainstorming:

| Question | Decision |
|---|---|
| Installation scope | **User-local** (`~/.local/…`) — no sudo, reversible, single-user. |
| Build responsibility | **Make dependency graph**: `install-linux: build-daemon build-app`. Incremental rebuilds for free, same idiom as the existing `install-service` on macOS. |
| Uninstall companion | **Yes** — `uninstall-linux` removes app; `PURGE=1` also wipes config and data. Mirrors Debian `apt remove` vs. `apt purge`. |

---

## 1. Install layout

```
~/.local/opt/heimdallm/                            # bundle root
├── heimdallm                                      # Flutter binary (entry point)
├── heimdalld                                      # Go daemon (renamed from daemon/bin/heimdallm)
├── data/                                          # Flutter assets (flutter_assets, icudtl.dat, …)
└── lib/                                           # libapp.so, libflutter_linux_gtk.so, …

~/.local/bin/heimdallm                             # → symlink to ~/.local/opt/heimdallm/heimdallm

~/.local/share/applications/
    com.theburrowhub.heimdallm.desktop             # Exec= is absolute path into the bundle

~/.local/share/icons/hicolor/{48,128,256,512}x{same}/apps/heimdallm.png
```

Key properties:

- **Layout mirrors CI's `/opt/heimdallm/`.** `DaemonLifecycle.defaultBinaryPath()` in `daemon_lifecycle.dart` resolves the daemon as `heimdalld` next to the Flutter binary — the CI `.deb` satisfies this, and so does this user-local install. No app-code change required.
- **`~/.local/share/heimdallm/` is reserved** as the daemon's runtime data directory (created by `make run-linux`, written to by the daemon at runtime). The install target must not place anything there; the uninstall target must not remove it except under `PURGE=1`.
- **Desktop entry `Exec=` is absolute** (the expanded value of `$HOME/.local/opt/heimdallm/heimdallm`). `%h` is not a standard Desktop Entry field code and not all launchers expand it.

---

## 2. `install-linux` target

Declaration:

```make
install-linux: build-daemon build-app
```

Make's dependency graph rebuilds `daemon/bin/heimdallm` and the Flutter Linux bundle only when their inputs changed. The recipe body runs only the staging/install steps.

Steps (all idempotent — every rerun leaves the same end state):

1. **Preflight.** Assert `uname -s` is Linux via a new `_check-linux` guard. On macOS, print: "This target requires Linux. On macOS, use `make release-local` or `make run-linux`." and exit 1. Mirrors the existing `_check-macos`.
2. **Verify build artifacts.** `[ -d flutter_app/build/linux/x64/release/bundle ] && [ -f daemon/bin/heimdallm ]` — fail with which artifact is missing. Defends against the (rare) case where `build-app` / `build-daemon` report success but the expected path isn't there.
3. **Stage the bundle.** `rm -rf ~/.local/opt/heimdallm && mkdir -p ~/.local/opt/heimdallm && cp -r flutter_app/build/linux/x64/release/bundle/. ~/.local/opt/heimdallm/`.
4. **Embed the daemon.** `cp daemon/bin/heimdallm ~/.local/opt/heimdallm/heimdalld && chmod +x ~/.local/opt/heimdallm/heimdalld`. Note the rename — source is `heimdallm`, destination is `heimdalld` — matching CI staging and `daemon_lifecycle.dart`'s lookup.
5. **Case-collision guard.** `cmp -s ~/.local/opt/heimdallm/heimdallm ~/.local/opt/heimdallm/heimdalld` must report a difference; if bytes match, fail with "Both binaries are identical — would fork-bomb on launch". Same guard CI's release pipeline uses; protects against a silently-broken rename.
6. **PATH shim.** `mkdir -p ~/.local/bin && ln -sf ~/.local/opt/heimdallm/heimdallm ~/.local/bin/heimdallm`. `ln -sf` atomically replaces any prior symlink.
7. **Icons.** For each size in `{48, 128, 256, 512}`: `mkdir -p ~/.local/share/icons/hicolor/<N>x<N>/apps/ && cp flutter_app/assets/icons/<N>.png ~/.local/share/icons/hicolor/<N>x<N>/apps/heimdallm.png`.
8. **Desktop entry.** Write `~/.local/share/applications/com.theburrowhub.heimdallm.desktop` (contents below, with `$$HOME` expanded at Make-recipe-execution time, not stored as `%h`):
   ```ini
   [Desktop Entry]
   Name=Heimdallm
   Comment=AI-powered GitHub PR review agent
   Exec=<expanded $HOME>/.local/opt/heimdallm/heimdallm
   Icon=heimdallm
   Type=Application
   Categories=Development;
   StartupWMClass=com.theburrowhub.heimdallm
   StartupNotify=true
   ```
9. **Refresh caches (best-effort).**
   - `command -v update-desktop-database >/dev/null && update-desktop-database ~/.local/share/applications/ 2>/dev/null || true`
   - `command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t ~/.local/share/icons/hicolor/ 2>/dev/null || true`
   - Silent no-op if the tools aren't installed. The app appears in the launcher either way after a re-login; the refresh just makes it immediate.
10. **Final report.** Print:
    - The four path groups written (bundle, bin symlink, desktop entry, icons).
    - A "Launch with: `heimdallm` (or from your app launcher)" hint.
    - **If `~/.local/bin` is not on `$PATH`**, a warning plus the snippet `export PATH="$HOME/.local/bin:$PATH"` and a reminder to add it to `~/.bashrc` / `~/.zshrc`. Detection: `case ":$$PATH:" in *":$$HOME/.local/bin:"*) ;; *) warn ;; esac`.

No output suppression via `@` on the core staging commands — users should see what's happening. `@echo` is fine for informational banners.

---

## 3. `uninstall-linux` target

Declaration:

```make
uninstall-linux:           # app only — config and data preserved
uninstall-linux PURGE=1    # also wipes ~/.config/heimdallm and ~/.local/share/heimdallm
```

Steps:

1. **Preflight.** Same `_check-linux` guard.
2. **Stop running instances.** Best-effort:
   - `pkill -f "$$HOME/.local/opt/heimdallm/heimdallm" 2>/dev/null || true` (stops running Flutter binary, which in turn terminates its child daemon).
   - `pkill -f "$$HOME/.local/opt/heimdallm/heimdalld" 2>/dev/null || true` (also stops an orphaned daemon if the Flutter app crashed earlier).
   - Remove stale UI PID file: `rm -f ~/.local/share/heimdallm/ui.pid` (the file itself, not the directory).
   - Avoids "Text file busy" on step 4 when rewriting the bundle.
3. **Remove desktop entry and icons.**
   - `rm -f ~/.local/share/applications/com.theburrowhub.heimdallm.desktop`
   - `rm -f ~/.local/share/icons/hicolor/{48,128,256,512}x{same}/apps/heimdallm.png`
4. **Remove PATH shim — only if it's our symlink.** Guard with `[ -L ~/.local/bin/heimdallm ]` and `readlink` resolving into `~/.local/opt/heimdallm/`. Never clobber an unrelated file named `heimdallm` that happens to live there. If the symlink is ours, `rm -f` it; otherwise print a warning and leave it alone.
5. **Remove bundle directory.** `rm -rf ~/.local/opt/heimdallm/`.
6. **Refresh caches (best-effort).** Same `update-desktop-database` and `gtk-update-icon-cache` calls as install — lets launchers drop the stale entry.
7. **Purge (only when `PURGE=1`).**
   - `rm -rf ~/.config/heimdallm/`
   - `rm -rf ~/.local/share/heimdallm/`
   - Print a loud warning that user data was wiped.
   - Never prompt interactively — Make recipes can't assume a TTY.
8. **Final report.**
   - List removed paths.
   - If `PURGE` was not set, print a note that `~/.config/heimdallm/` and `~/.local/share/heimdallm/` still exist, with the `make uninstall-linux PURGE=1` command to wipe them.

Key safety properties:

- **Never-installed machine.** The symlink check in step 4, and the `-f` on every `rm`, mean running `uninstall-linux` on a machine where `install-linux` never ran is a harmless no-op. No "file not found" errors.
- **Unrelated `~/.local/bin/heimdallm`.** If the user (or another tool) put a different binary at that path, step 4 detects it and leaves it alone.
- **Partial install state.** If a prior `install-linux` failed mid-way, `uninstall-linux` still cleans up whatever subset of paths got written.

---

## 4. Error handling & edge cases

- **Not Linux.** `_check-linux` fails fast with a platform-specific message redirecting to `release-local` / `run-linux`. Same shape as `_check-macos`.
- **Flutter not installed / build deps missing.** Handled by `build-app` itself — Flutter emits a clear error naming the missing dep (`libgtk-3-dev`, `clang`, etc.). The install target does not reimplement this check; our preflight only verifies that *artifacts exist* post-build, which is a faster and more reliable signal than duck-typing the toolchain.
- **Case-collision guard trips.** Fatal. The staged bundle is left in place (not on the user's `$PATH` yet — that's step 6, after the guard). User fixes and reruns; step 3 starts with `rm -rf`, so state is clean.
- **`~/.local/bin` not on `$PATH`.** Warning only, not an error. The symlink is still created; the desktop entry uses an absolute `Exec=` path, so launcher menu integration works regardless. User can still launch via `~/.local/opt/heimdallm/heimdallm`.
- **Already installed.** `install-linux` overwrites cleanly: `rm -rf` on the bundle dir, `ln -sf` on the symlink, fresh desktop entry / icons. No version-check logic — source installs always reflect current `HEAD`.
- **Daemon running at install time.** `rm -rf ~/.local/opt/heimdallm/` while the daemon is running is safe on Linux (unlinks the directory entry; the running process continues on its now-unlinked inode until it exits normally). The install target does *not* stop running processes — a rebuild-reinstall during active use won't interrupt a review in progress. Stopping processes is the `uninstall-linux` job.

---

## 5. Manual testing plan

This target interacts with the user's filesystem and launcher. No automated test covers it — the validation is a manual walk-through:

1. **Fresh install.** On a Linux machine with no prior Heimdallm install: `make install-linux`. Verify:
   - `~/.local/opt/heimdallm/heimdallm` and `…/heimdalld` exist, both executable.
   - `~/.local/bin/heimdallm` is a symlink into the bundle.
   - `~/.local/share/applications/com.theburrowhub.heimdallm.desktop` exists and has absolute `Exec=`.
   - Four icon sizes present under `~/.local/share/icons/hicolor/…/apps/heimdallm.png`.
   - App launcher / GNOME overview shows "Heimdallm" (may require re-login if `update-desktop-database` wasn't available).
2. **Launch from terminal.** `heimdallm &`. Verify the Flutter app opens, daemon starts, `curl -s http://localhost:7842/health` returns `{"status":"ok"}`.
3. **Launch from launcher.** Click the app in the OS launcher — same startup sequence.
4. **Reinstall (idempotence).** `make install-linux` a second time. No error, no duplicate state, final report identical.
5. **Uninstall (app only).** `make uninstall-linux`. Verify:
   - All four path groups from step 1 are gone.
   - `~/.config/heimdallm/` and `~/.local/share/heimdallm/` still exist.
6. **Reinstall + purge.** `make install-linux && make uninstall-linux PURGE=1`. Verify step-1 paths gone AND `~/.config/heimdallm/` and `~/.local/share/heimdallm/` gone.
7. **Uninstall on clean machine.** `make uninstall-linux` on a machine where install-linux never ran. Verify no errors, no unexpected deletions.
8. **Unrelated `~/.local/bin/heimdallm` at uninstall time.** Replace the install's symlink with a regular file (e.g. `rm ~/.local/bin/heimdallm && echo '#!/bin/sh' > ~/.local/bin/heimdallm`), then run `make uninstall-linux`. Verify the symlink-check in step 4 kicks in: the unrelated file is left untouched and the target prints a warning naming it. (Note: the install step's `ln -sf` *will* clobber a pre-existing regular file at that path — this is standard behavior for a CLI install, not something the target guards against.)

---

## Out of scope

- **System-wide install** (`/opt/heimdallm/`, `/usr/local/bin/heimdallm`). Developers who want that path should use the CI-built `.deb` / `.rpm`.
- **Build from source on non-Debian/non-RPM distros** without Flutter pre-installed. The target assumes `flutter` and the Linux desktop build deps are already present — installing those is a one-time user setup, not something this target attempts to automate.
- **Automatic daemon autostart / systemd unit.** The Flutter app spawns the daemon itself (`daemon_lifecycle.dart`); no separate service file is needed for the install path. `install-service` on macOS creates a LaunchAgent, but Linux doesn't need one for the spawn-from-app model.
- **Verifying `flutter build linux` runs green.** That's `make verify-linux`'s job. This target trusts the build succeeded if the artifact exists.
