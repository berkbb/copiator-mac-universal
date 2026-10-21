#!/bin/bash
# Finder'da çift tıklayınca Copiator'ı paketler (.app, .dmg; rsync dahil, evrensel).
cd "$(dirname "$0")" || exit 1
./Scripts/package.sh "$@"
STATUS=$?
echo
if [ $STATUS -eq 0 ]; then
  echo "Bitti. Paketler: $(pwd)/dist"
  open dist
else
  echo "Paketleme başarısız (çıkış kodu $STATUS)."
fi
read -r -p "Kapatmak için Enter'a basın…" _
exit $STATUS
