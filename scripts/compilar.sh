#!/bin/sh
# Compila o Mac Netwatcher em "build/Mac Netwatcher.app" (binario universal:
# Apple Silicon e Intel). Nao instala nada; para isso, scripts/instalar.sh.
set -eu
cd "$(dirname "$0")/.."
ID=${NETWATCH_ID:-xyz.paralaxe.netwatch}
VERSAO=$(cat VERSION)
APP="build/Mac Netwatcher.app"
EXE=mac-netwatcher
mkdir -p "$APP/Contents/MacOS" build/arm64 build/x86_64
for arq in arm64 x86_64; do
  # -wmo: o modulo inteiro de uma vez (mais inline, binario menor)
  swiftc -O -wmo -swift-version 5 -target $arq-apple-macos14.0 \
    -Xlinker -dead_strip Sources/*.swift -o build/$arq/$EXE
done
lipo -create build/arm64/$EXE build/x86_64/$EXE -output "$APP/Contents/MacOS/$EXE"
strip -x "$APP/Contents/MacOS/$EXE"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>Mac Netwatcher</string>
  <key>CFBundleDisplayName</key><string>Mac Netwatcher</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSAO</string>
  <key>CFBundleVersion</key><string>$VERSAO</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 seupedro · MIT License</string>
</dict>
</plist>
PL
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "ok: $APP $VERSAO ($(stat -f %z "$APP/Contents/MacOS/$EXE") bytes)"
