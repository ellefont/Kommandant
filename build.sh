#!/bin/zsh
# Baut Kommandant.app (Release) im Projektordner.
set -euo pipefail
cd "$(dirname "$0")"

APP="Kommandant.app"
VERSION="$(cat VERSION)"   # Versionsnummer: in der Datei VERSION pflegen
BUILD="$(date +%Y%m%d%H%M)"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/de.lproj"
cp .build/release/Kommandant "$APP/Contents/MacOS/Kommandant"

ICONSET=.build/Kommandant.iconset
swift Scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo '"CFBundleDisplayName" = "Kommandant";' > "$APP/Contents/Resources/de.lproj/InfoPlist.strings"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Kommandant</string>
    <key>CFBundleDisplayName</key><string>Kommandant</string>
    <key>CFBundleIdentifier</key><string>de.kommandant.dateimanager</string>
    <key>CFBundleExecutable</key><string>Kommandant</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleDevelopmentRegion</key><string>de</string>
    <key>CFBundleLocalizations</key><array><string>de</string></array>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSDesktopFolderUsageDescription</key><string>Kommandant zeigt und verwaltet die Dateien auf deinem Schreibtisch.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Kommandant zeigt und verwaltet die Dateien in deinem Dokumente-Ordner.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Kommandant zeigt und verwaltet die Dateien in deinem Downloads-Ordner.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>Kommandant zeigt und verwaltet Dateien auf Wechseldatenträgern.</string>
    <key>NSAppleEventsUsageDescription</key><string>Kommandant bittet den Finder, den Papierkorb zu leeren.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>Kommandant zeigt und verwaltet Dateien auf Netzwerkvolumes.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Fertig: $(pwd)/$APP (Version $VERSION)"
