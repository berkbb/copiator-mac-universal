#!/bin/bash
# rsync motorunu resmî GitHub sürümlerinden (RsyncProject/rsync) denetler ve kurar.
#
# Kullanım:
#   update-rsync.sh check   [hedefler] [--current SÜRÜM]
#   update-rsync.sh install [hedefler] [--current SÜRÜM] [--force]
#
# Hedefler (birden fazla verilebilir):
#   --dest DIR   rsync'i ve lisansını bir klasöre kurar (ör. Vendor/rsync)
#   --app PATH   Bir Copiator.app paketinin içindeki rsync'i günceller ve paketi yeniden imzalar
# Hedef verilmezse: betik bir .app içinden çalışıyorsa o uygulama, projeden çalışıyorsa projenin Vendor/rsync
# klasörü güncellenir.
#
# rsync yalnızca kaynak kodu yayımlar (macOS ikilisi yoktur). Kurulum: sürüm paketini indirir, GitHub'ın bildirdiği
# SHA-256 ile doğrular, build-rsync.sh ile bu Mac'te evrensel (arm64 + x86_64) derler, Mach-O ve --version
# denetimlerinden sonra tek adımda yerine taşır. Derleme için Xcode Komut Satırı Araçları gerekir.
#
# Makine tarafından okunacak sonuçlar stdout'a KEY=value satırları olarak, insan için mesajlar stderr'e yazılır.
# Copiator arayüzü de bu betiği çalıştırır.
set -euo pipefail

REPO="RsyncProject/rsync"
API_URL="https://api.github.com/repos/$REPO/releases/latest"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/"
FALLBACK_DIR="$HOME/Library/Application Support/Copiator/engine"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CURRENT=""
FORCE=0
TARGET_KINDS=()
TARGET_PATHS=()
# Hedef yedek klasöre çevrildiyse, oradaki rsync henüz yokken sürümü okunacak özgün (paketteki) rsync.
TARGET_ORIGINALS=()

usage() {
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' >&2
}

log() { echo "$*" >&2; }
fail() { log "HATA: $*"; echo "STATUS=error"; echo "ERROR=$*"; exit 1; }
add_target() { TARGET_KINDS+=("$1"); TARGET_PATHS+=("$2"); TARGET_ORIGINALS+=(""); }

COMMAND="${1:-}"
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) [ $# -ge 2 ] || fail "--dest bir klasör bekliyor"; add_target dir "$2"; shift 2 ;;
    --app) [ $# -ge 2 ] || fail "--app bir .app yolu bekliyor"; add_target app "$2"; shift 2 ;;
    --current) [ $# -ge 2 ] || fail "--current bir sürüm bekliyor"; CURRENT="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Bilinmeyen seçenek: $1" ;;
  esac
done
case "$COMMAND" in
  check|install) ;;
  -h|--help|"") usage; exit 0 ;;
  *) fail "Bilinmeyen komut: $COMMAND (check veya install)" ;;
esac

# --- Varsayılan hedef ------------------------------------------------------
if [ ${#TARGET_KINDS[@]} -eq 0 ]; then
  if [ -n "${COPIATOR_ENGINE_DIR:-}" ]; then
    add_target dir "$COPIATOR_ENGINE_DIR"
  elif [[ "$SCRIPT_DIR" == *.app/Contents/Resources ]]; then
    add_target app "${SCRIPT_DIR%/Contents/Resources}"
  else
    add_target dir "$(cd "$SCRIPT_DIR/.." && pwd)/Vendor/rsync"
  fi
fi

# Yazılamayan bir uygulama paketi (ör. yönetici izniyle kurulmuş) yerine kullanıcı klasörüne kur.
for i in "${!TARGET_KINDS[@]}"; do
  if [ "${TARGET_KINDS[$i]}" = app ]; then
    APP_PATH="${TARGET_PATHS[$i]}"
    [ -d "$APP_PATH/Contents" ] || fail "Uygulama paketi bulunamadı: $APP_PATH"
    if [ ! -w "$APP_PATH/Contents/MacOS" ]; then
      log "Uyarı: $APP_PATH yazılamıyor; rsync $FALLBACK_DIR klasörüne kurulacak."
      TARGET_KINDS[$i]=dir
      TARGET_PATHS[$i]="$FALLBACK_DIR"
      TARGET_ORIGINALS[$i]="$APP_PATH/Contents/MacOS/rsync"
    fi
  fi
done

target_binary() {
  if [ "$1" = app ]; then echo "$2/Contents/MacOS/rsync"; else echo "$2/rsync"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/copiator-update.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Bir programı en fazla N saniye çalıştırır (macOS'ta timeout komutu yok).
run_with_timeout() {
  local seconds="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
}

# "rsync  version 3.5.1  protocol version 33" satırından sürümü çıkarır (openrsync dahil).
engine_version() {
  local binary="$1"
  [ -x "$binary" ] || return 0
  run_with_timeout 10 "$binary" --version 2>/dev/null </dev/null \
    | awk '/rsync/ { for (i = 1; i < NF; i++) if ($i == "version" && $(i + 1) ~ /^[0-9]+\.[0-9]+/) { print $(i + 1); exit } }' || true
}

# "3.5.1" -> 3005001; karşılaştırma için.
version_number() {
  awk -F. '{ printf "%d%03d%03d\n", $1, $2, $3 }' <<<"$1"
}

# --- Son sürüm bilgisini al -------------------------------------------------
log "Son sürüm denetleniyor: github.com/$REPO"
curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 \
  -H "Accept: application/vnd.github+json" "$API_URL" -o "$WORK/release.json" \
  || fail "GitHub'a ulaşılamadı"

# JSON'u macOS'un yerleşik JavaScript motoruyla ayrıştır (ek bağımlılık yok).
RELEASE_INFO="$(osascript -l JavaScript -e '
function run(argv) {
  var text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js;
  var release = JSON.parse(text);
  if (release.draft || release.prerelease) { return "TAG="; }
  var asset = (release.assets || []).filter(function (a) { return /^rsync-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$/.test(a.name); })[0];
  if (!asset) { return "TAG=" + release.tag_name; }
  return ["TAG=" + release.tag_name, "ASSET=" + asset.name, "URL=" + asset.browser_download_url,
          "DIGEST=" + (asset.digest || "")].join("\n");
}' "$WORK/release.json")" || fail "Sürüm bilgisi okunamadı"

TAG="$(sed -n 's/^TAG=//p' <<<"$RELEASE_INFO")"
ASSET="$(sed -n 's/^ASSET=//p' <<<"$RELEASE_INFO")"
URL="$(sed -n 's/^URL=//p' <<<"$RELEASE_INFO")"
DIGEST="$(sed -n 's/^DIGEST=//p' <<<"$RELEASE_INFO")"

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Beklenmeyen sürüm etiketi: ${TAG:-yok}"
LATEST="${TAG#v}"
[ "$ASSET" = "rsync-$LATEST.tar.gz" ] || fail "Bu sürümde kaynak paketi yok ($TAG)"
[[ "$URL" == "$DOWNLOAD_PREFIX"* ]] || fail "Beklenmeyen indirme adresi: $URL"

# Kurulu sürüm: hedeflerin en eskisi (biri eksikse güncelleme gerekir).
# Yedek klasöre çevrilen hedefte henüz rsync yoksa uygulamanın kendi rsync'i geçerlidir; "yok" sayılmaz.
if [ -z "$CURRENT" ]; then
  LOWEST=""
  for i in "${!TARGET_KINDS[@]}"; do
    BINARY="$(target_binary "${TARGET_KINDS[$i]}" "${TARGET_PATHS[$i]}")"
    if [ ! -x "$BINARY" ] && [ -n "${TARGET_ORIGINALS[$i]}" ]; then BINARY="${TARGET_ORIGINALS[$i]}"; fi
    VERSION="$(engine_version "$BINARY")"
    if [ -z "$VERSION" ]; then LOWEST=""; break; fi
    if [ -z "$LOWEST" ] || [ "$(version_number "$VERSION")" -lt "$(version_number "$LOWEST")" ]; then
      LOWEST="$VERSION"
    fi
  done
  CURRENT="$LOWEST"
fi

echo "LATEST=$LATEST"
echo "CURRENT=${CURRENT:-none}"
echo "SOURCE=https://github.com/$REPO/releases/tag/$TAG"
for i in "${!TARGET_KINDS[@]}"; do echo "TARGET=${TARGET_KINDS[$i]}:${TARGET_PATHS[$i]}"; done

UPDATE_AVAILABLE=1
if [ -n "$CURRENT" ] && [ "$(version_number "$CURRENT")" -ge "$(version_number "$LATEST")" ]; then
  UPDATE_AVAILABLE=0
fi

if [ "$COMMAND" = "check" ]; then
  if [ "$UPDATE_AVAILABLE" = 1 ]; then
    log "Yeni sürüm var: $LATEST (kurulu: ${CURRENT:-yok})"
    echo "STATUS=update-available"
  else
    log "rsync güncel: $CURRENT"
    echo "STATUS=up-to-date"
  fi
  exit 0
fi

# --- İndirme, doğrulama ve derleme -------------------------------------------
if [ "$UPDATE_AVAILABLE" = 0 ] && [ "$FORCE" = 0 ]; then
  log "rsync zaten güncel ($CURRENT). Yeniden kurmak için --force kullanın."
  echo "STATUS=up-to-date"
  exit 0
fi

# Derleyici yoksa xcrun bir kurulum penceresi açar; bunun yerine açık bir hata kodu döndürülür.
xcode-select -p >/dev/null 2>&1 && xcrun --find clang >/dev/null 2>&1 \
  || fail "command-line-tools-missing"
[ -x "$SCRIPT_DIR/build-rsync.sh" ] || [ -f "$SCRIPT_DIR/build-rsync.sh" ] || fail "build-rsync.sh bulunamadı ($SCRIPT_DIR)"

log "İndiriliyor: $ASSET"
curl -fL --proto '=https' --tlsv1.2 --max-time 600 --progress-bar "$URL" -o "$WORK/$ASSET" \
  || fail "İndirme başarısız"

[[ "$DIGEST" == sha256:* ]] || fail "GitHub SHA-256 özeti vermedi; paket doğrulanamıyor"
EXPECTED="${DIGEST#sha256:}"
ACTUAL="$(shasum -a 256 "$WORK/$ASSET" | awk '{ print $1 }')"
[ "$EXPECTED" = "$ACTUAL" ] || fail "SHA-256 eşleşmedi (beklenen $EXPECTED, gelen $ACTUAL)"
log "SHA-256 doğrulandı."

log "Derleniyor (birkaç dakika sürebilir)…"
/bin/bash "$SCRIPT_DIR/build-rsync.sh" --tarball "$WORK/$ASSET" --tag "$TAG" --dest "$WORK/out" >&2 \
  || fail "Derleme başarısız"

PAYLOAD="$WORK/out"
[ -f "$PAYLOAD/rsync" ] || fail "Derlenen rsync bulunamadı"
file "$PAYLOAD/rsync" | grep -q "Mach-O" || fail "rsync geçerli bir macOS programı değil"
chmod 755 "$PAYLOAD/rsync"
NEW_VERSION="$(engine_version "$PAYLOAD/rsync")"
[ "$NEW_VERSION" = "$LATEST" ] || fail "Derlenen rsync sürümü beklenenle uyuşmuyor (${NEW_VERSION:-okunamadı})"

# --- Kurulum ----------------------------------------------------------------

# Dosyayı önce geçici adla kopyalayıp tek adımda yerine taşır; yarım kurulum kalmaz.
replace_file() {
  cp "$1" "$2.new"
  mv -f "$2.new" "$2"
}

install_to_dir() {
  local dest="$1"
  mkdir -p "$dest"
  replace_file "$PAYLOAD/rsync" "$dest/rsync"
  for doc in COPYING NEWS.md SOURCE.txt; do
    if [ -f "$PAYLOAD/$doc" ]; then replace_file "$PAYLOAD/$doc" "$dest/$doc"; fi
  done
}

install_to_app() {
  local app="$1"
  replace_file "$PAYLOAD/rsync" "$app/Contents/MacOS/rsync"
  if [ -f "$PAYLOAD/COPYING" ]; then replace_file "$PAYLOAD/COPYING" "$app/Contents/Resources/rsync-License.txt"; fi
  # İçerik değiştiği için paketin imzasını yenile (ad-hoc).
  if command -v codesign >/dev/null; then
    codesign --force --sign - "$app/Contents/MacOS/rsync" >/dev/null 2>&1 || log "Uyarı: rsync imzalanamadı."
    codesign --force --sign - "$app" >/dev/null 2>&1 || log "Uyarı: $app yeniden imzalanamadı."
  fi
}

for i in "${!TARGET_KINDS[@]}"; do
  KIND="${TARGET_KINDS[$i]}"
  TARGET="${TARGET_PATHS[$i]}"
  if [ "$KIND" = app ]; then install_to_app "$TARGET"; else install_to_dir "$TARGET"; fi
  INSTALLED="$(target_binary "$KIND" "$TARGET")"
  log "rsync $LATEST kuruldu: $INSTALLED"
  echo "INSTALLED=$INSTALLED"
done

echo "STATUS=installed"
