# Security

Pavé runs with the Accessibility permission (it moves other apps' windows and
reads your shortcuts through an event tap), may record the screen for
previews, and replaces itself when it updates. A flaw in it can matter, so
please report one privately.

## Reporting a vulnerability

Open a [private security advisory](https://github.com/Srynetix/pave/security/advisories/new)
on GitHub rather than a public issue. Say what an attacker can do, on which
version, and how to reproduce it. You should get an answer within a week.

## What Pavé already guards against

- **Updates**: an archive is installed only if its minisign signature comes
  from the key built into the app (`Resources/update-key.pub`) and names that
  very file, and if the new app is code-signed with the same certificate and
  identifier as the running one. Nothing is extracted before both checks; an
  older version is never installed.
- **The CLI socket** (`~/.local/state/pave/pave.sock`) is reachable by your
  user only (mode `0600`, in a `0700` folder), and a slow client cannot block
  the others.
- **Logs** hold neither window titles nor workspace names. Previews stay in
  memory and never reach the disk.
- **Hardened runtime**: no injected library can borrow Pavé's permissions.

Private macOS APIs are confined to `Sources/PaveMac/Private.swift`.
