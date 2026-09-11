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

Daily totals in the right-click menu show time as `H:MM:SS`; the pill stays uncluttered. While tracking, it uses a white fill and a red dot; the dot turns green when the daily target is reached. When stopped, the pill is transparent and uses native menu-bar rendering, so it stays crisp on the active display and dims with neighboring items on inactive displays; green indicates that the daily target is complete. The native right-click menu and management window automatically follow the system light/dark setting. Daily totals use the local focus day and reset at 6:00 AM.

Daily targets use a simple `H:MM` format (for example, `1:17`) and reset along with each day's totals at 6:00 AM. Manual elapsed-time overrides accept either `H:MM` or `H:MM:SS`. Focus tracking pauses while your Mac sleeps and resumes on wake; the next wake also performs the 6:00 AM local-time rollover before any new time is counted.

Each focus area shows its last seven completion days and current streak. FocusBar sends a native macOS notification the first time an area reaches its daily target. Data is stored locally in macOS `UserDefaults` under `com.local.focusbar`.
