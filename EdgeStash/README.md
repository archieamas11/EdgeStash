# EdgeStash

A small, independent macOS menu bar utility for keeping windows at a screen edge. No account, payment, license check, network connection, or third-party runtime.

## Build and run

Requires macOS 13+ and Apple's Swift tools (Xcode Command Line Tools).

```sh
swift run EdgeStashChecks
sh scripts/check-settings.sh
sh scripts/build-app.sh
open dist/EdgeStash.app
```

Move `dist/EdgeStash.app` to Applications if desired **before** granting Accessibility access. Open the menu bar icon → Enable Accessibility, then enable **EdgeStash** in System Settings → Privacy & Security → Accessibility. Return to your working window. A rebuilt/ad-hoc signed app can need removal and re-adding in Accessibility settings.

The build script creates an ad-hoc signed app for the current Mac's architecture. It is not notarized or an App Store distribution.

## Use

| Shortcut | Action |
| --- | --- |
| Control–Option–Command–← / → / ↑ / ↓ | Stash focused window on that edge; repeat on the same window to restore |
| Control–Option–Command–U | Restore the focused stashed window |
| Control–Option–Command–Shift–U | Restore every stashed window |
| Control–Option–Command–J | Cycle the most recently revealed app stack |

Open **Settings…** from the menu bar (or reopen the app) to edit Stash, Shortcuts, and Appearance. Every shortcut can be recorded, cleared, or reset; duplicate and bare-key combinations are rejected. Shortcuts are suspended while EdgeStash settings or its color picker is active.

Hover an app indicator to reveal a window. Reveals sit beside their stash edge, preserving the original perpendicular position where it fits. **Unstash** restores the pre-stash position and size separately. By default, moving outside the window and indicator hides it after the configured delay. In **Only when I press Escape** mode, it remains open when the pointer or focus leaves. Escape is consumed only when a revealed stashed window is focused; it hides the stash and never invokes Close or Quit. Clicking a single-window indicator toggles reveal/hide. Right-click an indicator for individual reveal and unstash actions.

**Stack windows from the same app** groups windows by app, edge, display, and desktop. The indicator shows an app icon and window count; clicking cycles that app's windows. Control–Option–Command–J cycles the most recently revealed app stack. With stacking enabled, only one window per edge/display is revealed at a time. Indicators and reveal actions stay on their originating desktop/Space. They do not follow you to another Space.

Appearance provides a live preview, indicator thickness (16–48 points), length (48–160 points), a default color, and per-app color overrides. Tabs use the usable screen area and sit near the original stash position. Slide animation, duration, and reveal/hide delays are adjustable; animation respects Reduce Motion. macOS restrictions can force native minimization rather than a full offscreen slide.

Stashing preserves each window's original position and size. Where an app/macOS clamps offscreen placement (commonly top/bottom/Dock edges), EdgeStash falls back to minimizing that individual window and keeps its edge tab. It never hides an entire app. An edge is rejected if it joins another monitor or its hidden window would overlap another display across a gap. Tabs sit inside the usable display area so the menu bar and Dock do not cover them. Windows in native full screen are rejected.

Quit normally to restore every managed window. Changing the monitor arrangement also restores windows to a connected display. A failed restore keeps its entry and prevents normal quit so the restore action remains available. Errors appear in the menu and play the system error sound.

## Recovery and privacy

Before moving a window, EdgeStash atomically records its process ID, process launch time, title, and original frame in `~/Library/Application Support/EdgeStash/recovery.json` (owner-only file permissions). Window titles stay on this Mac. No window contents are captured and no Screen Recording permission is requested. Escape mode installs a keyboard event tap to handle only plain Escape for the focused revealed stash; keyboard text is not recorded. macOS must allow the event tap; a permission failure is shown in the menu, and clickable hide actions remain available.

On the next launch with Accessibility access, EdgeStash attempts to restore journaled windows. A process must have the same launch time and a unique matching window title; it does not guess between duplicate titles. Changed titles, duplicate titles, inaccessible windows, and windows in other Spaces may require manual recovery: unminimize using the Dock or the app's Window menu, then move the window using macOS or another window manager. Original geometry stays in the journal for unresolved records. Force-quitting bypasses orderly restoration.

## Scope and verification

The implementation uses public Accessibility APIs, AppKit, Core Graphics event taps, and Carbon's global hotkey API. Settings are stored locally in UserDefaults (`EdgeStash.preferences.v1`). It is independently written; evidence describing Rectangle Pro is in `docs/rectangle-stash.md` when present.

Geometry and preferences self-checks cover four-edge reveal anchoring, animation interpolation, multiple-monitor coordinates, shared-edge rejection, tab placement, restoration bounds, saved settings and shortcut conflicts. A native settings smoke check constructs and resizes the actual window to catch runtime layout exceptions and collapsed content. The release build verifies compilation and bundle signing. Cross-application Accessibility behavior must be checked interactively; automated tests do not establish that all apps accept window moves.

Intentionally omitted: drag-to-stash, app-focus auto-reveal, bulk stash commands, and automatic launch at login. See `docs/verification.md` for tested behavior and remaining runtime checks.

When updating a running copy, quit EdgeStash normally to restore its windows, then reopen the rebuilt app. Do not force quit while windows are stashed. A new ad-hoc signature may require re-adding Accessibility access.
