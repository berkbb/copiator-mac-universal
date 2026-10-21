#!/bin/bash
# Copiator sürümünü değiştirir. Sürümün tek kaynağı Support/Info.plist'tir.
#
# Kullanım: set-version.sh 1.0.1
#   CFBundleShortVersionString verilen sürüm olur, CFBundleVersion (derleme numarası) bir artar.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Support/Info.plist"
VERSION="${1:-}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Kullanım: $(basename "$0") <büyük.küçük.yama>  (ör. 1.0.1)" >&2
  exit 2
fi

OLD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
OLD_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
NEW_BUILD=$((OLD_BUILD + 1))

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
echo "Sürüm: $OLD_VERSION ($OLD_BUILD) → $VERSION ($NEW_BUILD)"
echo "CHANGELOG.md içinde '## [$VERSION]' başlığını eklemeyi unutmayın."
