#!/bin/bash
# Builds Meeting Notes.app — a real double-clickable Mac app.
set -e
cd "$(dirname "$0")"

APP="Meeting Notes.app"
BIN="MeetingNotes"

echo "Compiling…"
rm -rf "$APP" "$BIN"
swiftc -O -parse-as-library Sources/*.swift -o "$BIN"

echo "Packaging…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/$BIN"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Meeting Notes</string>
    <key>CFBundleDisplayName</key>       <string>Meeting Notes</string>
    <key>CFBundleExecutable</key>        <string>MeetingNotes</string>
    <key>CFBundleIdentifier</key>        <string>com.sikiru.meetingnotes</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>26.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Meeting Notes records your meetings so it can write up the notes. The audio never leaves this Mac.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Meeting Notes turns your recording into text. This happens on this Mac.</string>
</dict>
</plist>
PLIST

if [ -f AppIcon.icns ]; then cp AppIcon.icns "$APP/Contents/Resources/"; fi

echo "Signing…"
codesign --force --deep --sign - "$APP" 2>/dev/null || codesign --force --sign - "$APP"

echo
echo "Built:  $(pwd)/$APP"
echo "Open it with:   open \"$APP\""
