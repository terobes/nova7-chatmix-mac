#!/bin/bash
# Veröffentlicht nova7-chatmix-mac als öffentliches GitHub-Repository.
# Einmal ausführen: bash publish.sh
set -e
cd "$(dirname "$0")"

REPO="nova7-chatmix-mac"
DESC="ChatMix dial support for the SteelSeries Arctis Nova 7 Wireless Gen 2 on macOS – menu bar app, no drivers"

# 1. GitHub CLI installieren und anmelden (Anmeldung läuft im Browser)
if ! command -v gh >/dev/null; then
    echo "Installiere GitHub CLI ..."
    brew install gh
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "Anmeldung bei GitHub – folge den Schritten, es öffnet sich der Browser."
    gh auth login --web --git-protocol https
fi

LOGIN=$(gh api user -q .login)
ID=$(gh api user -q .id)
NAME=$(gh api user -q '.name // .login')
EMAIL="${ID}+${LOGIN}@users.noreply.github.com"   # anonyme GitHub-Adresse
echo "Angemeldet als: $LOGIN"

if gh repo view "$LOGIN/$REPO" >/dev/null 2>&1; then
    echo "Das Repository $LOGIN/$REPO gibt es schon – Abbruch."
    exit 1
fi

# 2. Benutzernamen ins README eintragen
sed -i '' "s/GITHUB_USER/$LOGIN/g" README.md

# 3. Git-Repository anlegen
rm -rf .git
git init -q -b main
git add -A
git -c user.name="$NAME" -c user.email="$EMAIL" commit -q -m "Initial release: ChatMix for Arctis Nova 7 Gen 2 on macOS

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011jbLCHy37H4Au8Ju3AGWxB"

# 4. Öffentliches Repository erstellen und hochladen
gh repo create "$REPO" --public --description "$DESC" --source=. --remote=origin --push
gh repo edit "$LOGIN/$REPO" --add-topic macos,swift,steelseries,arctis-nova-7,chatmix,menubar-app,core-audio

# 5. Release mit Änderungsprotokoll anlegen
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
gh release create "v$VERSION" --title "ChatMix $VERSION" --notes-file CHANGELOG.md

echo ""
echo "Fertig: https://github.com/$LOGIN/$REPO"
