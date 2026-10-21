#!/bin/bash
# Finder'da çift tıklayınca Copiator'ı paketleyip GitHub Releases'e yükler.
# Önce neler yapılacağını deneme modunda gösterir, sonra onay ister.
cd "$(dirname "$0")" || exit 1

./Scripts/release.sh --dry-run "$@" || { read -r -p "Kapatmak için Enter'a basın…" _; exit 1; }
echo
read -r -p "Yukarıdaki sürüm GitHub'a yüklensin mi? [e/H] " answer
case "$answer" in
  e|E|evet|Evet) ./Scripts/release.sh --skip-tests "$@"; STATUS=$? ;;
  *) echo "Vazgeçildi; hiçbir şey gönderilmedi."; STATUS=0 ;;
esac
echo
read -r -p "Kapatmak için Enter'a basın…" _
exit $STATUS
