#!/bin/bash
# Copiator sürümünü bu Mac'te paketler ve GitHub Releases'e yükler (GitHub Actions kullanılmaz).
#
# Kullanım: release.sh [--dry-run] [--draft] [--skip-tests]
#   --dry-run     Hiçbir şey göndermez; yapılacakları gösterir ve paketler
#   --draft       GitHub'da taslak sürüm oluşturur (yayımlamak için web arayüzünden onaylanır)
#   --skip-tests  package.sh testleri atlasın
#
# Gerekenler: temiz bir git çalışma kopyası (main dalı, origin ile eşit), gh CLI ile oturum,
# CHANGELOG.md içinde '## [<sürüm>]' bölümü. Sürüm Support/Info.plist'ten okunur.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRY_RUN=0
DRAFT=0
PACKAGE_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --draft) DRAFT=1 ;;
    --skip-tests) PACKAGE_ARGS+=(--skip-tests) ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Bilinmeyen seçenek: $arg" >&2; exit 2 ;;
  esac
done

fail() { echo "HATA: $*" >&2; exit 1; }
run() {
  if [ "$DRY_RUN" = 1 ]; then echo "  (deneme) $*"; else "$@"; fi
}

cd "$ROOT"
command -v gh >/dev/null || fail "gh CLI bulunamadı (brew install gh)"
gh auth status >/dev/null 2>&1 || fail "gh oturumu yok (gh auth login)"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
TAG="v$VERSION"
NAME="Copiator-$VERSION"
REPO="$(/usr/libexec/PlistBuddy -c 'Print :CopiatorRepository' Support/Info.plist)"
echo "▸ Sürüm: $VERSION  (etiket $TAG, depo $REPO)"

# --- Ön denetimler ---------------------------------------------------------
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || fail "Yayım main dalından yapılır (şu an: $BRANCH)"
[ -z "$(git status --porcelain)" ] || fail "Çalışma kopyasında commit edilmemiş değişiklikler var"
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "Yerel main ile origin/main aynı değil (önce git push / pull)"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
  fail "$TAG etiketi zaten var. Önce Scripts/set-version.sh ile sürümü artırın."
fi

# Sürüm notları: CHANGELOG.md'deki '## [sürüm]' bölümü. Başlık düz metin olarak karşılaştırılır: sürümdeki "."
# bir düzenli ifadede her karakterle eşleşir ("1.2.0" araması "1x2y0" başlığını da bulurdu).
NOTES="$(mktemp "${TMPDIR:-/tmp}/copiator-notes.XXXXXX")"
trap 'rm -f "$NOTES"' EXIT
awk -v heading="## [$VERSION]" '
  index($0, heading) == 1 { found = 1; next }
  found && /^## \[/ { exit }
  found { print }
' CHANGELOG.md > "$NOTES"
[ -s "$NOTES" ] || fail "CHANGELOG.md içinde '## [$VERSION]' bölümü bulunamadı"
cat >> "$NOTES" <<'EOF'

---
**Installation:** open the `.dmg` and drag Copiator into the Applications folder. The app is ad-hoc signed; if macOS blocks it on first launch, allow it in System Settings › Privacy & Security › **Open Anyway**. You can verify the files with the `.sha256` file.
EOF

# --- Paketleme ---------------------------------------------------------------
"$ROOT/Scripts/package.sh" "${PACKAGE_ARGS[@]+"${PACKAGE_ARGS[@]}"}"
ASSETS=("dist/$NAME.dmg" "dist/$NAME.dmg.sig" "dist/SHA256SUMS.txt")
for asset in "${ASSETS[@]}"; do [ -f "$asset" ] || fail "$asset oluşmadı"; done

# --- Etiket ve GitHub sürümü -------------------------------------------------
echo "▸ Etiket: $TAG"
run git tag -a "$TAG" -m "Copiator $VERSION"
run git push origin "$TAG"

RELEASE_ARGS=(release create "$TAG" "${ASSETS[@]}" --repo "$REPO" --title "Copiator $VERSION" --notes-file "$NOTES" --verify-tag)
[ "$DRAFT" = 1 ] && RELEASE_ARGS+=(--draft)
echo "▸ GitHub sürümü oluşturuluyor…"
run gh "${RELEASE_ARGS[@]}"

if [ "$DRY_RUN" = 1 ]; then
  echo "✓ Deneme bitti; hiçbir şey gönderilmedi. Sürüm notları:"
  sed 's/^/    /' "$NOTES"
else
  echo "✓ Yayımlandı: https://github.com/$REPO/releases/tag/$TAG"
fi
