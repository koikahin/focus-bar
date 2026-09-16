# FocusBar resolved requirements

This document is the source of truth for the product behavior agreed during the original design and implementation conversation. Later decisions listed here supersede earlier ideas.

## Product purpose

FocusBar is a native macOS menu-bar app for tracking focused time against a small set of daily focus areas such as `work` or `pd`.

- Only one focus area is selected in the menu-bar pill at a time.
- At most one timer may run at a time.
- The pill must stay compact and must not display elapsed time.
- All state is local to the Mac. No account or network service is required.

## Menu-bar pill

### Interaction

- A left click starts the selected area's timer when stopped and stops the active timer when running.
- A right click opens the status menu.
- Choosing an area from the status menu selects it and stops any running timer. Selection must never automatically start tracking; starting is always a separate, deliberate action.

### Visual states

- While tracking, use a white filled pill with dark, readable text.
- While tracking below the daily target, show a red recording dot.
- While tracking at or above the daily target, show a green recording dot.
- While stopped, use a transparent pill with an outline so it is less prominent.
- While stopped below the daily target, use the normal native menu-bar outline and text treatment.
- While stopped at or above the daily target, use a green outline. Do not add a tick to the pill.
- Idle text and sizing must use native template-based menu-bar rendering so the label is centered from its actual visible content and dims like neighboring menu-bar items on an inactive display.
- The completed idle treatment may add the green outline separately, but the label must retain the native template behavior.
- The appearance must remain readable in both macOS light and dark modes.

## Right-click status menu

- Show a `Today · resets at 6:00 AM` heading.
- Show every focus area with today's elapsed time and daily target.
- Elapsed values use `H:MM:SS` and update once per second while the menu is open.
- Daily targets are shown as `H:MM`.
- Identify the active timer and completed areas with native menu affordances.
- Include commands to open **Manage Focus Areas…** and quit FocusBar.
- Use the native menu appearance so text remains readable in both light and dark modes.
- Edits made in the management window must immediately synchronize with this menu and the menu-bar pill.

## Focus-area management window

- The management UI is a proper macOS window and appears in Cmd+Tab while open.
- When no inline time edit is active, Escape closes the window.
- Present all controls within each focus area's row; do not use a separate selected-area header/control panel.
- Each row supports:
  - editing the focus-area name;
  - editing its daily target;
  - starting or stopping its timer;
  - viewing and editing today's elapsed time;
  - resetting today's elapsed time;
  - viewing the current streak and recent daily history;
  - removing the focus area after confirmation.
- Support adding new focus areas with an arbitrary daily target.

### Daily target editing

- Targets are daily targets, not lifetime or session targets.
- Accept arbitrary `H:MM` values; target configuration does not require or accept seconds.
- A valid target edit must immediately update completion state, pill styling, the status menu, and today's history state.

### Today's elapsed-time editing

- The displayed time next to **Today** becomes an inline field when clicked.
- Enter, Escape, clicking elsewhere, or losing focus all save the field's current valid value.
- If the value is invalid, retain the previous elapsed time.
- A **Reset** button appears only while the time is being edited.
- Accept `H:MM` as hours and minutes and `H:MM:SS` as hours, minutes, and seconds.
- Beginning an edit pauses whichever timer is running, even if it belongs to another area.
- Finishing the edit resumes that same timer if one was previously running; otherwise tracking remains stopped.
- The opening click must not be mistaken for an outside click or immediately close the editor.

## Daily boundaries and history

- A focus day runs from 6:00 AM local time through 5:59:59 AM the following local day.
- At rollover, archive the elapsed time and target that applied to the completed focus day, then reset current totals.
- Rollover must be evaluated from wall-clock time and work correctly when the Mac was asleep at 6:00 AM and wakes at any later time.
- Show the ten most recent focus days for each area.
- Keep the weekday and calendar date together above the day's status mark.
- Show that day's recorded `H:MM` beneath the status mark.
- Use a green tick when the elapsed time met that day's saved target.
- Use a yellow tick when elapsed time was more than one minute but below that day's saved target.
- Use no colored tick when elapsed time was one minute or less.
- Historical status is evaluated against the target saved for that day, never the area's currently configured target.
- Show a completion streak derived from consecutive completed focus days.

## Sleep, lock, and notifications

- Locking the Mac or putting it to sleep stops any active timer at the interruption time.
- The stopped timer must not resume automatically after wake or unlock.
- After the Mac is usable again, show one transient native notification explaining which timer was stopped. Overlapping lock and sleep events must not produce duplicate notifications.
- Wake and unlock must process any pending 6:00 AM rollover before further tracking.
- When an area first reaches its daily target, show a transient native macOS notification.
- Send the target-complete notification at most once per area per focus day.
- Foreground notifications should be presented as banners with sound, subject to the user's macOS notification settings.

## Persistence

- Persist focus areas, targets, selection, current totals, active-session state, completion history, per-day elapsed history, and per-day target history in macOS `UserDefaults`.
- Use the application domain/bundle identifier `com.local.focusbar`.
- Removing an area also removes its associated totals and history.

## Packaging and operation

- Support macOS 14 or later.
- Build as an installable native `FocusBar.app`.
- `zsh scripts/install-app.sh` must build the release app, stop an existing running copy before replacement, install it to `~/Applications/FocusBar.app`, and launch exactly one new copy.
- The app normally behaves as a menu-bar accessory without a Dock icon. It temporarily becomes a regular app while the management window is open so that window participates in Cmd+Tab.

## Verification expectations

- Run `swift run FocusBar --self-test` after behavioral changes.
- Preserve tests for selection-versus-start behavior, elapsed overrides, pause/resume around editing, 6:00 AM rollover after sleep, interruption-notification deduplication, historical daily targets, completion events, removal, and pill spacing/template rendering.
- For requested releases, build, stop the current installed run, reinstall, relaunch, and verify only one FocusBar instance is running.

