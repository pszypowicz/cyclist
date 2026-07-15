<p align="center">
  <img src="docs/icon.png" width="128" alt="Cyclist app icon">
</p>

# Cyclist

A keyboard-driven app switcher for macOS. No thumbnails, no window screenshots - just a list of app icons, names, and window titles you cycle through with Cmd+Tab.

> **Beta.** Cyclist is in early development (0.x). Expect rough edges, hardcoded shortcuts, and breaking changes between releases.

## What it does

- Replaces the native Cmd+Tab switcher with a vertical, text-only list in most-recently-used app order. Every window gets its own row (`App - Window title`), so two Safari windows are two entries.
- Windows in other Spaces (including native fullscreen) get their own rows too. With Screen Recording permission granted their titles are live; without it, each row shows the last title Cyclist saw while that window was visible. Selecting a row jumps straight to that Space.
- A separate binding (Cmd+`) cycles through the windows of the frontmost app in most-recently-used order, including minimized ones and windows in other Spaces (native fullscreen included) - things the native window cycler skips. A quick tap bounces between the app's last two windows.
- Ctrl+Left/Right walks the native Spaces of the primary display in Mission Control order - user desktops and fullscreen Spaces alike - instantly and without animation. Arriving on a desktop focuses its top window, so leaving a fullscreen app always lands somewhere concrete.
- With [AeroSpace](https://github.com/nikitabobko/AeroSpace) running, its workspaces join that ring in place of the desktop hosting them, so Ctrl+Left/Right walks `workspace 1 ... workspace N, fullscreen Spaces` seamlessly - workspace steps go over AeroSpace's socket, and crossing from a fullscreen Space lands on the ring-adjacent workspace. Windows parked in hidden workspaces appear in the switcher as `workspace N` rows; selecting one switches there. Detection is automatic and everything falls back to plain native behavior the moment AeroSpace is absent, disabled, or the menu-bar toggle is off.
- Four independent settings control what shows up in the list:
  - include **hidden** apps (Cmd+H)
  - include **minimized** apps (all windows in the Dock)
  - include apps whose windows live in **other Spaces** (including native fullscreen)
  - include running apps with **no windows** at all (off by default; selecting one behaves like clicking its Dock icon, so the app reopens a window)

## Keybindings

| Keys                | Action                                        |
| ------------------- | --------------------------------------------- |
| Cmd+Tab (quick tap) | Switch to the previous window (any app)       |
| Cmd+Tab (hold Cmd)  | Open the list; each Tab advances              |
| Cmd+Shift+Tab       | Cycle backward                                |
| Cmd+`               | Cycle windows of the frontmost app            |
| Up/Down, K/J (open) | Move the selection                            |
| Q (while open)      | Quit the selected app                         |
| W (while open)      | Close the selected window                     |
| Esc (while open)    | Cancel                                        |
| Release Cmd         | Switch to the selected item                   |
| Ctrl+Left / Right   | Previous / next workspace or fullscreen Space |

Shortcuts are hardcoded in this release and use physical key positions (Tab and the key left of 1), so they may land oddly on some non-US layouts.

## Requirements

- macOS 13 or later
- **Accessibility** permission (System Settings > Privacy & Security > Accessibility) - required for the global Cmd+Tab hook and for reading window state
- **Screen Recording** permission, optional but recommended - macOS gates the titles of windows in other Spaces behind it. Cyclist uses it solely to read those titles and never captures window contents; there are no thumbnails or screenshots anywhere in the UI. Without it, other-Space rows show the last title Cyclist saw while the window was visible

## Install

### Homebrew

```sh
brew install --cask pszypowicz/tap/cyclist
```

The cask clears the quarantine flag (release builds are not notarized yet) and launches the app after install.

### Build from source

```sh
scripts/build-app.sh
cp -R build/Cyclist.app /Applications/
open /Applications/Cyclist.app
```

The build script signs with your "Apple Development" certificate when one is present so the Accessibility grant survives rebuilds. See `scripts/build-app.sh --help` for options.

On first launch Cyclist prompts for Accessibility permission and activates itself once granted. It lives in the menu bar (no Dock icon); the menu holds the list settings, a native Launch at Login toggle (registers with System Settings > General > Login Items), and Quit.

## Known limitations

- Switching to a window in another Space (including native fullscreen) jumps there near-instantly by posting synthetic high-velocity trackpad swipe gestures, the technique shared by Space Rabbit, InstantSpaceSwitcher, and Spaceman - macOS performs no Space transition for plain app activation, and the animated route takes over a second per Space. The jump is verified and retried a few times; if a future macOS breaks the gesture encoding entirely, cross-Space switching stops working until the encoding is updated.
- Cyclist consumes Ctrl+Left/Right for chain navigation; disable the equivalent Mission Control shortcuts if you do not want both meanings, and quit Cyclist to get the native behavior back.

- While a password field has secure input enabled, macOS withholds keystrokes from event taps, so Cmd+Tab temporarily falls through to the native switcher.
- Same-app window rows for other Spaces rely on the window-server list; their titles need Screen Recording permission or a previous sighting of the window (same rule as the app switcher's other-Space rows).
- The AeroSpace bridge speaks the server's socket protocol (version 1) and tracks the workspaces of AeroSpace's focused monitor. With several native desktops the ring only expands the current one.
- The list is keyboard-only; the panel ignores mouse clicks.
- Shortcuts are not yet rebindable.
