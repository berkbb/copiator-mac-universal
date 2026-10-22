#!/bin/bash
# Derlenmiş Copiator.app paketinin içeriğini denetler: evrensel uygulama ve rsync ikilisi, rsync'in yalnızca sistem
# kütüphanelerine bağlı olması, güncelleyici betikleri, lisans dosyaları, dil dosyaları ve imza.
#
# Kullanım: verify_bundle.sh [Copiator.app]   (varsayılan: build/Copiator.app)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Copiator.app}"
FAILURES=0

fail() { echo "✘ $1" >&2; FAILURES=$((FAILURES + 1)); }
check_file() { [ -f "$1" ] || fail "Eksik: ${1#"$APP/"}"; }
universal() {
  local archs
  archs="$(lipo -archs "$1" 2>/dev/null)"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "Evrensel değil ($archs): ${1#"$APP/"}"
}

[ -d "$APP" ] || { echo "✘ Paket bulunamadı: $APP" >&2; exit 1; }

for binary in Copiator rsync; do
  if [ -x "$APP/Contents/MacOS/$binary" ]; then universal "$APP/Contents/MacOS/$binary"; else fail "Eksik ya da çalıştırılamaz: Contents/MacOS/$binary"; fi
done
if [ -x "$APP/Contents/MacOS/rsync" ]; then
  while IFS= read -r dep; do
    [[ "$dep" == /usr/lib/* ]] || fail "rsync sistem dışı bir kütüphaneye bağlı: $dep"
  done < <(otool -L -arch all "$APP/Contents/MacOS/rsync" | awk '$0 !~ /:$/ && $1 ~ /^\// { print $1 }' | sort -u)
  "$APP/Contents/MacOS/rsync" --version 2>/dev/null | head -1 | grep -q "rsync  version" || fail "Paketteki rsync çalışmıyor"
fi
for file in update-rsync.sh build-rsync.sh Copiator-License.txt rsync-License.txt Third-Party-Notices.txt rsync-SOURCE.txt AppIcon.icns; do
  check_file "$APP/Contents/Resources/$file"
done
for LPROJ in "$ROOT/Resources/"*.lproj; do
  for FILE in "$LPROJ"/*.strings; do
    check_file "$APP/Contents/Resources/$(basename "$LPROJ")/$(basename "$FILE")"
  done
done
grep -q "GNU GENERAL PUBLIC LICENSE" "$APP/Contents/Resources/Copiator-License.txt" 2>/dev/null || fail "Copiator lisansı GPL metni değil"
# Kestirmeler (App Intents): eylemler ve Siri ifadeleri meta veride bulunmalı.
ACTIONS="$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
if [ -f "$ACTIONS" ]; then
  for action in RunJobIntent RunRoutineIntent RunRoutineOnFilesIntent PauseAllJobsIntent ResumeAllJobsIntent; do
    grep -q "\"$action\"" "$ACTIONS" || fail "Kestirmeler meta verisinde eksik eylem: $action"
  done
  grep -q '"autoShortcuts"' "$ACTIONS" || fail "Kestirmeler meta verisinde Siri ifadeleri yok"
else
  fail "Eksik: Contents/Resources/Metadata.appintents"
fi

codesign --verify --deep --strict "$APP" 2>/dev/null || fail "İmza doğrulanamadı"

if [ "$FAILURES" -gt 0 ]; then
  echo "✘ Paket denetimi başarısız: $FAILURES sorun." >&2
  exit 1
fi
echo "✓ Paket denetimi geçti: $APP"
