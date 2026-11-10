# Zones

Snap windows into a grid you draw, on each monitor. Nothing moves unless you move it.

## Install

1. Download [Zones.zip](https://github.com/joshuahuffman02/zones/releases/latest/download/Zones.zip), unzip it, and drag **Zones** to Applications.
2. Open it. The first time, macOS says it can't verify the developer, because the app isn't notarized. Go to System Settings → Privacy & Security, scroll down, and click **Open Anyway** next to Zones.
3. When asked, switch on **Zones** in System Settings → Privacy & Security → Accessibility. It starts working within a second.
4. Optional: choose **Open at Login** in the Zones menu (the grid icon in the menu bar).

After that, Zones updates itself. It checks every hour, downloads new versions in the background, and installs them once you've stepped away for 30 seconds. The relaunch takes about a second, and Accessibility stays on. **Check for Updates…** is in the menu if you want one right away.

Also turn off macOS's own edge snapping, which fights with Zones: System Settings → Desktop & Dock → Windows → "Drag windows to screen edges to tile".

## Using it

- **Snap:** hold ⇧ while dragging a window. Your zones appear; drop on one.
- **Span:** hold ⇧⌘ while dragging. The window covers every zone from where you pressed ⌘ to where you let go.
- **Resize neighbours:** drag the gap between two windows that sit side by side or one above the other. Both resize together. On a zone line, the line moves too, so later snaps match.
- **Monitors coming and going:** Zones remembers where your windows sit for each set of monitors. Plug the ultrawide back in and its windows return to where they were; unplug it and the laptop goes back to how you last had it on its own. Only windows that were there before move. Turn it off, or run it by hand, from the menu (**Put Windows Back…**).
- **Edit zones:** menu → your monitor → **Edit Zones…**, or ⌃⌥E with the mouse over that monitor.
  - Drag the lines between zones. They stick to halves, thirds and quarters; hold ⌥ to place them anywhere.
  - Hover a zone for **Split ↔︎**, **Split ↕︎** and **Remove**.
  - **Start from** has templates: 2–5 columns, grids, and a wide center.
  - Return saves, Esc cancels.

| Keys | Action |
|---|---|
| ⌃⌥ 1 – 9 | Put the focused window in that zone |
| ⌃⌥ ← / → | Next zone left / right, carrying on to the next monitor |
| ⌃⌥ ↑ / ↓ | Zone above / below |
| ⌃⌥ ↩ | Fill the monitor |
| ⌃⌥ E | Edit zones on the monitor under the mouse |

Ultrawide monitors (wider than 2.3:1) start with four columns, and others with two. Each monitor's layout is saved separately in `~/Library/Application Support/Zones/zones.json`.

## Development

```sh
./build.sh --run              # build build/Zones.app, sign it, launch it
swift test                    # zone geometry tests
./release.sh "What changed"   # publish an update; installed copies pick it up within the hour
```

- **`Sources/ZonesCore`:** zone geometry and editing, with no AppKit. Tested.
- **`Sources/Zones`:** the menu bar app.
  - `Snapper`: ⇧-drag snapping and the keyboard commands.
  - `GapHandles`: resize handles in the gaps between windows.
  - `Editor`: the zone editor.
  - `Arrangements`: remembers window spots per set of monitors and restores them.
  - `Updater`: Sparkle updates.
- **Signing:** builds are signed with an Apple Development certificate. The ID is saved in `.signing-identity`, which stays out of the repo. A stable signature keeps the Accessibility permission across updates.
- **Update signing key:** releases are also signed with an EdDSA key kept in the releasing Mac's keychain. Its public half is in `build.sh`.
