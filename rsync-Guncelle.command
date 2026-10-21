#!/bin/bash
# Finder'da çift tıklayınca projedeki rsync'i (Vendor/rsync) ve varsa derlenmiş build/Copiator.app içindeki rsync'i
# GitHub'daki son sürüme günceller. rsync kaynaktan derlenir (Xcode Komut Satırı Araçları gerekir).
cd "$(dirname "$0")" || exit 1
TARGETS=(--dest "$(pwd)/Vendor/rsync")
if [ -d build/Copiator.app ]; then TARGETS+=(--app "$(pwd)/build/Copiator.app"); fi
./Scripts/update-rsync.sh install "${TARGETS[@]}" "$@"
STATUS=$?
echo
read -r -p "Kapatmak için Enter'a basın…" _
exit $STATUS
