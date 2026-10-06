#!/usr/bin/env bash
# Pré-télécharge les modèles CoreML de diarization (FluidAudio) depuis HuggingFace.
# À lancer UNE FOIS avec accès réseau ; ensuite call-recorder --diarize
# fonctionne 100% offline (DiarizerModels.load ne contacte jamais le réseau).
set -euo pipefail

REPO="FluidInference/speaker-diarization-coreml"
DEST="${1:-$HOME/.call-recorder/models/speaker-diarization-coreml}"
BASE="https://huggingface.co"

# Seuls ces deux bundles sont requis par DiarizerModels.load(local…)
BUNDLES=("pyannote_segmentation.mlmodelc" "wespeaker_v2.mlmodelc")

echo "==> Modèles : $REPO"
echo "==> Destination : $DEST"
mkdir -p "$DEST"

# Liste récursive des fichiers du repo via l'API HuggingFace
FILES=$(curl -fsSL "$BASE/api/models/$REPO/tree/main?recursive=true" \
    | python3 -c '
import json, sys
for entry in json.load(sys.stdin):
    if entry.get("type") == "file":
        print(entry["path"])
')

count=0
for path in $FILES; do
    for bundle in "${BUNDLES[@]}"; do
        if [[ "$path" == "$bundle"* ]]; then
            mkdir -p "$DEST/$(dirname "$path")"
            echo "  ↓ $path"
            curl -fsSL --retry 3 -o "$DEST/$path" "$BASE/$REPO/resolve/main/$path"
            count=$((count + 1))
        fi
    done
done

if [[ $count -eq 0 ]]; then
    echo "Erreur : aucun fichier téléchargé (structure du repo HuggingFace changée ?)" >&2
    exit 1
fi

# Vérification minimale : le loader cherche coremldata.bin dans chaque bundle
for bundle in "${BUNDLES[@]}"; do
    if [[ ! -f "$DEST/$bundle/coremldata.bin" ]]; then
        echo "Erreur : $bundle/coremldata.bin manquant après téléchargement" >&2
        exit 1
    fi
done

echo "✅ $count fichiers téléchargés. Diarization utilisable avec : call-recorder --diarize"
