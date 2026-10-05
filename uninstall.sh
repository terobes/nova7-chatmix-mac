#!/bin/bash
# Entfernt ChatMix vollständig.
# Aufruf: bash uninstall.sh
BUNDLE_ID="local.chatmix"

osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
sleep 1
pkill -x ChatMix 2>/dev/null || true

for dir in /Applications "$HOME/Applications"; do
    if [ -d "$dir/ChatMix.app" ]; then
        rm -rf "$dir/ChatMix.app" && echo "Entfernt: $dir/ChatMix.app"
    fi
done

defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset AudioCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "✅ ChatMix wurde entfernt (inkl. Einstellungen und Berechtigung)."
echo "   Falls du „Beim Anmelden starten“ aktiviert hattest, verschwindet der Eintrag nach dem nächsten Neustart."
