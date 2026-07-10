# Cyclist

A keyboard-driven app switcher for macOS. No thumbnails, no window screenshots - just a list of app icons, names, and window titles you cycle through with Cmd+Tab.

> **Beta.** Cyclist is in early development (0.x). Expect rough edges, hardcoded shortcuts, and breaking changes between releases.

## What it does

- Replaces the native Cmd+Tab switcher with a vertical, text-only list in most-recently-used app order. Every window gets its own row (`App - Window title`), so two Safari windows are two entries.
- Windows in other Spaces (including native fullscreen) get their own rows too. With Screen Recording permission granted their titles are live; without it, each row shows the last title Cyclist saw while that window was visible. Selecting a row jumps straight to that Space.
- A separate binding (Cmd+`) cycles through the windows of the frontmost app, including minimized ones - something the native window cycler skips.
- Ctrl+Left/Right and a 3-finger horizontal trackpad swipe walk an ordered chain of AeroSpace workspaces (those with windows in the user Space, plus the focused one) followed by native fullscreen Spaces - instantly, without Mission Control. Without AeroSpace the chain is just the user Space plus fullscreen Spaces.
- Four independent settings control what shows up in the list:
  - include **hidden** apps (Cmd+H)
  - include **minimized** apps (all windows in the Dock)
  - include apps whose windows live in **other Spaces** (including native fullscreen)
  - include running apps with **no windows** at all (off by default; selecting one behaves like clicking its Dock icon, so the app reopens a window)

## Keybindings

| Keys                | Action                                        |
| ------------------- | --------------------------------------------- |
| Cmd+Tab (quick tap) | Switch to the previous app                    |
| Cmd+Tab (hold Cmd)  | Open the list; each Tab advances              |
| Cmd+Shift+Tab       | Cycle backward                                |
| Cmd+`               | Cycle windows of the frontmost app            |
| Esc (while open)    | Cancel                                        |
| Release Cmd         | Switch to the selected item                   |
| Ctrl+Left / Right   | Previous / next workspace or fullscreen Space |
| 3-finger swipe      | Walk the same workspace chain                 |

Shortcuts are hardcoded in this release and use physical key positions (Tab and the key left of 1), so they may land oddly on some non-US layouts.

## Requirements

- macOS 13 or later
- **Accessibility** permission (System Settings > Privacy & Security > Accessibility) - required for the global Cmd+Tab hook and for reading window state
- **Screen Recording** permission, optional but recommended - macOS gates the titles of windows in other Spaces behind it. Cyclist uses it solely to read those titles and never captures window contents; there are no thumbnails or screenshots anywhere in the UI. Without it, other-Space rows show the last title Cyclist saw while the window was visible

## Build and install

```sh
scripts/build-app.sh
cp -R build/Cyclist.app /Applications/
open /Applications/Cyclist.app
```

On first launch Cyclist prompts for Accessibility permission and activates itself once granted. It lives in the menu bar (no Dock icon); the menu holds the list settings, a native Launch at Login toggle (registers with System Settings > General > Login Items), and Quit.

Cyclist also exposes its instant Space-switching engine as a CLI for other tools (e.g. a Hammerspoon workspace chain): `Cyclist --goto-space <space-id>` switches and exits; see `--help`.

The build script signs with your "Apple Development" certificate when one is present so the Accessibility grant survives rebuilds. See `scripts/build-app.sh --help` for options.

## AeroSpace

Cyclist works well alongside [AeroSpace](https://github.com/nikitabobko/AeroSpace). AeroSpace emulates workspaces without macOS Spaces, so every window is visible to Cyclist regardless of workspace, and activating an app in another workspace makes AeroSpace follow focus there automatically. The Ctrl+Arrow / 3-finger-swipe chain integrates deeper: it walks AeroSpace workspaces (via the `aerospace` CLI, focusing a concrete user-Space window per workspace so a fullscreen sibling cannot hijack the switch) before the native fullscreen Spaces. AeroSpace is not required - without it the chain degrades to user Space plus fullscreen Spaces.

## Known limitations

- Switching to a window in another Space (including native fullscreen) jumps there near-instantly by posting synthetic high-velocity trackpad swipe gestures, the technique shared by Space Rabbit, InstantSpaceSwitcher, and Spaceman - macOS performs no Space transition for plain app activation, and the animated route takes over a second per Space. The jump is verified and retried a few times; if a future macOS breaks the gesture encoding entirely, cross-Space switching stops working until the encoding is updated.
- Cyclist consumes Ctrl+Left/Right for chain navigation; disable the equivalent Mission Control shortcuts if you do not want both meanings, and quit Cyclist to get the native behavior back.

- While a password field has secure input enabled, macOS withholds keystrokes from event taps, so Cmd+Tab temporarily falls through to the native switcher.
- Same-app window cycling covers windows in the current Space plus minimized ones; the Accessibility API cannot see individual windows parked in other Spaces (app-level switching still reaches those apps).
- The list is keyboard-only; the panel ignores mouse clicks.
- Shortcuts are not yet rebindable.
