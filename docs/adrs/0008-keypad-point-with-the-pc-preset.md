# 8. The "pc" preset types a point on the keypad

- **Status:** accepted
- **Date:** 2026-11-24
- **Deciders:** Denis Bourge

## Context and problem statement

On the Mac's French layouts, the numeric keypad's decimal key types ",". On a French PC it
types ".", the habit of people coming from Windows, and what a number typed for code, a
terminal or a version needs. The keyboard remap is `hidutil`, which moves keys but cannot
change the character a key types.

Where does the point come from, and who gets it?

## Decision

1. **The event tap rewrites the character.** A key-down or key-up of the keypad's decimal key
   that goes on to the apps carries "." as its text (`CGEvent.keyboardSetUnicodeString`). The
   key code is unchanged.
2. **It is part of the "pc" preset**, with no key of its own: on when `[keyboard] remap` is on
   and `preset = "pc"`, as the rest of the PC habits, and off while Karabiner-Elements runs,
   as the `hidutil` remap. The rules are `KeyRemap.character` and `KeyRemap.typingPreset` in
   `PaveCore`, with their tests. The switcher's search types the same character.
3. **Only the key alone.** With ⇧ or a shortcut's modifier, the layout's character is kept, so
   shortcuts on that key do not change.

## Options considered

### The "pc" preset — chosen

No new setting: a PC habit goes with the others.

### A `[keyboard] keypad-decimal` key ("." or ",") — rejected

Says the choice plainly and works with any preset, but adds a key to the config for one
character.

### Another key with `hidutil` — rejected

No key of the keypad types "." on the French layouts: there is nothing to map it to.

## Consequences

1. **Every keyboard gets it**, `[keyboard] skip` included: the tap does not know which keyboard
   a key comes from.
2. **Password fields still get ","**: with secure input on (a password, Terminal's Secure
   Keyboard Entry), macOS hides the keys from event taps. Only a keyboard layout could change
   that, and Pavé does not install one.
3. **Comma layouts other than French get the point too**, with the "pc" preset; the preset
   `"none"` keeps the layout's character.
4. **An app that reads key codes rather than text** (a game, a remote desktop) still sees the
   keypad's decimal key, and types what its own layout says.
