#!/bin/bash
# Copiator.app paketini derler ve hazırlar (varsayılan: evrensel arm64 + x86_64).
#
# Ortam değişkenleri:
#   RSYNC_DIR     Pakete eklenecek rsync klasörü (varsayılan: Vendor/rsync)
#   CONFIG        debug | release (varsayılan: release)
#   ARCHS         Derlenecek mimariler (varsayılan: "arm64 x86_64"; yalnızca bu Mac için: ARCHS=native)
#   SIGN_IDENTITY İmza kimliği (varsayılan: "-", ad-hoc). Ör. "Developer ID Application: Ad (TAKIM)";
#                 ad-hoc dışındaki kimliklerde noter onayı için sertleştirilmiş çalışma zamanı ve zaman damgası eklenir.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RSYNC_DIR="${RSYNC_DIR:-$ROOT/Vendor/rsync}"
CONFIG="${CONFIG:-release}"
ARCHS="${ARCHS:-arm64 x86_64}"
APP="$ROOT/build/Copiator.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then SIGN_ARGS+=(--options runtime --timestamp); fi

BUILD_ARGS=(-c "$CONFIG" --package-path "$ROOT")
if [ "$ARCHS" != "native" ]; then
  for arch in $ARCHS; do BUILD_ARGS+=(--arch "$arch"); done
fi

echo "▸ Swift paketi derleniyor ($CONFIG, ${ARCHS})…"
swift build "${BUILD_ARGS[@]}" --product Copiator
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

# Kestirmeler ve Siri (App Intents) meta verisi. Derleyici sabit değerleri (*.swiftconstvalues) üretir; Xcode'un derleme
# sırasında yaptığı gibi bunlardan Metadata.appintents paketini appintentsmetadataprocessor oluşturur. Meta veri mimariden
# bağımsızdır; derlenen ilk mimarinin dosyaları kullanılır.
echo "▸ Kestirmeler meta verisi üretiliyor…"
CONFIG_DIR="$(printf '%s' "${CONFIG:0:1}" | tr '[:lower:]' '[:upper:]')${CONFIG:1}"
if [ "$ARCHS" = "native" ]; then META_ARCH="$(uname -m)"; else META_ARCH="${ARCHS%% *}"; fi
OBJ_DIR="$ROOT/.build/out/Intermediates.noindex/Copiator.build/$CONFIG_DIR/Copiator-p.build/Objects-normal/$META_ARCH"
INTENTS_DIR="$ROOT/.build/appintents"
rm -rf "$INTENTS_DIR"
mkdir -p "$INTENTS_DIR"
find "$OBJ_DIR" -maxdepth 1 -name "*.swiftconstvalues" > "$INTENTS_DIR/constvalues.txt" 2>/dev/null || true
if [ ! -s "$INTENTS_DIR/constvalues.txt" ] || [ ! -f "$OBJ_DIR/Copiator.SwiftFileList" ]; then
  echo "⚠ Sabit değer dosyaları bulunamadı ($OBJ_DIR); Kestirmeler meta verisi üretilemedi." >&2
  exit 1
fi
TOOLCHAIN_DIR="$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")"
MIN_MACOS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$ROOT/Support/Info.plist")"
xcrun appintentsmetadataprocessor \
  --output "$INTENTS_DIR" \
  --toolchain-dir "$TOOLCHAIN_DIR" \
  --module-name Copiator \
  --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
  --platform-family macOS \
  --deployment-target "$MIN_MACOS" \
  --target-triple "$META_ARCH-apple-macos$MIN_MACOS" \
  --source-file-list "$OBJ_DIR/Copiator.SwiftFileList" \
  --swift-const-vals-list "$INTENTS_DIR/constvalues.txt" \
  --force >/dev/null 2>"$INTENTS_DIR/processor.log" || { cat "$INTENTS_DIR/processor.log" >&2; exit 1; }
[ -d "$INTENTS_DIR/Metadata.appintents" ] || { echo "⚠ Metadata.appintents üretilmedi." >&2; cat "$INTENTS_DIR/processor.log" >&2; exit 1; }

if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
  echo "▸ Uygulama simgesi çiziliyor…"
  swift "$ROOT/Scripts/make_icon.swift" "$ROOT/Resources/AppIcon.icns"
fi

echo "▸ Paket hazırlanıyor…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Copiator" "$APP/Contents/MacOS/Copiator"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/"*.lproj "$APP/Contents/Resources/"
cp -R "$INTENTS_DIR/Metadata.appintents" "$APP/Contents/Resources/Metadata.appintents"
# rsync güncelleyicisi kaynaktan derler: iki betik birlikte gider.
for script in update-rsync.sh build-rsync.sh; do
  cp "$ROOT/Scripts/$script" "$APP/Contents/Resources/$script"
  chmod 755 "$APP/Contents/Resources/$script"
done
cp "$ROOT/LICENSE" "$APP/Contents/Resources/Copiator-License.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Third-Party-Notices.txt"

if [ -x "$RSYNC_DIR/rsync" ]; then
  echo "▸ rsync motoru ekleniyor: $RSYNC_DIR/rsync"
  cp "$RSYNC_DIR/rsync" "$APP/Contents/MacOS/rsync"
  cp "$RSYNC_DIR/COPYING" "$APP/Contents/Resources/rsync-License.txt"
  cp "$RSYNC_DIR/SOURCE.txt" "$APP/Contents/Resources/rsync-SOURCE.txt"
  codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/rsync"
else
  echo "⚠ $RSYNC_DIR/rsync bulunamadı. Önce ./Scripts/build-rsync.sh çalıştırın." >&2
  exit 1
fi

if [ "$SIGN_IDENTITY" = "-" ]; then echo "▸ Ad-hoc imzalanıyor…"; else echo "▸ İmzalanıyor: $SIGN_IDENTITY"; fi
codesign "${SIGN_ARGS[@]}" "$APP"
echo "▸ Mimariler: $(lipo -archs "$APP/Contents/MacOS/Copiator")"
echo "✓ Hazır: $APP"
