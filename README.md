<p align="center">
  <img src="docs/icon.png" width="128" alt="Cyclist app icon">
</p>

# Cyclist

A keyboard-driven app switcher for macOS. No thumbnails, no window screenshots - just a list of app icons, names, and window titles you cycle through with Cmd+Tab.

> **Beta.** Cyclist is in early development (0.x). Expect rough edges and breaking changes between releases.

<p align="center">
  <img src="docs/demo.svg" width="830" alt="Hold Cmd to open a vertical text list where every window is its own row, some tagged 'other space'; move the selection to a Safari window that lives in a fullscreen Space, release Cmd, and the display jumps straight to that Space.">
</p>

## What it does

- Replaces the native Cmd+Tab switcher with a vertical, text-only list in most-recently-used app order. Every window gets its own row (`App - Window title`), so two Safari windows are two entries, and within an app the rows are ordered by when you last used each window.
- A quick Cmd+Tab tap returns to the previous window, wherever it lives - even between two windows of the same app, and even across Spaces or workspaces.
- Windows in other Spaces (including native fullscreen) get their own rows too. With Screen Recording permission granted their titles are live; without it, each row shows the last title Cyclist saw while that window was visible. Selecting a row jumps straight to that Space.
- A separate binding (Cmd+`) cycles through the windows of the frontmost app in most-recently-used order, including minimized ones and windows in other Spaces (native fullscreen included) - things the native window cycler skips. A quick tap bounces between the app's last two windows.
- Ctrl+Left/Right walks the native Spaces of the active display (the one holding the menu bar) in Mission Control order - user desktops and fullscreen Spaces alike - instantly and without animation. Arriving on a desktop focuses its top window, so leaving a fullscreen app always lands somewhere concrete.
- The trackpad's Spaces swipe (three or four fingers, per System Settings > Trackpad > More Gestures) drives that same navigation: Cyclist intercepts the gesture before the Dock sees it and steps instantly instead of playing the animated transition. The system gesture must stay **enabled** - it is what makes macOS emit the gesture events at all. A Settings toggle ("Trackpad swipe navigation") hands the gesture back to macOS at any time.
- With [AeroSpace](https://github.com/nikitabobko/AeroSpace) running, its workspaces join that ring in place of the desktop hosting them, so Ctrl+Left/Right walks `workspace 1 ... workspace N, fullscreen Spaces` seamlessly - workspace steps go over AeroSpace's socket, and crossing from a fullscreen Space lands on the ring-adjacent workspace. Windows parked in hidden workspaces appear in the switcher as `workspace N` rows; selecting one switches there. A workspace whose windows all went native-fullscreen is hollow - its windows display on their own Spaces and visiting it shows a bare desktop - so the ring skips it by default and the fullscreen Space itself is the stop; the `showHollowWorkspaces` setting restores those stops. The integration is opt-in (Settings > AeroSpace, or the `aerospaceIntegration` default) and everything falls back to plain native behavior the moment AeroSpace is absent or disabled.
- Four independent settings control what shows up in the list:
  - include **hidden** apps (Cmd+H)
  - include **minimized** apps (all windows in the Dock)
  - include apps whose windows live in **other Spaces** (including native fullscreen)
  - include running apps with **no windows** at all (off by default; selecting one behaves like clicking its Dock icon, so the app reopens a window)

## Keybindings

The four global shortcuts below are the defaults - rebind them in Settings (click the shortcut, press the new keys) or with `defaults write` (see Configuration).

Global - work anytime:

| Keys                | Action                                        |
| ------------------- | --------------------------------------------- |
| Cmd+Tab (quick tap) | Switch to the previous window (any app)       |
| Cmd+Tab (hold Cmd)  | Open the switcher list (Shift reverses)       |
| Cmd+`               | Cycle windows of the frontmost app            |
| Ctrl+Left / Right   | Previous / next workspace or fullscreen Space |
| Trackpad swipe      | Previous / next workspace or fullscreen Space |

While the switcher is open (Cmd held):

| Keys            | Action                          |
| --------------- | ------------------------------- |
| Tab / Shift+Tab | Advance / reverse the selection |
| Up/Down, K/J    | Move the selection              |
| Q               | Quit the selected app           |
| W               | Close the selected window       |
| , (Cmd+,)       | Open the Settings window        |
| Esc             | Cancel                          |
| Release Cmd     | Switch to the selected item     |

Quit and Close keep the list open: the affected rows leave and the selection moves to a neighbor.

## Requirements

- macOS 26 (Tahoe)
- **Accessibility** permission (System Settings > Privacy & Security > Accessibility) - required for the global Cmd+Tab hook and for reading window state
- **Screen Recording** permission, optional but recommended - macOS gates the titles of windows in other Spaces behind it. Cyclist uses it only to read those titles; without it, other-Space rows show the last title Cyclist saw

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

On first launch Cyclist prompts for Accessibility permission and activates itself once granted. It lives in the menu bar (no Dock icon); the menu holds Settings, About, and Quit - quitting is how every hook releases and the native shortcuts return. The Settings window holds the list options, trackpad swipe navigation, and a native Launch at Login toggle (registers with System Settings > General > Login Items).

## Configuration

Every setting lives in standard user defaults under the `io.github.pszypowicz.Cyclist` domain - the Settings window and `defaults write` are the same mechanism, and external writes apply to a running Cyclist immediately:

```sh
defaults write io.github.pszypowicz.Cyclist aerospaceIntegration -bool true
defaults write io.github.pszypowicz.Cyclist switcherShortcut "alt+tab"
```

| Key                       | Type   | Default        |
| ------------------------- | ------ | -------------- |
| `includeHidden`           | bool   | `true`         |
| `includeMinimized`        | bool   | `true`         |
| `includeOtherSpaces`      | bool   | `true`         |
| `includeNoWindows`        | bool   | `false`        |
| `trackpadSwipe`           | bool   | `true`         |
| `keyboardSpaceNavigation` | bool   | `true`         |
| `aerospaceIntegration`    | bool   | `false`        |
| `showHollowWorkspaces`    | bool   | `false`        |
| `switcherShortcut`        | string | `cmd+tab`      |
| `cycleWindowsShortcut`    | string | `cmd+backtick` |
| `previousSpaceShortcut`   | string | `ctrl+left`    |
| `nextSpaceShortcut`       | string | `ctrl+right`   |

Shortcut strings are modifiers and a key joined with `+`: `cmd`, `alt`, `ctrl`, `shift` plus a key name (`tab`, `backtick`, `left`, `right`, `up`, `down`, `space`, `return`, a letter, a digit, ...). A binding needs at least one non-shift modifier (shift is the reverse key); a string that fails these rules is a hard error - Cyclist quits rather than silently reverting to a default, whether the bad write happens before launch or while it runs.

## Known limitations

- Cyclist consumes the Previous/Next Space shortcuts (Ctrl+Left/Right by default) for chain navigation; disable the equivalent Mission Control shortcuts if you do not want both meanings, or turn off "Keyboard Space navigation" in Settings. Quitting Cyclist brings the native behavior back.
- Cyclist also consumes the trackpad Spaces-swipe gesture while "Trackpad swipe navigation" is on; flip the Settings toggle to get the native animated swipe back without quitting. One swipe is one step - a long swipe does not scrub across several Spaces.
- While a password field has secure input enabled, macOS withholds keystrokes from event taps, so Cmd+Tab temporarily falls through to the native switcher.
- Same-app window rows for other Spaces rely on the window-server list; their titles need Screen Recording permission or a previous sighting of the window (same rule as the app switcher's other-Space rows).
- The AeroSpace bridge speaks the server's socket protocol (version 1) and tracks the workspaces of AeroSpace's focused monitor. With several native desktops the ring only expands the current one.
- The list is keyboard-only; the panel ignores mouse clicks.
- Recording a shortcut captures through the same event tap the shortcuts use, so it needs the Accessibility grant.

## Acknowledgements

Cyclist relies on techniques that other projects worked out first:

- **Near-instant cross-Space jumps** (Ctrl+Left/Right and jumping to another Space's window) post the synthetic Dock-swipe gesture encoding from [Space Rabbit](https://github.com/Tahul/space-rabbit) - the same approach seen in InstantSpaceSwitcher and Spaceman. macOS performs no Space transition for a plain app activation, so the switch is driven by posting the gesture a trackpad would.
- **Window and focus detection** follows [AltTab](https://github.com/lwouis/alt-tab-macos) and [yabai](https://github.com/koekeishiya/yabai): reading focus changes, Space membership, and real-window state from the WindowServer's own notification stream and window records instead of the Accessibility API, and the tag/attribute predicate that filters out a fullscreen Space's companion windows.
- **The AeroSpace bridge** talks directly to [AeroSpace](https://github.com/nikitabobko/AeroSpace)'s socket.
