# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Everything Pavé can be asked to do; `just` lists it. `just ci` is the gate:
# the commits, formatting, a build without a warning, the string catalog, the
# SPDX lines, then the tests, fastest failure first.
#
# The recipes down to `release` exist in every app of the P suite, with the same
# meaning (p-suite's SUITE.md § 4).
#
# Uses the full Xcode toolchain when present (the Command Line Tools lack the
# SwiftUI and Swift Testing macro plugins); override with DEVELOPER_DIR=... just <task>.

xcode := "/Applications/Xcode.app/Contents/Developer"
export DEVELOPER_DIR := env("DEVELOPER_DIR", if path_exists(xcode) == "true" { xcode } else { "" })
# The daily-use copy, the one the login item points at.
install_dir := home_directory() / "Applications"
state := home_directory() / ".local/state/pave"

# List the recipes.
default:
    @just --list --unsorted

# ---------------------------------------------------------------- development

# There is no hosted pipeline, so this machine is the pipeline: a missing tool is
# a check that silently never runs.
# Report anything missing from the toolchain.
doctor:
    #!/usr/bin/env bash
    set -uo pipefail
    missing=0
    for tool in swift swift-format xcrun minisign gh; do
        if command -v "$tool" > /dev/null 2>&1; then
            printf '  %-14s %s\n' "$tool" "$($tool --version 2>&1 | head -1)"
        else
            printf '  %-14s MISSING\n' "$tool"
            missing=1
        fi
    done
    if [ ! -d "{{xcode}}" ]; then
        printf '  %-14s MISSING (the SwiftUI and Swift Testing macros need it)\n' "Xcode"
        missing=1
    fi
    if ! security find-certificate -c "Pave Dev" > /dev/null 2>&1; then
        printf '  %-14s MISSING (just cert)\n' "Pave Dev cert"
        missing=1
    fi
    if [ "$missing" -ne 0 ]; then
        echo
        echo "  Install the missing tools before trusting 'just ci'."
        echo "    brew install minisign gh"
        exit 1
    fi
    echo
    echo "  ✓ toolchain complete"

# Resolve the Swift package's dependencies.
install:
    swift package resolve

# Always through LaunchServices (`open`), never the binary from a terminal: it
# would get the terminal's TCC permissions, making the Accessibility check
# meaningless. A restart, not a quit: Pavé keeps the Dock hidden (no flash).
# Rebuild, then (re)launch build/Pave.app; logs in build/pave.log.
dev: app
    @pgrep -x Pave >/dev/null && mkdir -p "{{state}}" && touch "{{state}}/restarting" || true
    @pkill -x Pave || true
    @# The old instance restores parked windows on SIGTERM: let it finish (max 5 s).
    @scripts/wait-exit.sh Pave 5
    @: > build/pave.log
    open -n --stderr "{{justfile_directory()}}/build/pave.log" build/Pave.app
    @sleep 1; cat build/pave.log

# The former name of `dev`, kept while the habit goes.
[private]
run: dev

# Same signature as the dev build, so the TCC permissions follow.
# Build, copy to ~/Applications/Pave.app and launch it; logs in ~/Library/Logs/Pave.
deploy: app
    @pgrep -x Pave >/dev/null && mkdir -p "{{state}}" && touch "{{state}}/restarting" || true
    @pkill -x Pave || true
    @scripts/wait-exit.sh Pave 5
    @mkdir -p "{{install_dir}}"
    @rm -rf "{{install_dir}}/Pave.app"
    ditto build/Pave.app "{{install_dir}}/Pave.app"
    open "{{install_dir}}/Pave.app"
    @sleep 1; tail -3 "$HOME/Library/Logs/Pave/pave.log"

# Format the Swift sources in place (.swift-format).
fmt:
    swift format --in-place --recursive --parallel Sources Tests Package.swift scripts/make-icon.swift

# Extract the interface strings from the code into Resources/Localizable.xcstrings.
strings:
    scripts/strings.sh sync

# Redraw Resources/AppIcon.icns (scripts/make-icon.swift).
icon:
    @rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
    @for s in 16 32 128 256 512; do \
        swift scripts/make-icon.swift cobbles build/AppIcon.iconset/icon_${s}x${s}.png $s; \
        swift scripts/make-icon.swift cobbles build/AppIcon.iconset/icon_${s}x${s}@2x.png $((s * 2)); \
    done
    iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

# One-time: create the "Pave Dev" signing certificate.
cert:
    scripts/make-dev-cert.sh

# ---------------------------------------------------------------------- checks

# Warnings are errors here: an ignored warning is a warning that never goes away.
# The fast static checks: formatting, a build without a warning, translations.
check: fmt-check
    swift build -Xswiftc -warnings-as-errors
    scripts/strings.sh check

# Fail if anything is unformatted.
fmt-check:
    swift format lint --strict --recursive --parallel Sources Tests Package.swift scripts/make-icon.swift

# Fail if an interface string has no translation.
check-strings:
    scripts/strings.sh check

# The release notes are built from the commit subjects (ADR 0001).
# Check that the commits since the last release are Conventional; a range checks those instead.
check-commits *args:
    scripts/check-commits.sh {{args}}

# Every source file carries the SPDX line (ADR 0001).
spdx:
    scripts/check-spdx.sh

# Run the unit tests.
test:
    swift test

# The gate: everything a machine can check, before every commit meant to stay.
ci: check-commits check spdx test
    @echo "\n  ✓ all checks passed"

# -------------------------------------------------------------------- packaging

# Build and sign build/Pave.app (+ build/pave CLI), for development.
app:
    scripts/bundle.sh

# Build and sign the release build/Pave.app, the one `just release` publishes.
build:
    scripts/bundle.sh release

# Remove what the builds left.
clean:
    rm -rf .build build

# ---------------------------------------------------------------------- release

# What changed since the last release, from the commit subjects. `--help` for the options.
changelog *args:
    scripts/changelog.sh {{args}}

# Publish a GitHub release of this commit (scripts/release.sh; `just release --dry-run` first).
release *args:
    scripts/release.sh {{args}}
