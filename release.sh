#!/bin/bash
# Veröffentlicht eine neue humibeam-Version, damit installierte Kopien sich per Auto-Update
# (UpdateService → appcast.json) selbst aktualisieren.
#
#   ./release.sh <version> <build> "Was ist neu"
#   Beispiel:  ./release.sh 2.1 21 "SFTP Drag-out, Diktat-Knopf, Host-Key-Pinning"
#
# Voraussetzungen: Developer-ID + Notary-Profil (für ./build.sh --notarize) und `gh` angemeldet.
set -euo pipefail

VERSION="${1:?Version fehlt (z.B. 2.1)}"
BUILD="${2:?Build-Nummer fehlt (z.B. 21)}"
NOTES="${3:-Neue Version $VERSION}"
TAG="v$VERSION"
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

echo "▶︎ Setze Version $VERSION (Build $BUILD) in project.yml"
/usr/bin/sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"$VERSION\"/" HumibeamMac/project.yml
/usr/bin/sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: \"$BUILD\"/" HumibeamMac/project.yml

echo "▶︎ Baue notarisierte DMG (Release)"
./build.sh --release --dmg --notarize

DMG=$(/usr/bin/find "$DIR" -maxdepth 2 -name "*.dmg" -print0 | xargs -0 ls -t | head -1)
[ -n "$DMG" ] || { echo "❌ keine DMG gefunden"; exit 1; }
# Auf den vom appcast erwarteten Namen kopieren
cp "$DMG" "$DIR/Humibeam.dmg"

echo "▶︎ Aktualisiere appcast.json"
cat > appcast.json <<JSON
{
  "version": "$VERSION",
  "build": $BUILD,
  "dmgURL": "https://github.com/alpvis/humibeam/releases/download/$TAG/Humibeam.dmg",
  "notes": "$NOTES",
  "minOS": "13.0"
}
JSON

echo "▶︎ GitHub-Release $TAG anlegen + DMG hochladen"
gh release create "$TAG" "$DIR/Humibeam.dmg" --title "humibeam $VERSION" --notes "$NOTES"

echo "▶︎ appcast.json + Version committen & pushen"
git add appcast.json HumibeamMac/project.yml
git commit -m "Release $VERSION (build $BUILD)"
git push origin main

echo "✅ Release $VERSION veröffentlicht. Installierte Kopien aktualisieren sich beim nächsten Check."
