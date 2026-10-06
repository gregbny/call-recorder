#!/usr/bin/env bash
# Pre-downloads the FluidAudio CoreML diarization models from Hugging Face.
# Run ONCE with network access; afterwards diarization works 100% offline
# (DiarizerModels.load never touches the network).
set -euo pipefail

REPO="FluidInference/speaker-diarization-coreml"
DEST="${1:-$HOME/.call-recorder/models/speaker-diarization-coreml}"
BASE="https://huggingface.co"

# Only these two bundles are required by DiarizerModels.load(local…)
BUNDLES=("pyannote_segmentation.mlmodelc" "wespeaker_v2.mlmodelc")

echo "==> Models: $REPO"
echo "==> Destination: $DEST"
mkdir -p "$DEST"

# Recursive file listing via the Hugging Face API
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
    echo "Error: no files downloaded (Hugging Face repo layout changed?)" >&2
    exit 1
fi

# Minimal check: the loader looks for coremldata.bin in each bundle
for bundle in "${BUNDLES[@]}"; do
    if [[ ! -f "$DEST/$bundle/coremldata.bin" ]]; then
        echo "Error: $bundle/coremldata.bin missing after download" >&2
        exit 1
    fi
done

echo "✅ $count files downloaded. Speaker identification ready (app toggle or call-recorder --diarize)"
