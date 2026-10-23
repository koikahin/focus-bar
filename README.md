# FocusBar

A native macOS menu-bar timer for a small set of daily focus areas.

## Install and launch

```sh
zsh scripts/install-app.sh
```

This builds a native `FocusBar.app`, gracefully stops an older running copy, installs it in `~/Applications`, and launches it. Move that app to `/Applications` later if you want it available to every macOS account.

## Development-only run

```sh
swift run FocusBar
```

The app lives in the menu bar and has no Dock icon. A left click starts or stops the selected area. The pill is outlined and transparent while idle, then filled while tracking. A right click shows today's totals and lets you switch areas; switching always stops any active timer, so starting remains deliberate.

Use **Manage Focus Areas…** to add or remove areas, edit daily targets, and start or stop any area's timer directly in its row. Click the time beside **Today** to edit it inline; Reset appears only while editing. Return, Escape, or moving focus elsewhere saves the value, and whichever timer was running before the edit resumes afterward. The options window behaves like a regular macOS window while open, including Cmd+Tab support; Escape closes it when no time edit is active.

Daily totals in the right-click menu show time as `H:MM:SS` and update every second while the menu is open; the pill stays uncluttered. While tracking, it uses a white fill and a red dot; the dot turns green when the daily target is reached. When stopped, the pill is transparent and uses native menu-bar text rendering, so it stays crisp on the active display and dims with neighboring items on inactive displays; a green outline indicates that the daily target is complete. The native right-click menu and management window automatically follow the system light/dark setting. Daily totals use the local focus day and reset at 6:00 AM.

Daily targets use a simple `H:MM` format (for example, `1:17`) and reset along with each day's totals at 6:00 AM. Manual elapsed-time overrides accept `H`, `H:MM`, or `H:MM:SS`; omitted components default to zero, so `0` clears today's time and `1:1` means one hour and one minute. Reset clears the time and finishes editing. Removing an area, whether using its trash button or list deletion, requires confirmation. Locking the Mac or putting it to sleep stops an active timer; it stays stopped after wake or unlock, and FocusBar shows a notification explaining that it was stopped. Wake and unlock also perform any pending 6:00 AM local-time rollover before new tracking can begin.

Each focus area shows its last ten 6:00 AM–bounded days, with the weekday and date together, a status mark below them, and that day's recorded `H:MM` beneath the mark. A green tick means that day's saved target was reached; a yellow tick means more than one minute was recorded without reaching that day's target. Target changes do not recolor earlier days. FocusBar sends a native macOS notification the first time an area reaches its daily target. Data is stored locally in macOS `UserDefaults` under `com.local.focusbar`.

Elapsed time is derived from session timestamps. A one-shot timer handles the next target completion, 30-minute streak threshold, or 6:00 AM rollover, and target/time edits reschedule it. Per-second updates run only while a seconds display is visible and tracking is active. The pill is rendered only when its visible state changes; notification history is persisted separately so changing a target or resetting time does not repeat that day's notification.

Each area shows its daily-target streak with a separate `x-day (30 min) streak` directly below it. The second streak counts days with at least 30 minutes, regardless of the daily target. Both use the same 6:00 AM focus days and include today once their threshold is reached; until then, yesterday's streak remains visible.

Hover over the pill to see both streaks for its selected area in a native tooltip-style panel, even while FocusBar is in the background. It appears after a brief hover and closes on pointer exit or a pill click, without activating the app. Target-complete notifications include both streaks too. While stopped and below today's target, the pill shows a count such as `pd 3`: the daily-target streak takes precedence. If that streak is zero, a nonzero 30-minute streak appears as `pd 3*`. If both are zero, it shows `pd 0` without an asterisk. Pill labels use a compact, readable 11-point semibold font. Tracking and completed-today pills keep the plain name.

The hover header also shows today's elapsed time beside `Stopped` or `Tracking`, for example `work · Tracking · Today 1:23:45`. This value is captured when the panel opens and stays fixed until the next hover, with no additional live timer.

## Verification

Before each daily reset, FocusBar writes a separate JSON copy of all tracking data to `~/Library/Application Support/FocusBar/Backups`. It retains the two most recent completed focus-day versions, including their earlier history. These files survive deletion of the main preferences file during development and use the same snapshot format for restoration. If a backup fails, tracking stops and the reset is postponed; a native alert offers Retry or Later.

Run `swift run FocusBar --self-test` for behavior checks. Run `swift run FocusBar --render-test` for a live CPU benchmark of all four pill states; it temporarily adds a `test` pill without changing your recorded focus data. The tracking pill uses a single image rather than a text-field subview to avoid an AppKit menu-bar snapshot redraw loop.

The packaged app is signed and verified so macOS can authorize its notifications. Completion notices use a normal system banner and sound, respecting your notification settings. Permission and delivery errors are logged and shown immediately in a native error dialog. Unreadable saved data or snapshot encoding errors show an error and quit while preserving existing preferences.

Run `~/Applications/FocusBar.app/Contents/MacOS/FocusBar --check-notifications` to check system permission and banner settings (a nonzero exit means banners are unavailable). Run the same app with `--test-notification` to reach a target after one second in an isolated **Notification Test** area and confirm delivery with both streaks through macOS; this leaves your real areas, timers, and history untouched.
