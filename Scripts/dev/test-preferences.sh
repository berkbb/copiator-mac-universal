#!/bin/bash
# Checks that a test run left no settings file of its own in the user's ~/Library/Preferences.
#
# Tests open their UserDefaults suites only through Tests/CopiatorAppTests/TestDefaults.swift, whose suite names are
# absolute paths in a temporary folder, so cfprefsd never writes into ~/Library/Preferences. A suite opened with a plain
# name ("Copiator<Something>-<UUID>") would leave ~/Library/Preferences/<name>.plist behind, even after
# removePersistentDomain (it empties the file, it does not delete it); about 4,900 such files had piled up by 2026-11-08.
#
# Usage: test-preferences.sh snapshot FILE   Write the names of the current test settings files to FILE
#        test-preferences.sh check FILE      Exit 1 and list them if files that are not in FILE appeared since
#
# Only names of the tests' own shape count (Copiator, letters and digits, a dash and an upper-case UUID, .plist): other
# apps' files and the app's real settings (com.babadogantech.copiator.plist) are never looked at. Nothing is deleted:
# a new file means a test opened a suite without TestDefaults, which is the bug to fix.
set -euo pipefail

PREFERENCES="${COPIATOR_PREFERENCES_DIR:-$HOME/Library/Preferences}"
PATTERN='^Copiator[A-Za-z0-9]*-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\.plist$'

list() {
  # ls hata verirse (klasör yok) boş liste; grep eşleşme bulamazsa da 0.
  { ls -1 "$PREFERENCES" 2>/dev/null || true; } | { grep -E "$PATTERN" || true; } | LC_ALL=C sort
}

case "${1:-}" in
  snapshot)
    [ -n "${2:-}" ] || { echo "usage: $0 snapshot FILE" >&2; exit 2; }
    list > "$2"
    ;;
  check)
    [ -f "${2:-}" ] || { echo "usage: $0 check FILE (from snapshot)" >&2; exit 2; }
    # cfprefsd writes asynchronously: give a write the last test started time to land before looking.
    sleep 2
    NEW="$(list | LC_ALL=C comm -13 "$2" -)"
    if [ -n "$NEW" ]; then
      COUNT="$(printf '%s\n' "$NEW" | wc -l | tr -d ' ')"
      echo "✘ The tests left $COUNT settings file(s) in $PREFERENCES (open test settings with TestDefaults):" >&2
      printf '%s\n' "$NEW" | head -20 | sed 's/^/   /' >&2
      exit 1
    fi
    echo "✓ The tests left no settings file in $PREFERENCES."
    ;;
  *)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
