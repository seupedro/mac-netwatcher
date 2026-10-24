#!/bin/sh
# Compila o Netwatch em build/Netwatch.app (binario universal: Apple Silicon
# e Intel). Nao instala nada; para isso, scripts/instalar.sh.
set -eu
cd "$(dirname "$0")/.."
ID=${NETWATCH_ID:-xyz.paralaxe.netwatch}
VERSAO=$(cat VERSION)
APP=build/Netwatch.app
mkdir -p "$APP/Contents/MacOS" build/arm64 build/x86_64
for arq in arm64 x86_64; do
  # -wmo: o modulo inteiro de uma vez (mais inline, binario menor)
  swiftc -O -wmo -swift-version 5 -target $arq-apple-macos14.0 \
    -Xlinker -dead_strip Sources/*.swift -o build/$arq/netwatch
done
lipo -create build/arm64/netwatch build/x86_64/netwatch -output "$APP/Contents/MacOS/netwatch"
strip -x "$APP/Contents/MacOS/netwatch"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>Netwatch</string>
  <key>CFBundleDisplayName</key><string>Netwatch</string>
  <key>CFBundleExecutable</key><string>netwatch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSAO</string>
  <key>CFBundleVersion</key><string>$VERSAO</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PL
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "ok: $APP $VERSAO ($(stat -f %z "$APP/Contents/MacOS/netwatch") bytes)"
