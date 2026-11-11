# EdgeStash

A small, independent macOS menu bar utility for keeping windows at a screen edge. No account, payment, license check, network connection, or third-party runtime.

## Build and run

Requires macOS 13+ and Apple's Swift tools (Xcode Command Line Tools).

```sh
swift run EdgeStashChecks
sh scripts/check-settings.sh
sh scripts/check-runtime.sh
sh scripts/build-app.sh
open dist/EdgeStash.app
```

Move `dist/EdgeStash.app` to Applications if desired **before** granting Accessibility access. Open the menu bar icon → Enable Accessibility, then enable **EdgeStash** in System Settings → Privacy & Security → Accessibility. Return to your working window. A rebuilt/ad-hoc signed app can need removal and re-adding in Accessibility settings.

The build script creates an ad-hoc signed app for the current Mac's architecture. It is not notarized or an App Store distribution.

If macOS shows access enabled after an update but stashing still fails, quit EdgeStash normally, remove its old entry with the minus/Remove button in the privacy pane, then use Add to select this exact `dist/EdgeStash.app` and enable it before relaunching. Merely toggling the stale entry may leave its old signing requirement in place. On newer macOS versions, this pane may be named **Device Control and Data Access**.

## Use

| Shortcut | Action |
| --- | --- |
| Control–Option–Command–← / → / ↑ / ↓ | Stash focused window on that edge; repeat on the same window to restore |
| Control–Option–Command–U | Restore the focused stashed window |
| Control–Option–Command–Shift–U | Restore every stashed window |
| Control–Option–Command–J | Cycle the most recently revealed app stack |

Open **Settings…** from the menu bar (or reopen the app) to edit Stash, Shortcuts, and Appearance. Every shortcut can be recorded, cleared, or reset; duplicate and bare-key combinations are rejected. Shortcuts are suspended while EdgeStash settings or its color picker is active.

Hover or click an app indicator to reveal, focus, and raise its window above other normal app windows. Reveals sit flush against their stash edge, using the space freed by the hidden indicator and preserving the last visible perpendicular position where it fits. The app's indicator disappears while a window in that app's stack is open and returns after it hides; its slot remains reserved so other notes stay still. In cursor-leaves mode, moving outside the revealed window hides it after the configured delay. Hovering another stash indicator keeps open windows stable, including while that indicator opens its window. Moving into ordinary desktop content resumes normal dismissal. In **Only when I press Escape** mode, pointer/focus changes leave it open and re-raise it above ordinary app windows without activating it. Plain Escape dismisses the most recently revealed stash even after another app receives focus. Settings retains its normal Escape behavior. App/system floating panels can remain above a raised window under macOS window-ordering rules. Escape never invokes Close or Quit. A **Hide … to Stash** menu command provides a mouse-accessible alternative.

Dragging or otherwise moving a revealed window automatically unstashes it, leaving it exactly where you moved it. Resizing keeps it stashed and remembers the new dimensions, including resizes from the top or left. Permanent **Unstash** uses its pre-stash position and latest size. Small movement tolerances ignore Accessibility rounding, and programmatic animation frames are excluded from move detection.

**Stack windows from the same app** groups windows by app, edge, display, and desktop. The indicator shows an app icon and window count; clicking cycles that app's windows. Control–Option–Command–J cycles the most recently revealed app stack. With stacking enabled, only one window in each app stack is revealed at a time; opening another app no longer replaces the first app’s window. Indicators and reveal actions stay on their originating desktop/Space. A separate transparent desktop marker retains membership even while indicators are hidden; returning to the Space repairs the indicators after Mission Control settles. They do not follow you to another Space.

Appearance provides a live preview, indicator thickness (0–48 points), height (24–320 points, default **48**), inward corner radius (0–24 points), gap (0–48 points), **Show app icon**, app icon size (16–64 points), **Liquid Glass indicators**, **Use app brand color**, a default color, and per-app color overrides. The icon sits inside a compact sticky note and shrinks to fit the chosen height. Only the two inward corners are rounded; the outside of the bar sits square against the display edge. Liquid Glass is untinted and uses the native macOS 26+ material, with a frosted-glass fallback on macOS 13–15. At thickness 0 the bar disappears, leaving only the icon; with icons hidden, an invisible 1-point edge target retains hover access. Color settings are retained and reappear when glass mode is turned off. Brand color is estimated from the dominant saturated color in the app's icon; neutral icons use the default. A per-app override takes priority over either automatic choice.

Drag a sticky note anywhere within its display and release to snap it to the nearest available outside edge. Near its attached edge, the note attracts to the center or either end. Shared/blocked monitor edges are excluded. Dragged positions are saved per app, edge, and display; **Reset Positions** restores the centered arrangement. Notes pack without overlaps at the configured height and gap, shrinking only if the full group cannot fit. Top/bottom edges apply height along the horizontal axis. Opening a stash reserves its slot until it closes. Hover must leave a note's activation region before it can rearm, and waits for unfinished slides; clicking still cycles within an app stack. Slide animation, duration, and reveal/hide delays remain adjustable; animation respects Reduce Motion.

Mouse movement drives coalesced hover checks. When idle with no stashes, window-monitoring timers, mouse monitors, focus observers, and Escape interception are removed. Hidden-only maintenance runs at 0.5-second intervals; revealed geometry is checked at most every 0.12 seconds and reused for pointer dismissal. Process-liveness checks run once every two seconds instead of on every pointer tick. Before sleep, animations settle and revealed stashes hide; on wake, shortcut/event-tap registration and desktop indicators reconcile after displays settle. Entries on disconnected displays restore onto a connected display.

Stashing preserves each window's pre-stash position and remembers observed size changes. Where an app/macOS clamps offscreen placement (commonly top/bottom/Dock edges), EdgeStash falls back to minimizing that individual window and keeps its edge tab. It never hides an entire app. An edge is rejected if it joins another monitor or its hidden window would overlap another display across a gap. Tabs sit inside the usable display area so the menu bar and Dock do not cover them. Windows in native full screen are rejected.

Quit normally to restore every managed window. Changing the monitor arrangement also restores windows to a connected display. A failed restore keeps its entry and prevents normal quit so the restore action remains available. Errors appear in the menu and play the system error sound.

## Recovery and privacy

Before moving a window, EdgeStash atomically records its process ID, process launch time, title, and original frame in `~/Library/Application Support/EdgeStash/recovery.json` (owner-only file permissions). The recorded restore size is updated after resizing a revealed window. Window titles stay on this Mac. No window contents are captured and no Screen Recording permission is requested. Escape mode installs a keyboard event tap to handle only plain Escape while a stash is revealed; keyboard text is not recorded. Pointer monitors inspect event type and pointer position only and are removed while no windows are stashed. macOS must allow the event tap; a permission failure is shown in the menu, and the menu’s Hide … to Stash and Restore commands remain available.

On the next launch with Accessibility access, EdgeStash attempts to restore journaled windows. A process must have the same launch time and a unique matching window title; it does not guess between duplicate titles. Changed titles, duplicate titles, inaccessible windows, and windows in other Spaces may require manual recovery: unminimize using the Dock or the app's Window menu, then move the window using macOS or another window manager. Original geometry stays in the journal for unresolved records. Force-quitting bypasses orderly restoration.

## Scope and verification

The implementation uses public Accessibility APIs, AppKit, Core Graphics event taps, and Carbon's global hotkey API. Settings are stored locally in UserDefaults (`EdgeStash.preferences.v1`). It is independently written; evidence describing Rectangle Pro is in `docs/rectangle-stash.md` when present.

Geometry and preferences self-checks cover four-edge reveal anchoring, animation interpolation, multiple-monitor coordinates, shared-edge rejection, tab placement, restoration bounds, saved settings and shortcut conflicts. A native settings smoke check constructs and resizes the actual window to catch runtime layout exceptions and collapsed content. The release build verifies compilation and bundle signing. Cross-application Accessibility behavior must be checked interactively; automated tests do not establish that all apps accept window moves.

Intentionally omitted: drag-to-stash, app-focus auto-reveal, bulk stash commands, and automatic launch at login. See `docs/verification.md` for tested behavior and remaining runtime checks.

When updating a running copy, quit EdgeStash normally to restore its windows, then reopen the rebuilt app. Do not force quit while windows are stashed. A new ad-hoc signature may require re-adding Accessibility access.
