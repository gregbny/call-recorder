#!/usr/bin/env bash
# Full Call Recorder install on this Mac:
# checks requirements, builds, signs (ad-hoc), installs the app + CLI,
# downloads the diarization models, then launches the app.
#
# Usage : bash install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="Call Recorder"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$1"; }
fail() { printf '\n\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
step "Checking requirements"

macos_major=$(sw_vers -productVersion | cut -d. -f1)
[[ "$macos_major" -ge 26 ]] || fail "macOS 26 (Tahoe) or later required — current version: $(sw_vers -productVersion)"
ok "macOS $(sw_vers -productVersion)"

if [[ "$(uname -m)" == "arm64" ]]; then
    ok "Apple Silicon"
else
    warn "Intel Mac detected: untested (no Neural Engine)"
fi

if ! xcode-select -p >/dev/null 2>&1; then
    warn "Command Line Tools missing — opening Apple's installer…"
    xcode-select --install || true
    fail "Finish installing the Command Line Tools, then run again: bash install.sh"
fi
ok "Command Line Tools : $(xcode-select -p)"

swift_version=$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -1)
[[ -n "$swift_version" ]] || fail "Could not read the Swift version"
swift_major=${swift_version%%.*}
swift_minor=${swift_version#*.}
if (( swift_major < 6 || (swift_major == 6 && swift_minor < 2) )); then
    fail "Swift 6.2+ required (current: $swift_version). Update the Command Line Tools via System Settings > Software Update."
fi
ok "Swift $swift_version"

# ---------------------------------------------------------------------------
step "Building the app (a few minutes the first time)"
bash scripts/build-app.sh
codesign --sign - --force .build/release/call-recorder
ok "Build complete, binaries signed locally"

# ---------------------------------------------------------------------------
step "Installing the app"

# Quit any running instance before replacing it
pkill -x CallRecorderMenuBar 2>/dev/null && sleep 1 || true

if [[ -w /Applications ]]; then
    APP_DIR="/Applications"
else
    APP_DIR="$HOME/Applications"
    mkdir -p "$APP_DIR"
fi
DEST_APP="$APP_DIR/$APP_NAME.app"
rm -rf "$DEST_APP"
cp -R "build/$APP_NAME.app" "$DEST_APP"
ok "$DEST_APP"

# ---------------------------------------------------------------------------
step "Installing the command line tool"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
cp .build/release/call-recorder "$BIN_DIR/call-recorder"
ok "$BIN_DIR/call-recorder"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        warn "$BIN_DIR is not in your PATH. Add it with:"
        echo "      echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
        ;;
esac

# ---------------------------------------------------------------------------
step "Downloading the diarization models (~13 MB)"
if bash scripts/download-models.sh; then
    ok "Models installed"
else
    warn "Download failed — speaker identification disabled. Retry later: bash scripts/download-models.sh"
fi

# ---------------------------------------------------------------------------
step "Done 🎉"
cat <<EOF

    The Call Recorder icon is now in the menu bar (top right).

    On the first recording, macOS asks for 3 permissions — accept them:
      • Microphone
      • Screen & System Audio Recording (needed to capture the call audio)
      • Speech Recognition
    If one doesn't show up: System Settings > Privacy & Security,
    enable "Call Recorder", then quit and relaunch the app.

    Transcripts are saved in ~/Recordings.

    Remember: always tell participants and get their consent before recording.

EOF

open "$DEST_APP"
