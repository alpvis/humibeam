#!/bin/bash
set -euo pipefail
# Humibeam Release-Automatik: baut notarisiert, erzeugt sauberes DMG,
# aktualisiert den Auto-Update-Feed und veröffentlicht das Release.
# Nutzung:  ./tools/release.sh <VERSION> <BUILD> "<Was ist neu>"
# Beispiel: ./tools/release.sh 1.7 17 "Neue Funktion XY"

VERSION="${1:?Usage: release.sh VERSION BUILD NOTES}"
BUILD="${2:?build number (ganze Zahl, hoeher als bisher)}"
NOTES="${3:-Update}"

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"
eval "$(/opt/homebrew/bin/brew shellenv zsh 2>/dev/null)" 2>/dev/null || true

# Login-Schluesselbund fuer notarytool entsperren (verhindert "profile not found").
# Passwort optional via Umgebungsvariable, NIE im Code:  HUMIBEAM_KEYCHAIN_PW=… ./tools/release.sh …
if [ -n "${HUMIBEAM_KEYCHAIN_PW:-}" ]; then
    security unlock-keychain -p "$HUMIBEAM_KEYCHAIN_PW" "$HOME/Library/Keychains/login.keychain-db" || true
fi

echo "🔖 Setze Version $VERSION ($BUILD) ..."
sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"$VERSION\"/" HumibeamMac/project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: \"$BUILD\"/" HumibeamMac/project.yml

echo "🔨 Baue + notarisiere App ..."
./build.sh --notarize

echo "📦 Erzeuge sauberes DMG aus gestapelter App ..."
STAGING="$(mktemp -d)/Humibeam"
mkdir -p "$STAGING"
cp -R Humibeam.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f Humibeam.dmg
hdiutil create -volname "Humibeam" -srcfolder "$STAGING" -ov -format UDZO Humibeam.dmg >/dev/null
rm -rf "$(dirname "$STAGING")"
xcrun notarytool submit Humibeam.dmg --keychain-profile "humibeam-notary" --wait
xcrun stapler staple Humibeam.dmg

echo "📰 Aktualisiere appcast.json ..."
cat > appcast.json <<JSON
{
  "version": "$VERSION",
  "build": $BUILD,
  "dmgURL": "https://github.com/alpvis/humibeam/releases/download/v$VERSION/Humibeam.dmg",
  "notes": "$NOTES",
  "minOS": "14.0"
}
JSON

echo "⬆️  Veröffentliche ..."
git add appcast.json HumibeamMac/project.yml
git -c user.email="ali@uelkue.at" -c user.name="Ali Uelkue" commit -m "Release $VERSION ($BUILD): $NOTES"
git push
gh release create "v$VERSION" Humibeam.dmg --title "Humibeam $VERSION" --notes "$NOTES"

echo "✅ Release v$VERSION veröffentlicht. Alle Nutzer bekommen das Update automatisch."
