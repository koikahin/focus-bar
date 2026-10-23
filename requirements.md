# FocusBar requirements

This document is the source of truth for FocusBar product behavior.

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
- Use an 11-point semibold font for pill labels in all states, with a 9-point recording dot, to keep the pill compact and readable.
- While stopped below today's target, append a streak count separated by a space, without parentheses, such as `pd 3`. Use the daily-target streak if nonzero; otherwise show a nonzero 30-minute streak with an asterisk, such as `pd 3*`. Show `pd 0` without an asterisk when both are zero. The hover text explains both streak counts. Tracking pills and stopped pills that have completed today's target keep the plain area name.
- While stopped at or above the daily target, use a green outline. Do not add a tick to the pill.
- Idle text and sizing must use native template-based menu-bar rendering so the label is centered from its actual visible content and dims like neighboring menu-bar items on an inactive display.
- The completed idle treatment may add the green outline separately, but the label must retain the native template behavior.
- The appearance must remain readable in both macOS light and dark modes.
- Hovering over the pill shows the selected area's tracking/completion state and both its daily-target and 30-minute streaks. Refresh the hover text when either streak changes without redrawing an otherwise unchanged pill.
- Present the hover details in a native, nonactivating tooltip-style panel after a brief hover, using tracking that remains active while FocusBar is in the background. Dismiss it on pointer exit, pill clicks, system interruption, and quit. Hover must never start tracking, open the management window, or activate FocusBar.

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
- Clicking **Reset** immediately sets today's elapsed time to zero and finishes editing; an outside-click or blur save must not intercept the reset.
- Accept `H`, `H:MM`, and `H:MM:SS` without requiring two-digit components. Omitted components, including empty colon-separated components or an empty field, default to zero. For example, `0` means `0:00:00`, `1` means `1:00:00`, and `1:1` means `1:01:00`.
- Reject nonnumeric values, negative values, extra components, and minutes or seconds outside 0–59; retain the previous elapsed time for invalid input.
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
- Directly below the daily-target streak, show a separate `x-day (30 min) streak` for consecutive focus days with at least 30 minutes recorded in that area, independently of its daily target. Use exactly the same streak behavior: count today once its threshold is met; until then, show the streak ending yesterday. A past day below the threshold or without recorded time breaks the streak. Derive it from the full saved elapsed history, not just the ten displayed days, and update it immediately after time edits, resets, and while tracking is visible.

## Sleep, lock, and notifications

- Locking the Mac or putting it to sleep stops any active timer at the interruption time.
- The stopped timer must not resume automatically after wake or unlock.
- After the Mac is usable again, show one transient native notification explaining which timer was stopped. Overlapping lock and sleep events must not produce duplicate notifications.
- Wake and unlock must process any pending 6:00 AM rollover before further tracking.
- When an area first reaches its daily target, show a transient native macOS notification.
- Send the target-complete notification at most once per area per focus day.
- Include both streaks for the area that reached its target in the target-complete notification. For rollover or delayed completion notices, calculate the streaks through the completed focus day using its archived elapsed total.
- Foreground notifications should be presented as banners with sound, subject to the user's macOS notification settings.
- Keep target-completion and stopped-timer requests queued while notification authorization is pending. Permission denial, authorization errors, and delivery errors must be logged and immediately surfaced in a native error dialog with an explanation; never silently discard them. Successful notifications use normal system priority, without an app modal or an urgent interruption.

## Persistence

- Persist focus areas, targets, selection, current totals, active-session state, completion history, per-day elapsed history, and per-day target history in macOS `UserDefaults`.
- Use the application domain/bundle identifier `com.local.focusbar`.
- Missing saved data on first launch creates the default areas. Unreadable saved data or a snapshot encoding failure must show a native error and quit without overwriting the existing preferences; never silently fall back to defaults or skip a failed save.
- Removing an area also removes its associated totals and history.
- Every removal entry point, including a row's trash button and list deletion, must show an explicit confirmation with Cancel before removing the area or its history.
- Immediately before a 6:00 AM focus-day rollover (including a delayed rollover on wake or launch), write an independent JSON backup of the complete saved state to `~/Library/Application Support/FocusBar/Backups`.
- Keep the two most recent completed focus-day versions, identified by their focus-day keys. Write the new backup atomically before pruning older versions. Repeated rollover checks must not create extra versions.
- Backups must include areas, daily targets, totals, selection, and all saved histories and must survive deletion of the primary preferences file. A backup uses the same snapshot format as the primary data, with its completed-day timer stopped.
- If writing or rotating backups fails, stop tracking, preserve the existing data, postpone rollover and further edits, and show a native error with Retry and Later. Retry may complete rollover only once backup succeeds.

## Packaging and operation

- Support macOS 14 or later.
- Build as an installable native `FocusBar.app`.
- Sign and verify the complete app bundle, including its Info.plist, with the `com.local.focusbar` identity and a stable local designated requirement on every build so macOS can authorize system notifications.
- `zsh scripts/install-app.sh` must build the release app, stop an existing running copy before replacement, install it to `~/Applications/FocusBar.app`, and launch exactly one new copy.
- The app normally behaves as a menu-bar accessory without a Dock icon. It temporarily becomes a regular app while the management window is open so that window participates in Cmd+Tab.

## Scheduling and performance

- Derive elapsed time from saved totals and session timestamps; do not increment a per-second counter.
- Schedule a one-shot wake-up for the next daily-target completion, 30-minute streak threshold, or local 6:00 AM rollover. Recalculate it after tracking, target, elapsed-time, or system-clock changes. The 30-minute wake-up refreshes streak information without a separate notification or per-second polling.
- Use per-second refreshes only for visible seconds displays while tracking runs.
- Keep visual-state calculation separate from AppKit rendering; redraw the pill only when its title, tracking state, or completion state changes.
- Render the tracking pill as a single image, without a text-field subview or custom layer backing that can trigger repeated menu-bar snapshot redraws.
- Persist notification delivery history independently of completion status so edits and resets cannot repeat a daily-target notification.

## Verification expectations

- Run `swift run FocusBar --self-test` after behavioral changes.
- Preserve tests for selection-versus-start behavior, elapsed overrides, pause/resume around editing, 6:00 AM rollover after sleep, interruption-notification deduplication, historical daily targets, completion events, removal, and pill spacing/template rendering.
- Cover authorization queueing, permission and delivery failures, and saved-data decoding/encoding failures. A signed app's `--test-notification` mode must exercise a real target deadline in an isolated test profile and verify delivery through macOS without changing the user's focus data.
- Test actual hover event delivery and visible native hover details, including background-app tracking, pointer exit, quick-pass cancellation, action dismissal, and preservation of app activation and keyboard focus; checking a tooltip text property alone is insufficient.
- For requested releases, build, stop the current installed run, reinstall, relaunch, and verify only one FocusBar instance is running.
