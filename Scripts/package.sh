#!/bin/bash
# Copiator'ı dağıtıma hazır paketler: evrensel .app, .dmg, .dmg.sig ve SHA256SUMS.txt (rsync motoru dahil).
#
# Kullanım: package.sh [--skip-tests] [--update-rsync]
#   --skip-tests   Testleri çalıştırmadan paketle
#   --update-rsync Paketlemeden önce Vendor/rsync'i GitHub'daki son sürüme güncelle (kaynaktan derler)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_TESTS=1
UPDATE_ENGINE=0
for arg in "$@"; do
  case "$arg" in
    --skip-tests) RUN_TESTS=0 ;;
    --update-rsync) UPDATE_ENGINE=1 ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Bilinmeyen seçenek: $arg" >&2; exit 2 ;;
  esac
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Support/Info.plist")"
DIST="$ROOT/dist"
APP="$ROOT/build/Copiator.app"
NAME="Copiator-$VERSION"

if [ "$UPDATE_ENGINE" = 1 ]; then
  echo "▸ rsync güncelleniyor…"
  "$ROOT/Scripts/update-rsync.sh" install --dest "$ROOT/Vendor/rsync"
fi

if [ "$RUN_TESTS" = 1 ]; then
  echo "▸ Testler çalıştırılıyor…"
  # Testler kullanıcının ~/Library/Preferences klasörüne ayar dosyası bırakmamalı (TestDefaults): koşudan önceki ve
  # sonraki test biçimli adlar karşılaştırılır (2026-11-08'e dek ~4 900 boş plist birikmişti).
  PREFS_BEFORE="$(mktemp -t copiator-prefs)"
  "$ROOT/Scripts/dev/test-preferences.sh" snapshot "$PREFS_BEFORE"
  swift test --package-path "$ROOT"
  "$ROOT/Scripts/dev/test-preferences.sh" check "$PREFS_BEFORE"
  rm -f "$PREFS_BEFORE"
fi

"$ROOT/Scripts/build_app.sh"

# Paketin rsync motorunu içerdiğini ve çalıştığını doğrula.
ENGINE="$APP/Contents/MacOS/rsync"
[ -x "$ENGINE" ] || { echo "HATA: Pakette rsync yok." >&2; exit 1; }
ENGINE_VERSION="$(perl -e 'alarm shift; exec @ARGV' 10 "$ENGINE" --version </dev/null 2>/dev/null | head -1 || true)"
ENGINE_ARCHS="$(lipo -archs "$ENGINE")"
echo "▸ Paketteki rsync: ${ENGINE_VERSION:-okunamadı} ($ENGINE_ARCHS)"
# Motor, uygulamanın derlendiği her mimariyi içermeli; yoksa o Mac'lerde Copiator motorsuz kalır (build_app.sh ile aynı
# ARCHS değişkeni; native = yalnızca bu Mac).
REQUIRED_ARCHS="${ARCHS:-arm64 x86_64}"
[ "$REQUIRED_ARCHS" != native ] || REQUIRED_ARCHS="$(uname -m)"
for arch in $REQUIRED_ARCHS; do
  case " $ENGINE_ARCHS " in
    *" $arch "*) ;;
    *) echo "HATA: Paketteki rsync $arch içermiyor ($ENGINE_ARCHS). Scripts/update-rsync.sh install --force çalıştırın (build-rsync.sh evrensel derler)." >&2; exit 1 ;;
  esac
done
"$ROOT/Scripts/verify_bundle.sh" "$APP"

echo "▸ Dağıtım dosyaları hazırlanıyor…"
mkdir -p "$DIST"
rm -f "$DIST/$NAME.zip" "$DIST/$NAME.dmg" "$DIST/$NAME.dmg.sig" "$DIST/SHA256SUMS.txt" "$DIST/$NAME.sha256"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/copiator-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
# ditto paket üst verisini ve genişletilmiş öznitelikleri (imza dahil) olduğu gibi korur.
ditto "$APP" "$STAGING/Copiator.app"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/LICENSE" "$STAGING/LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGING/THIRD_PARTY_NOTICES.txt"
hdiutil create -quiet -volname "Copiator $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO "$DIST/$NAME.dmg"

DMG_PATH="$DIST/$NAME.dmg"
SIGNING_TOOL=(xcrun swift "$ROOT/Scripts/update_signing.swift")
APP_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :CopiatorUpdatePublicEDKey' "$ROOT/Support/Info.plist" 2>/dev/null || true)"

if [ -n "$APP_PUBLIC_KEY" ]; then
  KEYCHAIN_PUBLIC_KEY="$("${SIGNING_TOOL[@]}" public-key 2>/dev/null || true)"
  if [ "$APP_PUBLIC_KEY" = "$KEYCHAIN_PUBLIC_KEY" ]; then
    echo "▸ DMG imzalanıyor (Ed25519)…"
    "${SIGNING_TOOL[@]}" sign "$DMG_PATH" > "$DMG_PATH.sig"
    "${SIGNING_TOOL[@]}" verify "$DMG_PATH" "$(cat "$DMG_PATH.sig")" "$APP_PUBLIC_KEY"
    echo "✓ İmza doğrulandı ($DMG_PATH.sig)"
  else
    echo "UYARI: Keychain anahtarı ile Info.plist'teki CopiatorUpdatePublicEDKey uyuşmuyor; .sig üretilemedi." >&2
  fi
fi

echo "▸ SHA-256 özetleri oluşturuluyor…"
(cd "$DIST" && shasum -a 256 "$NAME.dmg" > SHA256SUMS.txt)

echo "✓ Paketler hazır:"
# ls | awk '{ print $9 }' boşluk içeren yolları keserdi; boyut ve yol ayrı ayrı yazılır.
READY_FILES=("$DIST/$NAME.dmg" "$DIST/SHA256SUMS.txt")
if [ -f "$DMG_PATH.sig" ]; then
  READY_FILES+=("$DMG_PATH.sig")
fi
for file in "${READY_FILES[@]}"; do
  printf '   %s\t%s\n' "$(du -h "$file" | cut -f1)" "$file"
done
