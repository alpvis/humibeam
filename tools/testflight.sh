#!/bin/bash
# Baut die iOS-App als App-Store-Archiv und lädt sie zu TestFlight hoch.
#
# Voraussetzungen (einmalig, siehe docs/APPLE-SETUP.md):
#   1. App-Record "Humibeam" (app.humibeam.ios) in App Store Connect angelegt
#   2. In Xcode mit der Apple-ID angemeldet (Settings → Accounts) ODER
#      App-Store-Connect-API-Key unter ~/.appstoreconnect/private_keys/
#
# Nutzung: ./tools/testflight.sh [<ASC-API-Key-ID> <ASC-Issuer-ID>]
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR/HumibeamiOS"

ARCHIVE="$DIR/.build/Humibeam-ios.xcarchive"
EXPORT="$DIR/.build/ios-export"

xcodegen generate

echo "▶︎ Archiviere (Release, Gerät)…"
xcodebuild -scheme HumibeamiOS -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=DC289RNL2G \
  archive

cat > /tmp/humibeam-export-options.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>DC289RNL2G</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
EOF

echo "▶︎ Exportiere + lade zu App Store Connect hoch…"
if [ $# -ge 2 ]; then
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist /tmp/humibeam-export-options.plist \
    -exportPath "$EXPORT" \
    -allowProvisioningUpdates \
    -authenticationKeyID "$1" -authenticationKeyIssuerID "$2"
else
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist /tmp/humibeam-export-options.plist \
    -exportPath "$EXPORT" \
    -allowProvisioningUpdates
fi

echo "✅ Hochgeladen. In App Store Connect → TestFlight erscheint der Build nach der Verarbeitung (~10 Min)."
