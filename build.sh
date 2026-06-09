#!/bin/bash
set -euo pipefail

# Humibeam macOS App - Build & Run
# Voraussetzungen: Full Xcode with Command Line Tools, xcodegen

RUN_AFTER=false
INSTALL_APP=false
BUILD_CONFIGURATION="Release"
UNIVERSAL_ARCHS="arm64 x86_64"
MAKE_DMG=false
NOTARIZE=false
# Developer-ID-Signatur (notarisierbar, auf allen Geraeten vertraut). Per Env ueberschreibbar.
SIGN_IDENTITY="${HUMIBEAM_SIGN_IDENTITY:-Developer ID Application: Ali Uelkue (DC289RNL2G)}"
DEV_TEAM="${HUMIBEAM_TEAM:-DC289RNL2G}"
NOTARY_PROFILE="${HUMIBEAM_NOTARY_PROFILE:-humibeam-notary}"

for arg in "$@"; do
    case "$arg" in
        --debug)
            BUILD_CONFIGURATION="Debug"
            ;;
        --run)
            RUN_AFTER=true
            ;;
        --install)
            INSTALL_APP=true
            ;;
        --release)
            BUILD_CONFIGURATION="Release"
            ;;
        --dmg)
            MAKE_DMG=true
            ;;
        --notarize)
            NOTARIZE=true
            MAKE_DMG=true
            ;;
        *)
            echo "Unbekannte Option: $arg"
            echo "Verwendung: ./build.sh [--install] [--run] [--release] [--debug] [--dmg] [--notarize]"
            exit 1
            ;;
    esac
done

verify_universal_app() {
    local app_path="$1"
    local app_name
    local binary_path
    local archs

    app_name="$(basename "$app_path" .app)"
    binary_path="$app_path/Contents/MacOS/$app_name"

    if [ ! -f "$binary_path" ]; then
        echo "❌ Konnte App-Binary nicht finden: $binary_path"
        exit 1
    fi

    archs="$(lipo -archs "$binary_path" 2>/dev/null || true)"

    if [[ -z "$archs" ]]; then
        echo "❌ Konnte Architekturen nicht lesen: $binary_path"
        file "$binary_path" 2>/dev/null || true
        exit 1
    fi

    if [[ " $archs " != *" arm64 "* || " $archs " != *" x86_64 "* ]]; then
        echo "❌ Build ist nicht universal. Erwartet: arm64 + x86_64"
        echo "   Gefunden: $archs"
        file "$binary_path" 2>/dev/null || true
        exit 1
    fi

    echo "✅ Universal Binary verifiziert: $archs"
}

ensure_xcodebuild_available() {
    if xcodebuild -version >/dev/null 2>&1; then
        return
    fi

    local default_xcode="/Applications/Xcode.app/Contents/Developer"
    if [ -d "$default_xcode" ]; then
        export DEVELOPER_DIR="$default_xcode"
        if xcodebuild -version >/dev/null 2>&1; then
            echo "⚠️  Aktiver Developer-Pfad nutzt kein vollständiges Xcode. Verwende: $DEVELOPER_DIR"
            return
        fi
    fi

    echo "❌ xcodebuild ist nicht verfügbar."
    echo "   Installiere Xcode und wähle es mit:"
    echo "   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/HumibeamMac"
PROJECT_FILE="$PROJECT_DIR/HumibeamMac.xcodeproj"
DERIVED_DATA_PATH="$SCRIPT_DIR/.derivedData-humibeammac-build"
cd "$PROJECT_DIR"

ensure_xcodebuild_available

if command -v xcodegen &> /dev/null; then
    echo "⚙️  Generiere Xcode-Projekt ..."
    xcodegen generate 2>&1
elif [ -d "$PROJECT_FILE" ]; then
    echo "⚠️  xcodegen nicht gefunden – nutze vorhandenes Xcode-Projekt."
else
    echo "❌ xcodegen fehlt."
    echo "   Installiere xcodegen explizit mit:"
    echo "   brew install xcodegen"
    echo "   Oder stelle sicher, dass $PROJECT_FILE vorhanden ist."
    exit 1
fi

# Signatur-Fallback: ohne passendes Zertifikat lokal ad-hoc signieren,
# damit `./build.sh --run` auch ohne Developer-ID durchläuft.
TIMESTAMP_FLAG="--timestamp"
if [ "$SIGN_IDENTITY" != "-" ] && ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    echo "⚠️  Signatur '$SIGN_IDENTITY' nicht im Keychain – nutze Ad-hoc-Signatur (nur lokal, nicht notarisierbar)."
    SIGN_IDENTITY="-"
fi
if [ "$SIGN_IDENTITY" = "-" ]; then
    DEV_TEAM=""
    TIMESTAMP_FLAG=""
fi

# Bauen
echo "🔨 Baue Humibeam ..."
xcodebuild \
    -project HumibeamMac.xcodeproj \
    -scheme HumibeamMac \
    -destination 'platform=macOS' \
    -configuration "$BUILD_CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="$UNIVERSAL_ARCHS" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$DEV_TEAM" \
    OTHER_CODE_SIGN_FLAGS="$TIMESTAMP_FLAG" \
    clean build

# App finden
APP_PATH="$DERIVED_DATA_PATH/Build/Products/$BUILD_CONFIGURATION/Humibeam.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Build fehlgeschlagen – keine App gefunden."
    exit 1
fi

verify_universal_app "$APP_PATH"

# Resources manuell ins Bundle kopieren (xcodegen kopiert sie nicht automatisch)
echo "📋 Kopiere Resources ..."
RESOURCES_DIR="$APP_PATH/Contents/Resources"
mkdir -p "$RESOURCES_DIR"
cp -f "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/" 2>/dev/null || true
cp -f "$PROJECT_DIR/Resources/menubar_icon.png" "$RESOURCES_DIR/" 2>/dev/null || true
cp -f "$PROJECT_DIR/Resources/menubar_icon@2x.png" "$RESOURCES_DIR/" 2>/dev/null || true

# In Projektordner kopieren
DEST="$SCRIPT_DIR/Humibeam.app"
rm -rf "$DEST"
cp -R "$APP_PATH" "$DEST"
ENTITLEMENTS="$PROJECT_DIR/Resources/HumibeamMac.entitlements"
echo "🔏 Signiere mit: $SIGN_IDENTITY"
codesign --force --deep --options runtime $TIMESTAMP_FLAG \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$DEST" 2>&1
verify_universal_app "$DEST"

RUN_TARGET="$DEST"

if [ "$INSTALL_APP" = true ]; then
    APPS_DIR="/Applications"
    INSTALL_DEST="$APPS_DIR/Humibeam.app"
    if [ ! -w "$APPS_DIR" ]; then
        echo "❌ /Applications ist nicht beschreibbar."
        echo "   Fuehre den Befehl mit passenden Rechten erneut aus oder ziehe die App manuell nach /Applications."
        exit 1
    fi
    rm -rf "$INSTALL_DEST"
    cp -R "$DEST" "$INSTALL_DEST"
    echo "🔏 Signiere installierte App ..."
    codesign --force --deep --options runtime $TIMESTAMP_FLAG \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$INSTALL_DEST" 2>&1
    verify_universal_app "$INSTALL_DEST"
    RUN_TARGET="$INSTALL_DEST"
fi

# Optional: DMG zum einfachen Verteilen auf andere Geraete erstellen
if [ "$MAKE_DMG" = true ]; then
    echo "📦 Erstelle DMG ..."
    DMG_PATH="$SCRIPT_DIR/Humibeam.dmg"
    STAGING_PARENT="$(mktemp -d)"
    STAGING="$STAGING_PARENT/Humibeam"
    mkdir -p "$STAGING"
    cp -R "$DEST" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    rm -f "$DMG_PATH"
    hdiutil create -volname "Humibeam" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
    rm -rf "$STAGING_PARENT"
    echo "✅ DMG erstellt: $DMG_PATH"
fi

# Optional: Notarisieren + Stapeln (App auf allen Geraeten ohne Warnung)
if [ "$NOTARIZE" = true ]; then
    echo "📤 Notarisiere (kann 1-5 Min dauern) ..."
    if xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1; then
        echo "📎 Stemple ..."
        xcrun stapler staple "$DMG_PATH" 2>&1 || true
        xcrun stapler staple "$DEST" 2>&1 || true
        [ "$INSTALL_APP" = true ] && xcrun stapler staple "$INSTALL_DEST" 2>&1 || true
        echo "✅ Notarisiert & gestapelt."
        spctl -a -vvv -t install "$DEST" 2>&1 | head -3 || true
    else
        echo "❌ Notarisierung fehlgeschlagen (Profil '$NOTARY_PROFILE' vorhanden?)."
    fi
fi

echo ""
echo "✅ Fertig! App liegt unter:"
echo "   $DEST"
if [ "$INSTALL_APP" = true ]; then
    echo "   $RUN_TARGET"
fi
echo ""
echo "Build-Typ: $BUILD_CONFIGURATION"
echo "Architekturen: $UNIVERSAL_ARCHS"
echo "Kompatibel: Apple Silicon + Intel (macOS 14+)"
echo ""
echo "Naechste Schritte:"
echo "1. App starten"
echo "2. Mikrofon erlauben"
echo "3. Fuer direktes Einfuegen zusaetzlich Bedienungshilfen erlauben"
echo "4. In Humibeam deinen eigenen OpenAI API Key eintragen"
echo "5. Loslegen und bei Bedarf im Code weiterbauen"
echo ""

# Optional: direkt starten
if [ "$RUN_AFTER" = true ]; then
    echo "🚀 Starte Humibeam ..."
    open "$RUN_TARGET"
fi
