#!/bin/bash
# Variante de make-app.sh para macOS 13 con las Command Line Tools 14.x (Swift 5.8).
#
# Ahí SwiftPM no arranca («unable to lookup item 'PlatformPath'»), así que se compila con swiftc:
# UsageCore como biblioteca estática y el ejecutable enlazado contra ella. El bundle resultante es
# el mismo que arma make-app.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="AIUsageBar"
BUNDLE_ID="cl.alisonvivanco.ai-usage-bar"
VERSION="${VERSION:-1.0}"
BUILD_DIR="build"
OBJ_DIR="$BUILD_DIR/swiftc"
APP="$BUILD_DIR/$APP_NAME.app"
TARGET="$(uname -m)-apple-macos13"

echo "==> Compilando UsageCore ($TARGET)"
rm -rf "$OBJ_DIR"
mkdir -p "$OBJ_DIR"
find Sources/UsageCore -name '*.swift' -print0 | xargs -0 swiftc -O -target "$TARGET" \
	-parse-as-library -static -emit-library -emit-module -module-name UsageCore \
	-o "$OBJ_DIR/libUsageCore.a" -emit-module-path "$OBJ_DIR/UsageCore.swiftmodule"

echo "==> Compilando $APP_NAME"
swiftc -O -target "$TARGET" -I "$OBJ_DIR" -L "$OBJ_DIR" -lUsageCore \
	-module-name "$APP_NAME" -o "$OBJ_DIR/$APP_NAME" Sources/AIUsageBar/*.swift

echo "==> Armando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OBJ_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>AI Usage Bar</string>
	<key>CFBundleDisplayName</key>
	<string>AI Usage Bar</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<!-- Sin ícono en el Dock ni conmutador de apps: vive sólo en la barra de menú. -->
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Uso personal</string>
</dict>
</plist>
PLIST

echo "==> Firmando (ad-hoc, sólo para uso local)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo
echo "Listo: $APP"
