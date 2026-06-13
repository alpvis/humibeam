#!/bin/bash
set -euo pipefail
# Baut "Humibeam Support" (Kunden-App fürs Remote-Support) universal, signiert mit Developer-ID,
# als notarisiertes DMG. Voraussetzung: Developer-ID-Zertifikat + Notar-Profil im Keychain.

SIGN_IDENTITY="${HUMIBEAM_SIGN_IDENTITY:-Developer ID Application: Ali Uelkue (DC289RNL2G)}"
NOTARY_PROFILE="${HUMIBEAM_NOTARY_PROFILE:-humibeam-notary}"
UNIVERSAL_ARCHS="arm64 x86_64"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/HumibeamMac"
DERIVED="$SCRIPT_DIR/.dd-support-rel"
ENTITLEMENTS="$SCRIPT_DIR/HumibeamSupport/HumibeamSupport.entitlements"
cd "$PROJECT_DIR"

echo "⚙️  Generiere Projekt…"; xcodegen generate >/dev/null

echo "🔨 Baue Humibeam Support (Release, universal)…"
xcodebuild \
  -project HumibeamMac.xcodeproj \
  -scheme HumibeamSupport \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  ONLY_ACTIVE_ARCH=NO ARCHS="$UNIVERSAL_ARCHS" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  DEVELOPMENT_TEAM=DC289RNL2G \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  clean build

APP_SRC="$DERIVED/Build/Products/Release/Humibeam Support.app"
[ -d "$APP_SRC" ] || { echo "❌ Build fehlgeschlagen"; exit 1; }

DEST="$SCRIPT_DIR/Humibeam Support.app"
rm -rf "$DEST"; cp -R "$APP_SRC" "$DEST"

echo "🔏 Signiere (hardened runtime, inkl. WebRTC.framework)…"
# Eingebettete Frameworks zuerst (inside-out), dann die App.
find "$DEST/Contents/Frameworks" -name "*.framework" -maxdepth 1 2>/dev/null | while read -r fw; do
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$fw"
done
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$DEST"
codesign --verify --deep --strict --verbose=1 "$DEST"

echo "📦 Erstelle DMG…"
DMG="$SCRIPT_DIR/HumibeamSupport.dmg"
STAGE="$(mktemp -d)/Humibeam Support"; mkdir -p "$STAGE"
cp -R "$DEST" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Humibeam Support" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"

echo "📤 Notarisiere (1–5 Min)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler staple "$DEST" || true
echo "✅ Fertig: $DMG"
spctl -a -vvv "$DEST" 2>&1 | head -3 || true
