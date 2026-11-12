# Building and releasing

You need macOS 15 or later, Xcode in `/Applications/Xcode.app` and [just](https://just.systems)
(`brew install just`). `just doctor` lists what this machine is missing; `just cert`, once,
creates the self-signed "Pave Dev" certificate, so the Accessibility permission survives
rebuilds.

## The development loop

```sh
just dev            # build and sign build/Pave.app, then launch it (logs: build/pave.log)
just deploy         # the same, installed as ~/Applications/Pave.app, the copy you use every day
just fmt            # format the Swift sources (swift-format, .swift-format)
just test           # unit tests
just ci             # the gate: commits, formatting, a build without a warning, strings, tests
just strings        # extract the interface strings into Resources/Localizable.xcstrings
just check-strings  # fail if a string has no translation
just icon           # redraw Resources/AppIcon.icns (scripts/make-icon.swift)
just changelog      # the notes of the next release, from the commit subjects
just release        # publish a GitHub release of this commit (just release --dry-run to try)
```

Always launch through `just dev` or `open`, never `build/Pave.app/Contents/MacOS/Pave` from a
terminal: macOS would give the permissions to the terminal. Only one Pavé runs at a time:
`just dev` stops the installed copy, `just deploy` restarts it. The Command Line Tools alone
lack the SwiftUI and Swift Testing macro plugins, hence the Xcode requirement.

The five targets and what each may depend on are in [Architecture](architecture.md).

## Localization

Strings live in [`Resources/Localizable.xcstrings`](../../Resources/Localizable.xcstrings),
English being the source language. Literals given to SwiftUI views are localized keys; strings
built in code go through `String(localized:)`. `just strings` extracts new strings into the
catalog, and `just check-strings` (part of `just ci`) fails while one has no translation.

To add a language, add it to `LANGUAGES` in [`scripts/strings.sh`](../../scripts/strings.sh)
and to `CFBundleLocalizations` in [`Resources/Info.plist`](../../Resources/Info.plist), then
translate in the catalog.

## Releases

Bump `CFBundleShortVersionString` in `Resources/Info.plist`, commit, push, then `just release`
([`scripts/release.sh`](../../scripts/release.sh); `just release --dry-run` first). It runs
`just ci`, builds a release `Pave.app` signed with "Pave Dev", and publishes, as the release
`pave-v<version>` with `just changelog` as notes:

- `Pave_<version>.dmg`, for a first install;
- `Pave_<version>.app.tar.gz`, what updates install;
- each with its `.sha256` and its `.minisig`.

Signing uses `~/.minisign/pave.key` (or `PAVE_SIGN_KEY`), whose public half is
[`Resources/update-key.pub`](../../Resources/update-key.pub); create it once with
`minisign -G -s ~/.minisign/pave.key -p Resources/update-key.pub`.

Installed copies look for releases only if they are signed with the certificate whose SHA-256
is in [`Resources/update-cert.sha256`](../../Resources/update-cert.sha256) (`just release`
checks it); a fork that publishes its own releases replaces both files. Keep a backup of the
minisign key and of the "Pave Dev" certificate (Keychain Access › export as `.p12`): without
the same two, installed copies refuse the next update, or lose the Accessibility permission.
Releases are built on a Mac, not on a hosted runner, for that reason.

## Private APIs

Pavé uses `_AXUIElementGetWindow` and a few CGS functions (to tell windows of other native
Spaces apart), all in [`Sources/PaveMac/Private.swift`](../../Sources/PaveMac/Private.swift)
([Architecture › Platform code](architecture.md#platform-code)). They may break with a macOS
update, and they rule out the Mac App Store.
