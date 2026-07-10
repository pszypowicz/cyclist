# Cyclist

A keyboard-driven app switcher for macOS. No thumbnails, no window screenshots - just a list of app icons, names, and window titles you cycle through with Cmd+Tab.

> **Beta.** Cyclist is in early development (0.x). Expect rough edges, hardcoded shortcuts, and breaking changes between releases.

## What it does

- Replaces the native Cmd+Tab switcher with a vertical, text-only list in most-recently-used app order. Every window gets its own row (`App - Window title`), so two Safari windows are two entries.
- Windows in other Spaces (including native fullscreen) get their own rows too. With Screen Recording permission granted their titles are live; without it, each row shows the last title Cyclist saw while that window was visible. Selecting a row jumps straight to that Space.
- A separate binding (Cmd+`) cycles through the windows of the frontmost app, including minimized ones - something the native window cycler skips.
- Four independent settings control what shows up in the list:
  - include **hidden** apps (Cmd+H)
  - include **minimized** apps (all windows in the Dock)
  - include apps whose windows live in **other Spaces** (including native fullscreen)
  - include running apps with **no windows** at all (off by default; selecting one behaves like clicking its Dock icon, so the app reopens a window)

## Keybindings

| Keys                | Action                             |
| ------------------- | ---------------------------------- |
| Cmd+Tab (quick tap) | Switch to the previous app         |
| Cmd+Tab (hold Cmd)  | Open the list; each Tab advances   |
| Cmd+Shift+Tab       | Cycle backward                     |
| Cmd+`               | Cycle windows of the frontmost app |
| Esc (while open)    | Cancel                             |
| Release Cmd         | Switch to the selected item        |

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

On first launch Cyclist prompts for Accessibility permission and activates itself once granted. It lives in the menu bar (no Dock icon); the menu holds the three list settings and Quit.

The build script signs with your "Apple Development" certificate when one is present so the Accessibility grant survives rebuilds. See `scripts/build-app.sh --help` for options.

## AeroSpace

Cyclist works well alongside [AeroSpace](https://github.com/nikitabobko/AeroSpace). AeroSpace emulates workspaces without macOS Spaces, so every window is visible to Cyclist regardless of workspace, and activating an app in another workspace makes AeroSpace follow focus there automatically. AeroSpace is not required.

## Known limitations

- Switching to a window in another Space (including native fullscreen) navigates there by synthesizing the Mission Control "Move left/right a space" shortcut, because macOS performs no Space transition for plain app activation. Keep those shortcuts enabled (System Settings > Keyboard > Keyboard Shortcuts > Mission Control); without them Cyclist falls back to a Dock-style activation, which reaches regular Spaces but not fullscreen ones.

- While a password field has secure input enabled, macOS withholds keystrokes from event taps, so Cmd+Tab temporarily falls through to the native switcher.
- Same-app window cycling covers windows in the current Space plus minimized ones; the Accessibility API cannot see individual windows parked in other Spaces (app-level switching still reaches those apps).
- The list is keyboard-only; the panel ignores mouse clicks.
- Shortcuts are not yet rebindable.
