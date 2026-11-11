#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Interface strings: Resources/Localizable.xcstrings (source language: English).
#
#   scripts/strings.sh sync    # extract the strings from the code (through the
#                              # compiler, so keys match exactly) into the catalog
#   scripts/strings.sh check   # fail if a string has no translation
#
# Translations are edited in the catalog (Xcode opens it, or any JSON editor).
set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$ROOT/Resources/Localizable.xcstrings"
LANGUAGES=(fr)
cd "$ROOT"

case "${1:-}" in
sync)
    OUT="$ROOT/.build/l10n"
    # A clean, separate build: an incremental one would only emit the strings of
    # the files it recompiles, and the others would be marked stale.
    rm -rf "$OUT" "$ROOT/.build/l10n-build" && mkdir -p "$OUT"
    swift build --product PaveApp --scratch-path "$ROOT/.build/l10n-build" \
        -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT"
    [[ -f "$CATALOG" ]] || echo '{"sourceLanguage":"en","strings":{},"version":"1.0"}' > "$CATALOG"
    xcrun xcstringstool sync "$CATALOG" --stringsdata "$OUT"/*.stringsdata
    echo "synced $CATALOG"
    ;;
check)
    python3 - "$CATALOG" "${LANGUAGES[@]}" <<'PY'
import json, sys
catalog, languages = sys.argv[1], sys.argv[2:]
strings = json.load(open(catalog))["strings"]
missing = []
for key, entry in strings.items():
    if entry.get("extractionState") == "stale" or entry.get("shouldTranslate") is False:
        continue
    for lang in languages:
        unit = entry.get("localizations", {}).get(lang, {}).get("stringUnit", {})
        if unit.get("state") != "translated" or not unit.get("value"):
            missing.append(f"{lang}: {key}")
stale = [k for k, e in strings.items() if e.get("extractionState") == "stale"]
for line in missing: print("missing", line)
for key in stale: print("stale (no longer in the code):", key)
print(f"{len(strings)} strings, {len(missing)} missing translation(s), {len(stale)} stale")
sys.exit(1 if missing or stale else 0)
PY
    ;;
*)
    echo "usage: scripts/strings.sh sync|check" >&2
    exit 2
    ;;
esac
