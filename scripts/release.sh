#!/usr/bin/env bash
# Publishes this commit as a GitHub release that installed copies of Pavé update from
# (Settings › General › Updates, `pave update`, `[updates] source`).
#
#   scripts/release.sh [--repo owner/repo] [--notes "text" | --notes-file file] [--skip-checks] [--dry-run]
#
# - Version: CFBundleShortVersionString of Resources/Info.plist; bump it first.
#   The release is tagged pave-v<version>; an existing one is refused.
# - The commit must be committed and pushed (the tag points at it on GitHub).
# - Builds a release Pave.app (scripts/bundle.sh release), signed with the
#   "Pave Dev" certificate: updates keep the Accessibility permission only if
#   every version is signed with the same one (an ad-hoc build is refused).
# - Files, in dist/release-<version>/:
#     Pave_<version>.dmg          a first install (drag to Applications)
#     Pave_<version>.app.tar.gz   what an update replaces
#   each with its .sha256 and its .minisig, signed with minisign (brew install
#   minisign) with the key PAVE_SIGN_KEY names (~/.minisign/pave.key by
#   default), whose public half is Resources/update-key.pub: an installed Pavé
#   installs only a file signed with it, and named in the signature
#   (trusted comment "file:<name>").
# - Notes: the commit subjects since the previous pave-v tag, then how to
#   install; --notes / --notes-file replace the first part.
# - --repo: where to publish (PAVE_RELEASE_REPO, else Srynetix/pave).
# - --dry-run: builds, signs and prints what would be published, publishes nothing.
set -euo pipefail

cd "$(dirname "$0")/.."

repo=${PAVE_RELEASE_REPO:-Srynetix/pave}
notes=""
notes_file=""
checks=true
dry=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo=${2:-}; shift ;;
    --notes) notes=${2:-}; shift ;;
    --notes-file) notes_file=${2:-}; shift ;;
    --skip-checks) checks=false ;;
    --dry-run) dry=true ;;
    -h | --help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Everything that can refuse, before anything is built.
command -v gh >/dev/null || fail "gh not found (brew install gh)"
command -v minisign >/dev/null || fail "minisign not found (brew install minisign)"
sign_key=${PAVE_SIGN_KEY:-$HOME/.minisign/pave.key}
sign_key=${sign_key/#\~/$HOME}
[[ -f "$sign_key" ]] || fail "no signing key $sign_key (PAVE_SIGN_KEY): minisign -G -s $sign_key -p Resources/update-key.pub"
[[ -f Resources/update-key.pub ]] || fail "no Resources/update-key.pub: the public key installed copies of Pavé check"
[[ -z "$notes_file" || -f "$notes_file" ]] || fail "--notes-file: no $notes_file"
security find-certificate -c "Pave Dev" >/dev/null 2>&1 || fail "no \"Pave Dev\" certificate (just cert): every release must be signed with the same one"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || fail "version '$version' in Resources/Info.plist: numbers like 0.5.0"
tag="pave-v$version"

step "Pavé $version → $repo ($tag)"
gh repo view "$repo" >/dev/null || fail "no access to $repo with gh"
if gh release view "$tag" -R "$repo" >/dev/null 2>&1; then fail "$tag is already released: bump CFBundleShortVersionString in Resources/Info.plist"; fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then fail "tag $tag already exists here"; fi
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "uncommitted changes: commit them first"
commit=$(git rev-parse HEAD)
git fetch -q origin
[[ -n "$(git branch -r --contains "$commit")" ]] || fail "$(git rev-parse --short HEAD) is not pushed: push it first"

if $checks; then
  step "Checks"
  log=$(mktemp "${TMPDIR:-/tmp}/pave-test.XXXXXX")
  if ! swift test >"$log" 2>&1; then
    tail -40 "$log"
    fail "tests failed (full output: $log)"
  fi
  tail -1 "$log"
  # A string added in the code but never extracted would ship untranslated.
  scripts/strings.sh sync >/dev/null
  git diff --quiet Resources/Localizable.xcstrings || fail "the string catalog is out of date: run just strings, translate, commit"
  scripts/strings.sh check
fi

step "Build"
scripts/bundle.sh release >/dev/null
# Captured first: grep -q stops reading early, and pipefail would take
# codesign's SIGPIPE for a failure.
signing=$(codesign -dvv build/Pave.app 2>&1)
grep -q "^Authority=Pave Dev$" <<<"$signing" || fail "build/Pave.app is not signed with \"Pave Dev\""
codesign --verify --strict build/Pave.app || fail "build/Pave.app: invalid signature"
# Installed copies only look for releases signed with this certificate.
certs=$(mktemp -d "${TMPDIR:-/tmp}/pave-cert.XXXXXX")
codesign -d --extract-certificates="$certs/cert" build/Pave.app 2>/dev/null </dev/null
signed_with=$(shasum -a 256 "$certs/cert0" | cut -d' ' -f1)
rm -rf "$certs"
[[ "$signed_with" == "$(tr -d '[:space:]' < Resources/update-cert.sha256 | tr 'A-F' 'a-f')" ]] \
  || fail "build/Pave.app is signed with a certificate ($signed_with) other than Resources/update-cert.sha256: installed copies would not see this release"
built=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Pave.app/Contents/Info.plist)
[[ "$built" == "$version" ]] || fail "built $built, expected $version"

out=dist/release-$version
rm -rf "$out"
mkdir -p "$out"
archive="Pave_${version}.app.tar.gz"
dmg="Pave_${version}.dmg"
COPYFILE_DISABLE=1 tar -czf "$out/$archive" -C build Pave.app
stage=$(mktemp -d "${TMPDIR:-/tmp}/pave-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto build/Pave.app "$stage/Pave.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "Pavé $version" -srcfolder "$stage" -ov -format UDZO "$out/$dmg"

step "Sign"
for file in "$archive" "$dmg"; do
  (cd "$out" && shasum -a 256 "$file" > "$file.sha256")
  minisign -S -s "$sign_key" -m "$out/$file" -t "file:$file"
  minisign -V -q -p Resources/update-key.pub -m "$out/$file" || fail "$file: the signature does not verify with Resources/update-key.pub (another key?)"
done

previous=$(git describe --tags --match 'pave-v*' --abbrev=0 "$commit^" 2>/dev/null || true)
{
  if [[ -n "$notes_file" ]]; then cat "$notes_file"
  elif [[ -n "$notes" ]]; then printf '%s\n' "$notes"
  elif [[ -n "$previous" ]]; then git log --no-merges --format='- %s' "$previous..$commit"
  else echo "First release of Pavé."
  fi
  cat <<EOF

---
**Update**: Pavé installs it itself (menu bar › Install Pavé ${version}…, or \`pave update install\`).
**First install**: open \`${dmg}\`, drag Pavé to Applications, then, since Pavé is not notarized:
\`\`\`
xattr -dr com.apple.quarantine /Applications/Pave.app
\`\`\`
EOF
} > "$out/notes.md"

step "Release"
ls -1 "$out"
echo
cat "$out/notes.md"
if $dry; then
  echo
  echo "dry run: nothing published"
  exit 0
fi
gh release create "$tag" -R "$repo" --target "$commit" --title "Pavé $version" --notes-file "$out/notes.md" \
  "$out/$dmg" "$out/$dmg.sha256" "$out/$dmg.minisig" \
  "$out/$archive" "$out/$archive.sha256" "$out/$archive.minisig"
git fetch -q origin "refs/tags/$tag:refs/tags/$tag"
echo "published: $(gh release view "$tag" -R "$repo" --json url -q .url)"
