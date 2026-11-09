# Contributing

Thanks for looking. Pavé is a personal project used every day by its author:
issues are welcome, and pull requests too, small and focused ones first.

## Build and run

You need macOS 15 or later, Xcode in `/Applications/Xcode.app` and
[just](https://just.systems) (`brew install just`).

```sh
just cert      # once: a self-signed "Pave Dev" certificate, so the
               # Accessibility permission survives rebuilds
just run       # build/Pave.app, logs in build/pave.log
just test      # the unit tests (PaveCore, PaveIPC)
just install   # ~/Applications/Pave.app, the copy you use every day
```

Grant **Accessibility** to the build on first launch. Your builds are signed
with your own certificate: they do not look for Pavé's releases, they update
with your next `just install`.

## Before sending a change

- `just test` passes, and the build has no warning.
- Interface strings: `just strings`, then translate the new ones in
  `Resources/Localizable.xcstrings` (English and French); `just check-strings`
  must pass.
- Logic that does not need macOS goes into `PaveCore`, with tests.
- Never log a window title or a workspace name.
- Private APIs only in `Sources/PaveMac/Private.swift`.

The README's **Development** section describes the layout of the code.
