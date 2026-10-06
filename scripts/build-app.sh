#!/usr/bin/env bash
# Construit Call Recorder.app à partir du binaire SPM CallRecorderMenuBar.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Call Recorder"
BUNDLE_ID="local.call-recorder.menubar"
VERSION="0.2.0"
BINARY="CallRecorderMenuBar"

echo "==> swift build -c release"
swift build -c release

APP="build/${APP_NAME}.app"
echo "==> Construction du bundle $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/$BINARY" "$APP/Contents/MacOS/$BINARY"

echo "==> Génération de l'icône"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift scripts/generate-icon.swift "$ICONSET/icon_1024.png"
# Tailles requises par iconutil
for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONSET/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$ICONSET/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
cp "$ICONSET/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
rm "$ICONSET/icon_1024.png"
iconutil --convert icns --output "build/AppIcon.icns" "$ICONSET"
cp "build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>fr</string>
    <key>CFBundleExecutable</key>
    <string>${BINARY}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Call Recorder enregistre votre micro pendant les appels.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Call Recorder transcrit vos enregistrements localement.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Codesign ad-hoc"
codesign --sign - --force --deep "$APP"

echo ""
echo "✅ Bundle construit : $APP"
echo ""
echo "Pour installer :"
echo "  mv \"$APP\" /Applications/"
echo "  open \"/Applications/${APP_NAME}.app\""
