# Pavé's tasks (`just` lists them). Uses the full Xcode toolchain when present
# (the Command Line Tools lack the Swift Testing macro plugin); override with
# DEVELOPER_DIR=... just <task>.
xcode := "/Applications/Xcode.app/Contents/Developer"
export DEVELOPER_DIR := env("DEVELOPER_DIR", if path_exists(xcode) == "true" { xcode } else { "" })
# The daily-use copy, the one the login item points at.
install_dir := home_directory() / "Applications"
state := home_directory() / ".local/state/pave"

# List the tasks
default:
    @just --list --unsorted

# Build and sign build/Pave.app (+ build/pave CLI)
app:
    scripts/bundle.sh

# Rebuild, then (re)launch Pave.app; logs in build/pave.log
run: app
    @# A restart, not a quit: Pavé keeps the Dock hidden (no flash), see DockController.
    @pgrep -x Pave >/dev/null && mkdir -p "{{state}}" && touch "{{state}}/restarting" || true
    @pkill -x Pave || true
    @# The old instance restores parked windows on SIGTERM: let it finish (max 5 s).
    @scripts/wait-exit.sh Pave 5
    @: > build/pave.log
    @# Through LaunchServices (`open`), never the binary from a terminal: it would
    @# get the terminal's TCC permissions, making the Accessibility check meaningless.
    open -n --stderr "{{justfile_directory()}}/build/pave.log" build/Pave.app
    @sleep 1; cat build/pave.log

# Build, copy to ~/Applications/Pave.app and launch it; logs in ~/Library/Logs/Pave
install: app
    @# Same signature as the dev build, so the TCC permissions follow.
    @pgrep -x Pave >/dev/null && mkdir -p "{{state}}" && touch "{{state}}/restarting" || true
    @pkill -x Pave || true
    @scripts/wait-exit.sh Pave 5
    @mkdir -p "{{install_dir}}"
    @rm -rf "{{install_dir}}/Pave.app"
    ditto build/Pave.app "{{install_dir}}/Pave.app"
    open "{{install_dir}}/Pave.app"
    @sleep 1; tail -3 "$HOME/Library/Logs/Pave/pave.log"

# Run the unit tests
test:
    swift test

# Extract the interface strings from the code into Resources/Localizable.xcstrings
strings:
    scripts/strings.sh sync

# Fail if an interface string has no translation
check-strings:
    scripts/strings.sh check

# Redraw Resources/AppIcon.icns (scripts/make-icon.swift)
icon:
    @rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
    @for s in 16 32 128 256 512; do \
        swift scripts/make-icon.swift cobbles build/AppIcon.iconset/icon_${s}x${s}.png $s; \
        swift scripts/make-icon.swift cobbles build/AppIcon.iconset/icon_${s}x${s}@2x.png $((s * 2)); \
    done
    iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

# Publish a GitHub release of this commit (scripts/release.sh; e.g. just release --dry-run)
release *args:
    scripts/release.sh {{args}}

# One-time: create the "Pave Dev" signing certificate
cert:
    scripts/make-dev-cert.sh

clean:
    rm -rf .build build
