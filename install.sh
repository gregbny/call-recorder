#!/usr/bin/env bash
# Installation complète de Call Recorder sur ce Mac :
# vérifie les prérequis, compile, signe (ad-hoc), installe l'app + la CLI,
# télécharge les modèles de diarization, puis lance l'app.
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
step "Vérification des prérequis"

macos_major=$(sw_vers -productVersion | cut -d. -f1)
[[ "$macos_major" -ge 26 ]] || fail "macOS 26 (Tahoe) ou plus requis — version actuelle : $(sw_vers -productVersion)"
ok "macOS $(sw_vers -productVersion)"

if [[ "$(uname -m)" == "arm64" ]]; then
    ok "Apple Silicon"
else
    warn "Mac Intel détecté : non testé (Apple Intelligence et le Neural Engine ne seront pas disponibles)"
fi

if ! xcode-select -p >/dev/null 2>&1; then
    warn "Command Line Tools absents — ouverture de l'installeur Apple…"
    xcode-select --install || true
    fail "Terminez l'installation des Command Line Tools, puis relancez : bash install.sh"
fi
ok "Command Line Tools : $(xcode-select -p)"

swift_version=$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -1)
[[ -n "$swift_version" ]] || fail "Impossible de lire la version de Swift"
swift_major=${swift_version%%.*}
swift_minor=${swift_version#*.}
if (( swift_major < 6 || (swift_major == 6 && swift_minor < 2) )); then
    fail "Swift 6.2+ requis (actuel : $swift_version). Mettez à jour les Command Line Tools via Réglages Système > Mise à jour logicielle."
fi
ok "Swift $swift_version"

# ---------------------------------------------------------------------------
step "Compilation et construction de l'app (quelques minutes la première fois)"
bash scripts/build-app.sh
codesign --sign - --force .build/release/call-recorder
ok "Compilation terminée et binaires signés localement"

# ---------------------------------------------------------------------------
step "Installation de l'app"

# Quitte une éventuelle instance en cours avant de la remplacer
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
step "Installation de la ligne de commande"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
cp .build/release/call-recorder "$BIN_DIR/call-recorder"
ok "$BIN_DIR/call-recorder"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        warn "$BIN_DIR n'est pas dans votre PATH. Ajoutez-le avec :"
        echo "      echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
        ;;
esac

# ---------------------------------------------------------------------------
step "Téléchargement des modèles de diarization (~13 Mo)"
if bash scripts/download-models.sh; then
    ok "Modèles installés"
else
    warn "Échec du téléchargement — la diarization sera désactivée. Relancez plus tard : bash scripts/download-models.sh"
fi

# ---------------------------------------------------------------------------
step "Terminé 🎉"
cat <<EOF

    L'icône Call Recorder apparaît dans la barre de menu (en haut à droite).

    Au premier enregistrement, macOS demandera 3 autorisations — acceptez-les :
      • Microphone
      • Enregistrement de l'écran et de l'audio système (nécessaire pour capter Teams)
      • Reconnaissance vocale
    Si l'une n'apparaît pas : Réglages Système > Confidentialité et sécurité,
    activez « Call Recorder », puis quittez et relancez l'app.

    Les comptes-rendus sont enregistrés dans ~/Recordings.

EOF

open "$DEST_APP"
