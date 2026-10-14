#!/bin/zsh
# Baut Kommandant.dmg: klassisches Drag-&-Drop-Installationsfenster (App → Programme).
set -euo pipefail
cd "$(dirname "$0")"

APP="Kommandant.app"
VOL="Kommandant"
DMG="Kommandant.dmg"
WORK=.build/dmg
STAGE="$WORK/stage"

[[ -d "$APP" ]] || ./build.sh

rm -rf "$WORK" "$DMG"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Programme"

swift Scripts/make-dmg-background.swift "$WORK/bg.png" "$WORK/bg@2x.png"
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null

# Detach a leftover volume with the same name
if [[ -d "/Volumes/$VOL" ]]; then hdiutil detach "/Volumes/$VOL" -force >/dev/null || true; fi

hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg" >/dev/null
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | awk '/Apple_HFS/ {print $1}')
MOUNT="/Volumes/$VOL"


osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 520}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "$APP" of container window to {170, 200}
        set position of item "Programme" of container window to {490, 200}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

# Volume icon – added after the Finder step, which removes it otherwise
cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"

chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach "$DEVICE" >/dev/null
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -rf "$WORK"
echo "Fertig: $(pwd)/$DMG"
