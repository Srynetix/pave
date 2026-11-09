#!/usr/bin/env bash
# Build Pave.app from the SwiftPM products and sign it.
#
# Signing with a *stable* identity ("Pave Dev", see make-dev-cert.sh) keeps the
# code-signing requirement identical across rebuilds, so macOS does not revoke
# the Accessibility permission every time. Ad-hoc signing ("-") is a fallback:
# it works, but the permission must then be granted again after each build.
#
# usage: scripts/bundle.sh [debug|release]
set -euo pipefail

# Prefer the full Xcode toolchain (Command Line Tools lack the Swift Testing
# macro plugin); no need to change xcode-select globally.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

CONFIG="${1:-debug}"
IDENTITY="${PAVE_SIGN_IDENTITY:-Pave Dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Pave.app"

cd "$ROOT"
swift build -c "$CONFIG" --product PaveApp
swift build -c "$CONFIG" --product pave
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# The public key updates are checked with (minisign, scripts/release.sh).
cp "$ROOT/Resources/update-key.pub" "$APP/Contents/Resources/update-key.pub"
# The SHA-256 of the certificate releases are signed with: a copy signed
# with another one (built from source elsewhere) does not look for updates.
cp "$ROOT/Resources/update-cert.sha256" "$APP/Contents/Resources/update-cert.sha256"
# Unique build number. Info.plist is sealed by the signature, so every build
# gets a new cdhash: this is what proves the TCC permission survives rebuilds.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M%S)" "$APP/Contents/Info.plist"
# Branch and commit, for the About window ("-dirty": uncommitted changes).
COMMIT="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?") @ $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "?")"
git -C "$ROOT" diff --quiet HEAD 2>/dev/null || COMMIT="$COMMIT-dirty"
/usr/libexec/PlistBuddy -c "Add :PaveCommit string $COMMIT" "$APP/Contents/Info.plist"
cp "$BIN/PaveApp" "$APP/Contents/MacOS/Pave"
# Interface strings: en.lproj, fr.lproj… from the catalog (scripts/strings.sh).
xcrun xcstringstool compile "$ROOT/Resources/Localizable.xcstrings" --output-directory "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources/en.lproj"  # English is the source: keys are the text
cp "$BIN/pave" "$ROOT/build/pave"

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    # Hardened runtime: no injected libraries (DYLD_INSERT_LIBRARIES, unsigned
    # dylibs) can borrow Pavé's permissions (Accessibility, event tap, screen capture).
    codesign --force --options runtime --sign "$IDENTITY" --identifier dev.srynetix.pave.Pave "$APP"
    echo "signed with '$IDENTITY'"
else
    codesign --force --sign - --identifier dev.srynetix.pave.Pave "$APP"
    echo "warning: identity '$IDENTITY' not found, ad-hoc signed." >&2
    echo "         The Accessibility permission will be lost on every rebuild." >&2
    echo "         Run scripts/make-dev-cert.sh once to fix this." >&2
fi

codesign --display --requirements - "$APP" 2>&1 | grep designated || true
echo "built $APP"
echo "CLI:  $ROOT/build/pave"
