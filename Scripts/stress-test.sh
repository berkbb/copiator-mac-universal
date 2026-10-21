#!/bin/bash
# Sürüm öncesi stres turu: büyük ağaçlar, kesip sürdürme, yabancı dosya sistemleri ve gerçek uygulama.
#
# Klavye kullanmaz: Copiator erişilebilirlik (AX) ile sürülür. Bu yüzden başka bir uygulamada yazarken çalıştırmak
# güvenlidir; yine de Copiator başta bir kez öne getirilir (pencere bu masaüstünde olmalı).
#
# Gereken izin (uygulama turu): betiği çalıştıran uygulama (Terminal, Claude…) Sistem Ayarları › Gizlilik ve Güvenlik ›
# Aygıt Denetimi ve Veri Erişimi (Erişilebilirlik) listesinde açık olmalı.
#
# Kullanım: stress-test.sh [--app PATH] [--files N] [--skip-core] [--skip-app]
#   --app PATH    Sınanacak uygulama (varsayılan: /Applications/Copiator.app, yoksa build/Copiator.app)
#   --files N     Büyük ağaçtaki dosya sayısı (varsayılan: 20000; 200'ün katı)
#   --skip-core   Çekirdek turunu (gerçek rsync ile büyük ağaç, FAT32/exFAT disk görüntüleri) atla
#   --skip-app    Uygulama turunu (kuyruk, duraklat/sürdür, arayüz yanıtı, VoiceOver) atla
#
# Uygulama turu Copiator'ın iş kuyruğunu (~/Library/Application Support/Copiator/jobs.json) ve birkaç ayarını geçici
# olarak değiştirir; betik nasıl biterse bitsin (hata ya da Ctrl-C dahil) eski hâllerine döner.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Copiator.app"
[ -d "$APP" ] || APP="$ROOT/build/Copiator.app"
FILES=20000
RUN_CORE=1
RUN_APP=1
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift ;;
    --files) FILES="$2"; shift ;;
    --skip-core) RUN_CORE=0 ;;
    --skip-app) RUN_APP=0 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Bilinmeyen seçenek: $1" >&2; exit 2 ;;
  esac
  shift
done

BUNDLE=com.babadogantech.copiator
SUPPORT="$HOME/Library/Application Support/Copiator"
QUEUE="$SUPPORT/jobs.json"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/copiator-stress.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
PROBE="$WORK/stressprobe"
FAILED=0
pass() { echo "  ✔ $1"; }
fail() { echo "  ✘ $1"; FAILED=$((FAILED + 1)); }
crash_reports() { ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -ciE "^Copiator" || true; }

# Ayarları ve kuyruğu yedekle; çıkışta geri yükle. Hiç ayarlanmamış olanlar yeniden silinir.
SETTINGS=(updateConsentAsked notifyOnFinish queueHeld sandboxEngine)
SAVED_VALUES=(); SAVED_TYPES=()
for key in "${SETTINGS[@]}"; do
  SAVED_TYPES+=("$(defaults read-type "$BUNDLE" "$key" 2>/dev/null | awk '{print $NF}')")
  SAVED_VALUES+=("$(defaults read "$BUNDLE" "$key" 2>/dev/null)")
done
QUEUE_BACKUP=""
restore() {
  if [ "$RUN_APP" = 1 ]; then
    osascript -e "tell application id \"$BUNDLE\" to quit" >/dev/null 2>&1; sleep 2; pkill -x Copiator 2>/dev/null
    if [ -n "$QUEUE_BACKUP" ]; then mv -f "$QUEUE_BACKUP" "$QUEUE"; else rm -f "$QUEUE"; fi
    for i in "${!SETTINGS[@]}"; do
      key="${SETTINGS[$i]}"
      case "${SAVED_TYPES[$i]}" in
        "") defaults delete "$BUNDLE" "$key" >/dev/null 2>&1 ;;
        boolean) defaults write "$BUNDLE" "$key" -bool "$([ "${SAVED_VALUES[$i]}" = 1 ] && echo true || echo false)" ;;
        integer) defaults write "$BUNDLE" "$key" -int "${SAVED_VALUES[$i]}" ;;
        *) defaults write "$BUNDLE" "$key" -string "${SAVED_VALUES[$i]}" ;;
      esac
    done
  fi
  chmod -R u+w "$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap restore EXIT

CRASHES_BEFORE="$(crash_reports)"

if [ "$RUN_CORE" = 1 ]; then
  echo "▸ Çekirdek: $FILES dosyalık ağaç + 1 GB dosya, kesip sürdürme, doğrulama; FAT32/exFAT disk görüntüleri…"
  if COPIATOR_STRESS_FILES="$FILES" COPIATOR_VOLUME_TESTS=1 swift test --package-path "$ROOT" \
      --filter "StressTests|ForeignVolumeTests" > "$WORK/core.log" 2>&1; then
    pass "Çekirdek stres testleri geçti"
  else
    fail "Çekirdek stres testleri başarısız (günlük aşağıda)"
    grep -E "✘|recorded an issue|↳" "$WORK/core.log" | head -30
  fi
fi

if [ "$RUN_APP" = 1 ]; then
  [ -d "$APP" ] || { echo "HATA: $APP yok (./Scripts/build_app.sh)" >&2; exit 2; }
  echo "▸ Yardımcı derleniyor…"
  swiftc -O "$ROOT/Scripts/StressProbe.swift" -o "$PROBE" 2>&1 | grep -v "^$" | grep -v warning >&2 || true
  [ -x "$PROBE" ] || { echo "HATA: yardımcı derlenemedi" >&2; exit 2; }

  echo "▸ Uygulama: kuyruk, duraklat/sürdür, arayüz yanıtı ($WORK)…"
  SRC="$WORK/Kaynak"; OUT="$WORK/Hedef"; mkdir -p "$SRC" "$OUT"
  "$PROBE" mkfiles "$SRC" $((FILES / 200)) 200 >/dev/null
  mkfile 2g "$SRC/buyuk.bin"
  xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;" "$SRC/buyuk.bin"
  BEFORE="$(cd "$SRC" && find . | LC_ALL=C sort | shasum -a 256)"
  pass "$FILES dosya ve 2 GB'lık bir dosya hazır"

  osascript -e "tell application id \"$BUNDLE\" to quit" >/dev/null 2>&1; sleep 2; pkill -x Copiator 2>/dev/null; sleep 1
  mkdir -p "$SUPPORT"
  if [ -f "$QUEUE" ]; then QUEUE_BACKUP="$WORK/jobs.backup.json"; cp "$QUEUE" "$QUEUE_BACKUP"; fi
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$QUEUE" <<JSON
{"version": 1, "jobs": [{"id": "5A1F0C2E-0000-4000-8000-00000000C0DE", "kind": "rsync", "status": "waiting",
  "source": "file://$SRC/", "destination": "file://$OUT/", "createdAt": "$NOW", "log": [],
  "options": {"copyMode": "folder", "preservePermissions": false, "preserveExtendedAttributes": true,
              "deleteExtraneous": false, "excludeSystemFolders": true}}]}
JSON
  defaults write "$BUNDLE" updateConsentAsked -bool true
  defaults write "$BUNDLE" notifyOnFinish -bool false
  defaults write "$BUNDLE" queueHeld -bool false
  defaults write "$BUNDLE" sandboxEngine -bool true
  status() { plutil -extract jobs.0.status raw -o - "$QUEUE" 2>/dev/null; }
  wait_status() {
    local want="$1" timeout="$2" start=$SECONDS
    while [ $((SECONDS - start)) -lt "$timeout" ]; do [ "$(status)" = "$want" ] && return 0; sleep 0.5; done
    return 1
  }

  open -a "$APP"
  visible=0
  for _ in $(seq 1 30); do
    [ "$("$PROBE" windows 2>/dev/null || echo 0)" -ge 1 ] && { visible=1; break; }
    sleep 0.5
  done
  if [ "$visible" = 0 ]; then
    fail "Copiator penceresi ekranda değil (izin yok ya da başka bir masaüstünde). Uygulama turu atlandı."
  else
    "$PROBE" latency 900 > "$WORK/latency" &
    LATENCY_PID=$!
    wait_status copying 60 && pass "İş kendiliğinden başladı (kopyalanıyor)" || fail "İş başlamadı: $(status)"
    sleep 2
    "$PROBE" press copiator.job.toggle && wait_status paused 15 && pass "Duraklat: iş durdu" || fail "Duraklat: durum $(status)"
    "$PROBE" press copiator.job.toggle && wait_status finished 900 && pass "Sürdür: iş kaldığı yerden bitti" || fail "Sürdür: durum $(status)"
    kill $LATENCY_PID 2>/dev/null; wait $LATENCY_PID 2>/dev/null

    COPIED="$(find "$OUT/Kaynak" -type f | wc -l | tr -d ' ')"
    [ "$COPIED" = "$((FILES + 1))" ] && pass "Kopya: $COPIED dosya" || fail "Kopya: $COPIED/$((FILES + 1)) dosya"
    cmp -s "$SRC/buyuk.bin" "$OUT/Kaynak/buyuk.bin" && pass "Büyük dosya birebir" || fail "Büyük dosya farklı"
    xattr -p com.apple.quarantine "$OUT/Kaynak/buyuk.bin" >/dev/null 2>&1 && pass "Karantina işareti korundu" || fail "Karantina işareti yok"
    AFTER="$(cd "$SRC" && find . | LC_ALL=C sort | shasum -a 256)"
    [ "$BEFORE" = "$AFTER" ] && pass "Kaynak değişmedi" || fail "Kaynak değişti!"
    worst="$(tail -1 "$WORK/latency" 2>/dev/null)"; worst="${worst:-?}"
    if [ "$worst" != "?" ] && [ "$worst" -lt 1500 ]; then pass "Arayüz yanıtı: en kötü $worst ms"; else fail "Arayüz dondu: en kötü $worst ms"; fi

    if result="$("$PROBE" audit "iş listesi")"; then pass "VoiceOver: $result"; else fail "VoiceOver: $result"; fi
    unexpected="$("$PROBE" alert)"
    [ -z "$unexpected" ] && pass "Tur sonunda açık uyarı yok" || fail "Tur sonunda açık uyarı: $unexpected"
  fi
fi

CRASHES_AFTER="$(crash_reports)"
[ "$CRASHES_AFTER" = "$CRASHES_BEFORE" ] && pass "Yeni çökme raporu yok" || fail "Yeni çökme raporu: $((CRASHES_AFTER - CRASHES_BEFORE))"

echo
if [ "$FAILED" -eq 0 ]; then echo "✓ Stres turu geçti"; else echo "✘ Stres turu: $FAILED sorun"; fi
exit $((FAILED > 0))
