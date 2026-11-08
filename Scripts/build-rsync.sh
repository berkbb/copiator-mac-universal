#!/bin/bash
# rsync'i resmî kaynağından (github.com/RsyncProject/rsync) derleyip Vendor/rsync/ altına evrensel
# (arm64 + x86_64), bağımlılıksız bir ikili olarak koyar. Copiator rsync'i yalnızca ayrı süreç olarak çalıştırır;
# hiçbir zaman bağlamaz (link etmez).
#
# Kullanım: build-rsync.sh [--tag v3.5.1] [--tarball DOSYA] [--dest DIR] [--keep-work]
#   --tag TAG        Derlenecek etiket (varsayılan: v3.5.1)
#   --tarball DOSYA  Git yerine, doğrulanmış bir sürüm paketinden (rsync-X.tar.gz) derle (update-rsync.sh kullanır)
#   --dest DIR       Çıktı klasörü (varsayılan: Vendor/rsync)
#   --keep-work      Derleme klasörünü silme (hata ayıklamak için)
#
# Adımlar: clone → etiket → arm64 ve x86_64 için ayrı configure + make → lipo -create → otool -L ile yalnızca
# /usr/lib bağımlılığı denetimi → ad-hoc imza → SOURCE.txt (sürüm, commit, URL, SHA-256, configure bayrakları).
#
# x86_64 çapraz derlenir (--host): macOS 27'de Rosetta olmayabilir, configure'ün deneme programları x86_64 olarak
# çalıştırılamaz. Bu yüzden önce yerel (arm64) configure çalışır, deneme sonuçları önbelleğe yazılır ve x86_64
# configure aynı önbelleği kullanır (iki mimari de aynı macOS libc'sini ve aynı tür boyutlarını kullanır).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_URL="https://github.com/RsyncProject/rsync"
TAG="v3.5.2"
DEST="$ROOT/Vendor/rsync"
KEEP_WORK=0
TARBALL=""
MIN_MACOS="26.0"
# İstenen özellik seti: ACL, xattr ve iconv açık (macOS sistem kütüphanesinde); dış bağımlılıklar kapalı.
CONFIGURE_FLAGS=(--disable-xxhash --disable-zstd --disable-lz4 --disable-openssl --disable-md2man --disable-idn)
# Homebrew'daki popt'a yanlışlıkla bağlanmasın: rsync'in kendi popt kopyası kullanılır. zlib macOS'unkidir (/usr/lib).
EXTRA_FLAGS=(--with-included-popt)

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    --tarball) TARBALL="$2"; shift 2 ;;
    --keep-work) KEEP_WORK=1; shift ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Bilinmeyen seçenek: $1" >&2; exit 2 ;;
  esac
done

log() { echo "▸ $*" >&2; }
fail() { echo "HATA: $*" >&2; exit 1; }

[ -n "$TARBALL" ] || command -v git >/dev/null || fail "git bulunamadı"
command -v lipo >/dev/null || fail "lipo bulunamadı (Xcode komut satırı araçları)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/copiator-rsync-build.XXXXXX")"
cleanup() { if [ "$KEEP_WORK" = 1 ]; then echo "Derleme klasörü: $WORK" >&2; else rm -rf "$WORK"; fi; }
trap cleanup EXIT

if [ -n "$TARBALL" ]; then
  [ -f "$TARBALL" ] || fail "Paket bulunamadı: $TARBALL"
  log "Kaynak paketi açılıyor: $(basename "$TARBALL")"
  mkdir -p "$WORK/src"
  tar -xzf "$TARBALL" -C "$WORK/src" --strip-components 1 || fail "Paket açılamadı: $TARBALL"
  COMMIT="(sürüm paketi: $(basename "$TARBALL"), sha256 $(shasum -a 256 "$TARBALL" | awk '{ print $1 }'))"
else
  log "Kaynak indiriliyor: $REPO_URL ($TAG)"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" "$REPO_URL.git" "$WORK/src" 2>/dev/null \
    || fail "Kaynak indirilemedi: $REPO_URL ($TAG)"
  COMMIT="$(git -C "$WORK/src" rev-parse HEAD)"
  log "Commit: $COMMIT"
fi
# rsync'in mkgitver'ı .git klasörü görünce sürüme commit ekler ("3.5.1-g04355d27"). Sürüm tar paketlerinde .git
# yoktur ve rsync yalın sürümü ("3.5.1") yazar; commit SOURCE.txt'ye kaydedildiği için .git atılır.
rm -rf "$WORK/src/.git"

# Git etiketinde üretilmiş configure.sh ve config.h.in yoktur (yalnızca sürüm tar paketlerinde vardır). rsync'in
# prepare-source.mak'ı bunları "aclocal -I m4", "autoconf" ve "autoheader" ile üretir. rsync automake kullanmaz;
# aclocal burada yalnızca m4/ klasöründeki yerel makroları toplar. automake gerekmesin diye aclocal.m4 aynı
# içerikle (m4_include satırları) yazılır, ardından autoconf ve autoheader çalıştırılır.
GENERATED_WITH="(configure.sh hazır geldi)"
if [ ! -f "$WORK/src/configure.sh" ]; then
  command -v autoconf >/dev/null && command -v autoheader >/dev/null \
    || fail "configure.sh üretmek için autoconf gerekli (brew install autoconf)"
  log "configure.sh üretiliyor ($(autoconf --version | head -1))"
  (
    cd "$WORK/src"
    for macro in m4/*.m4; do echo "m4_include([$macro])"; done > aclocal.m4
    autoconf -o configure.sh
    autoheader && touch config.h.in
  ) || fail "configure.sh üretilemedi"
  GENERATED_WITH="$(autoconf --version | head -1); aclocal.m4 = m4_include(m4/*.m4)"
fi

# Homebrew ve kullanıcı ortamı derlemeye sızmasın: yalnızca sistem araçları ve SDK.
CLEAN_PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(xcrun -f clang)")"

build_arch() {
  local arch="$1" host_flags=("${@:2}")
  local dir="$WORK/build-$arch"
  cp -R "$WORK/src" "$dir"
  log "[$arch] configure ${CONFIGURE_FLAGS[*]} ${EXTRA_FLAGS[*]} ${host_flags[*]}"
  (
    cd "$dir"
    env -i PATH="$CLEAN_PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
      CC="clang -arch $arch" CFLAGS="-O2 -mmacosx-version-min=$MIN_MACOS -isysroot $SDK" \
      LDFLAGS="-mmacosx-version-min=$MIN_MACOS -isysroot $SDK" \
      ./configure "${CONFIGURE_FLAGS[@]}" "${EXTRA_FLAGS[@]}" "${host_flags[@]}" > "$WORK/configure-$arch.log" 2>&1 \
      || { tail -40 "$WORK/configure-$arch.log" >&2; exit 1; }
    log "[$arch] make"
    env -i PATH="$CLEAN_PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
      make -j"$(sysctl -n hw.ncpu)" rsync > "$WORK/make-$arch.log" 2>&1 \
      || { tail -40 "$WORK/make-$arch.log" >&2; exit 1; }
  ) || fail "[$arch] derleme başarısız (günlük: $WORK/*-$arch.log; --keep-work ile saklayın)"
  [ "$(lipo -archs "$dir/rsync")" = "$arch" ] || fail "[$arch] beklenmeyen mimari: $(lipo -archs "$dir/rsync")"
}

# 1) Yerel mimari (deneme programları çalışabilir); sonuçlar önbelleğe yazılır.
build_arch arm64 --cache-file="$WORK/arm64.cache"

# 2) x86_64: önbellekteki deneme sonuçlarıyla çapraz derleme. Ortam ve mimari kayıtları atılır; yoksa configure
#    "önbellek başka bir ortamda üretildi" diye durur. SIMD/asm denetimleri mimariye özgü olduğu için kapalıdır.
grep -v -E '^(ac_cv_env_|ac_cv_host|ac_cv_build|ac_cv_target|ac_cv_prog_c|ac_cv_c_compiler|ac_cv_objext|ac_cv_exeext)' \
  "$WORK/arm64.cache" > "$WORK/x86_64.cache"
build_arch x86_64 --host=x86_64-apple-darwin --build=aarch64-apple-darwin --cache-file="$WORK/x86_64.cache" \
  --disable-roll-simd --disable-md5-asm --disable-roll-asm

log "lipo -create"
mkdir -p "$WORK/out"
lipo -create "$WORK/build-arm64/rsync" "$WORK/build-x86_64/rsync" -output "$WORK/out/rsync"
strip -x "$WORK/out/rsync"
chmod 755 "$WORK/out/rsync"
ARCHS="$(lipo -archs "$WORK/out/rsync")"
[ "$ARCHS" = "x86_64 arm64" ] || [ "$ARCHS" = "arm64 x86_64" ] || fail "Evrensel ikili değil: $ARCHS"

log "Bağımlılıklar denetleniyor (otool -L)"
DEPS="$(otool -L -arch all "$WORK/out/rsync" | awk '$0 !~ /:$/ && $1 ~ /^\// { print $1 }' | sort -u)"
echo "$DEPS" | sed 's/^/    /' >&2
while IFS= read -r dep; do
  [ -z "$dep" ] && continue
  [[ "$dep" == /usr/lib/* ]] || fail "Sistem dışı bağımlılık: $dep"
done <<<"$DEPS"

log "Ad-hoc imzalanıyor"
codesign --force --sign - "$WORK/out/rsync"
codesign --verify --strict "$WORK/out/rsync"

# Çıktı bir kez okunur: "rsync --version | grep -q" pipefail altında grep boruyu erken kapatınca (SIGPIPE) başarısız sayılır.
VERSION_TEXT="$("$WORK/out/rsync" --version)"
VERSION_LINE="$(head -1 <<<"$VERSION_TEXT")"
VERSION="$(awk '{ for (i = 1; i <= NF; i++) if ($i == "version") { print $(i + 1); exit } }' <<<"$VERSION_LINE")"
[ "v$VERSION" = "$TAG" ] || fail "Derlenen sürüm etiketle uyuşmuyor: $VERSION_LINE"
for capability in xattrs ACLs iconv; do
  grep -qw "$capability" <<<"$VERSION_TEXT" || fail "$capability desteği derlenmemiş"
done

SHA256="$(shasum -a 256 "$WORK/out/rsync" | awk '{ print $1 }')"
mkdir -p "$DEST"
cp "$WORK/out/rsync" "$DEST/rsync.new" && mv -f "$DEST/rsync.new" "$DEST/rsync"
cp "$WORK/src/COPYING" "$DEST/COPYING"
cp "$WORK/src/NEWS.md" "$DEST/NEWS.md"
{
  echo "name=rsync"
  echo "version=$VERSION"
  echo "tag=$TAG"
  echo "commit=$COMMIT"
  echo "url=$REPO_URL/tree/$TAG"
  echo "source=$REPO_URL.git"
  echo "license=GPL-3.0-or-later (COPYING)"
  echo "sha256=$SHA256"
  echo "archs=$ARCHS"
  echo "min_macos=$MIN_MACOS"
  echo "configure_flags=${CONFIGURE_FLAGS[*]} ${EXTRA_FLAGS[*]}"
  echo "configure_flags_x86_64_extra=--host=x86_64-apple-darwin --build=aarch64-apple-darwin --disable-roll-simd --disable-md5-asm --disable-roll-asm"
  echo "dependencies=$(echo "$DEPS" | tr '\n' ' ' | sed 's/ $//')"
  echo "configure_generated_with=$GENERATED_WITH"
  echo "built_with=$(xcrun clang --version | head -1)"
} > "$DEST/SOURCE.txt"

log "Hazır: $DEST/rsync ($VERSION_LINE; $ARCHS)"
echo "STATUS=built"
echo "VERSION=$VERSION"
echo "SHA256=$SHA256"
