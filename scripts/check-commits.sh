#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Checks that commit subjects follow Conventional Commits (ADR 0001): the release notes
# are built from them (scripts/changelog.sh). From p-suite's template.
#
#   scripts/check-commits.sh              every commit since the previous pave-v* tag
#   scripts/check-commits.sh <range>      the commits of a range (`main..HEAD`, `abc123..`)
#   scripts/check-commits.sh <file>       one message in a file: as a commit-msg hook,
#                                         ln -s ../../scripts/check-commits.sh .git/hooks/commit-msg
#
# `just ci` runs it with no argument, and so does scripts/release.sh before publishing.
# Merge commits, and the commit a tag-less history starts from, are not checked.

set -euo pipefail

SLUG="pave"
TYPES="feat|fix|perf|docs|refactor|test|chore|build|ci|style|revert"
PATTERN="^($TYPES)(\([^)]+\))?!?: [^ ]"

check() { # <subject>
  printf '%s\n' "$1" | grep -Eq "$PATTERN"
}

# As a commit-msg hook: one message, in a file.
if [ $# -eq 1 ] && [ -f "$1" ]; then
  subject="$(grep -v '^#' "$1" | head -1)"
  if check "$subject"; then exit 0; fi
  echo "✗ Not a Conventional Commit: $subject" >&2
  echo "  Write it as \`type(scope): what changed\`, type one of: ${TYPES//|/, }." >&2
  exit 1
fi

if [ $# -eq 1 ]; then
  range="$1"
else
  last="$(git describe --tags --abbrev=0 --match "$SLUG-v*" 2>/dev/null || true)"
  if [ -n "$last" ]; then
    range="$last..HEAD"
  else
    # No release yet: everything after the first commit.
    root="$(git rev-list --max-parents=0 HEAD | tail -1)"
    range="$root..HEAD"
  fi
fi

bad=0
total=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  total=$((total + 1))
  subject="${line#* }"
  if ! check "$subject"; then
    [ "$bad" -eq 0 ] && echo "✗ Not Conventional Commits, in $range:" >&2
    echo "    $line" >&2
    bad=$((bad + 1))
  fi
done < <(git log --no-merges --format='%h %s' "$range")

if [ "$bad" -ne 0 ]; then
  echo "  $bad of $total. Reword them (git rebase -i) before they are pushed, or released." >&2
  exit 1
fi
echo "  ✓ $total commits, all Conventional ($range)"
