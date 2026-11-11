#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Every source file carries the SPDX line in its first three lines, so a shebang
# or Package.swift's tools version can come first (ADR 0001). Tracked files only:
# nothing generated is asked for one.
set -euo pipefail

cd "$(dirname "$0")/.."

line="SPDX-License-Identifier: MIT OR Apache-2.0"
missing=()
total=0
while IFS= read -r file; do
  total=$((total + 1))
  head -3 "$file" | grep -qF "$line" || missing+=("$file")
done < <(git ls-files '*.swift' '*.sh')

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "✗ Source files without \"$line\" in their first lines:" >&2
  printf '    %s\n' "${missing[@]}" >&2
  exit 1
fi
echo "  ✓ SPDX: $total source files, all with the header"
