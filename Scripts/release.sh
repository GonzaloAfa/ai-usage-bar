#!/bin/bash
# Prepara la app para repartirla: la firma con Developer ID, la empaqueta en un DMG y la notariza.
#
# El resultado se abre con doble clic en cualquier Mac. Sin notarizar, macOS avisa que no puede
# comprobar el software y obliga a abrirla con clic derecho la primera vez.
#
# Hace falta correrlo en una máquina con Apple Developer Program:
#
#   1. Un certificado «Developer ID Application» instalado en el llavero. Se comprueba con:
#        security find-identity -v -p codesigning | grep "Developer ID Application"
#
#   2. Un perfil de notarización guardado una sola vez:
#        xcrun notarytool store-credentials "ai-usage-bar" \
#          --apple-id <correo de la cuenta> --team-id <TEAMID> --password <app-specific password>
#      La contraseña específica se crea en appleid.apple.com, no es la del Apple ID.
#
#      En CI se usa en su lugar una clave de API de App Store Connect, por variables de entorno:
#        NOTARY_KEY_PATH (archivo .p8), NOTARY_KEY_ID y NOTARY_ISSUER_ID
#
#   Uso:  Scripts/release.sh [versión]
#   Perfil distinto:  NOTARY_PROFILE=otro-perfil Scripts/release.sh 1.1
#
# El binario sale universal (Apple Silicon e Intel); ARCHS="arm64" lo limita a una arquitectura.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="AIUsageBar"
VOLUME_NAME="AI Usage Bar"
VERSION="${1:-1.0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ai-usage-bar}"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
STAGE="$BUILD_DIR/dmg"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
ARCHS="${ARCHS:-arm64 x86_64}"

if [ -n "${NOTARY_KEY_PATH:-}" ]; then
	NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?falta NOTARY_KEY_ID}" \
		--issuer "${NOTARY_ISSUER_ID:?falta NOTARY_ISSUER_ID}")
else
	NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
fi

# ---------------------------------------------------------------- comprobaciones

if [ -z "${SIGN_IDENTITY:-}" ]; then
	# `|| true`: que no haya certificado es un caso previsto y merece un mensaje, no una muerte
	# silenciosa por el grep vacío bajo `set -e`.
	SIGN_IDENTITY=$(security find-identity -v -p codesigning \
		| { grep "Developer ID Application" || true; } \
		| head -1 \
		| sed -n 's/.*"\(.*\)".*/\1/p')
fi

if [ -z "$SIGN_IDENTITY" ]; then
	cat <<'MESSAGE' >&2
No hay ningún certificado «Developer ID Application» en este llavero.

Es el único tipo de certificado que sirve para repartir la app fuera del App Store; el de tipo
«Apple Development» no vale, aunque aparezca en la lista. Se crea en:

    developer.apple.com → Certificates, Identifiers & Profiles → Certificates → +
    → Developer ID Application

Para armar el paquete sin firmar, sólo para uso local:  Scripts/make-app.sh
MESSAGE
	exit 1
fi

if ! xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1; then
	cat <<MESSAGE >&2
Las credenciales de notarización no sirven: ni el perfil «$NOTARY_PROFILE» ni la clave de API
(NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID) dejan consultar a Apple.

Se guardan una sola vez con:

    xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
      --apple-id <correo de la cuenta de desarrollador> \\
      --team-id <TEAMID> \\
      --password <app-specific password de appleid.apple.com>
MESSAGE
	exit 1
fi

# ---------------------------------------------------------------- empaquetado

echo "==> Versión $VERSION, firmando como: $SIGN_IDENTITY"
VERSION="$VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" ARCHS="$ARCHS" Scripts/make-app.sh

echo "==> Armando el DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# El atajo a Aplicaciones es lo que hace que se pueda arrastrar sin abrir otra ventana.
ln -s /Applications "$STAGE/Aplicaciones"

hdiutil create \
	-volname "$VOLUME_NAME" \
	-srcfolder "$STAGE" \
	-ov -quiet -format UDZO \
	"$DMG"

# El DMG también se firma: si no, Gatekeeper avisa del disco aunque la app dentro esté notarizada.
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

# ---------------------------------------------------------------- notarización

echo "==> Enviando a notarizar (Apple tarda entre uno y unos pocos minutos)"
xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait

# Grapar el resultado deja la aprobación dentro del archivo, para que valga sin consultar a Apple.
echo "==> Grapando el resultado"
xcrun stapler staple "$DMG"

echo "==> Comprobando como lo haría un Mac recién descargado"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

rm -rf "$STAGE"

echo
echo "Listo: $DMG"
echo "$(du -h "$DMG" | cut -f1) · firmado y notarizado · se abre con doble clic"
