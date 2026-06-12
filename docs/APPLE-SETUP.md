# Apple-Setup: Push + TestFlight (einmalig, ~10 Minuten mit Ali)

Zwei Dinge kann nur Ali mit seinem Apple-Konto (2FA) erledigen. Alles andere ist
vorbereitet und springt danach sofort an.

## 1. APNs-Key erzeugen (für „Claude wartet"-Pushes aufs iPhone)

1. https://developer.apple.com/account → **Certificates, Identifiers & Profiles → Keys**
2. **+** → Name `Humibeam Push` → Haken bei **Apple Push Notifications service (APNs)** → Continue → Register
3. **Download** der `.p8`-Datei (geht nur einmal!) und die **Key ID** notieren
4. Datei auf den Server legen und Dienst neu starten:
   ```
   scp AuthKey_XXXXXXXXXX.p8 ali@alpvis.com:~/humibeam-push/AuthKey.p8
   ssh ali@alpvis.com "sed -i 's/\"keyId\": \"\"/\"keyId\": \"XXXXXXXXXX\"/' ~/humibeam-push/config.json && sudo systemctl restart humibeam-push"
   ```
   (Das Relay selbst installiert `server/push-relay/install.sh`, einmal auf dem Server ausführen.)
5. Das beim Install erzeugte **Secret** (steht in `~/humibeam-push/config.json`) in beide Apps eintragen:
   - Mac: Einstellungen → Anpassen → iPhone-Push
   - iPhone: Serverliste → Zahnrad → Push

## 2. TestFlight (App aufs echte iPhone, auch für Freunde)

1. https://appstoreconnect.apple.com → **Apps → +** → Neue App:
   Plattform iOS, Name `Humibeam`, Bundle-ID `app.humibeam.ios` (vorher unter
   Identifiers anlegen, falls nicht angeboten), SKU `humibeam-ios`
2. Am Mac in Xcode anmelden: **Xcode → Settings → Accounts → +** → Apple-ID ali@uelkue.at
3. Dann reicht künftig ein Befehl:
   ```
   ./tools/testflight.sh
   ```
4. In App Store Connect → TestFlight: Ali als internen Tester hinzufügen → Einladung
   aufs iPhone → fertig. (Familie/Freunde: als externe Tester einladen.)

## Status der Vorbereitung

- ✅ Push-Relay-Code: `server/push-relay/` (Installation: `install.sh` auf dem Server)
- ✅ Mac sendet an Relay (Einstellungen → iPhone-Push)
- ✅ iOS registriert sich beim Relay und empfängt Pushes (sobald Entitlement aktiv)
- ✅ `HumibeamiOS/Humibeam.entitlements` (aps-environment) vorhanden
- ✅ `tools/testflight.sh` (Archiv + Upload, automatisches Signing)
- ⏳ APNs-Key (.p8) — Schritt 1
- ⏳ App-Record + Xcode-Login — Schritt 2
