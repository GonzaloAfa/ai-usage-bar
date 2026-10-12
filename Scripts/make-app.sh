#!/bin/bash
# Empaqueta el ejecutable de SwiftPM como una app de barra de menú.
#
# SwiftPM produce un binario suelto; para que macOS lo trate como app sin ícono en el Dock hace falta
# un bundle con Info.plist. Copiar el resultado a /Applications es un paso manual (ver README).
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="AIUsageBar"
BUNDLE_ID="cl.alisonvivanco.ai-usage-bar"
VERSION="${VERSION:-1.0}"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Compilando en release"
swift build -c release --product "$APP_NAME"
BINARY="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"

echo "==> Armando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

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

# Con una identidad de Developer ID se firma para distribuir (hardened runtime y sello de tiempo, que
# son requisitos de la notarización). Sin ella, firma ad-hoc: sirve para uso local, no para repartir.
if [ -n "${SIGN_IDENTITY:-}" ]; then
	echo "==> Firmando con $SIGN_IDENTITY"
	codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
	codesign --verify --strict --verbose=2 "$APP"
else
	echo "==> Firmando (ad-hoc, sólo para uso local)"
	codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
fi

echo
echo "Listo: $APP"
echo
echo "Para instalarlo:"
echo "  cp -R \"$APP\" /Applications/ && open /Applications/$APP_NAME.app"
