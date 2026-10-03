#!/bin/bash
# Baut ChatMix und installiert es in den Programme-Ordner.
# Aufruf: bash install.sh
set -e
cd "$(dirname "$0")"

APP_NAME="ChatMix.app"
BUNDLE_ID="local.chatmix"
BUILD_DIR="$(mktemp -d)"
APP="$BUILD_DIR/$APP_NAME"
trap 'rm -rf "$BUILD_DIR"' EXIT

# Zielordner: /Applications, falls nicht beschreibbar ~/Applications
DEST="/Applications"
if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

# 1. Voraussetzungen
if ! command -v swiftc >/dev/null; then
    echo "Die Apple Command Line Tools fehlen. Starte Installation ..."
    xcode-select --install || true
    echo "Bitte nach Abschluss der Installation 'bash install.sh' erneut ausführen."
    exit 1
fi

# 2. Bauen
echo "▶︎ Baue ChatMix ..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -swift-version 5 -parse-as-library ChatMix.swift -o "$APP/Contents/MacOS/ChatMix"
codesign --force --sign - "$APP" >/dev/null 2>&1

# 3. Laufende Version beenden
if pgrep -x ChatMix >/dev/null; then
    echo "▶︎ Beende laufendes ChatMix ..."
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    sleep 1
    pkill -x ChatMix 2>/dev/null || true
fi

# 4. Installieren
echo "▶︎ Installiere nach $DEST ..."
rm -rf "$DEST/$APP_NAME"
cp -R "$APP" "$DEST/$APP_NAME"
xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

# 5. Audio-Berechtigung zurücksetzen, damit macOS für den neuen Build sauber fragt
tccutil reset AudioCapture "$BUNDLE_ID" >/dev/null 2>&1 || true

# 6. Starten
open "$DEST/$APP_NAME"

echo ""
echo "✅ ChatMix ist installiert: $DEST/$APP_NAME"
echo "   Das Symbol erscheint oben in der Menüleiste."
echo "   Wenn macOS fragt, ob ChatMix Systemaudio aufnehmen darf: bitte erlauben."
echo "   Den heruntergeladenen Ordner kannst du jetzt löschen."
