import AppKit
import Foundation
import SwiftUI
import UserNotifications

@MainActor
private final class SelfTestClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

@MainActor
enum FocusSelfTests {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run() -> Bool {
        do {
            try testResetClickRouting()
            try testElapsedInput()
            try testSelectionStopsTimer()
            try testOverrideRebasesTimer()
            try testElapsedEditPauseAndResume()
            try testSleepRollover()
            try testSystemInterruptionNotice()
            try testHabitDayStates()
            try testHistoricalDailyTarget()
            try testCompletionEvent()
            try testRemoval()
            try testPillSpacing()
            try testDeadlinePlanning()
            try testCompletionWithoutPolling()
            try testNotificationPersistence()
            try testPillVisualState()
            try testFocusDayBoundaries()
            try testAutomaticRescheduling()
            try testDailyBackups()
            try testBackupFailurePreservesDay()
            try testNotificationErrors()
            try testPersistenceErrors()
            try testThirtyMinuteStreak()
            try testPillStreakPresentation()
            try testThirtyMinuteRefreshWithoutPolling()
            try testCompletionNotificationStreaks()
            try testPillHoverPresentation()
            try testPillHoverElapsedSnapshot()
            print("FocusBar self-tests passed (28/28)")
            return true
        } catch {
            FileHandle.standardError.write(Data("FocusBar self-test failed: \(error)\n".utf8))
            return false
        }
    }

    private static func testElapsedInput() throws {
        try expect(ElapsedInput.seconds(from: "0") == 0, "a bare zero should reset today's time")
        try expect(ElapsedInput.seconds(from: "1") == 3_600, "a bare number should mean hours")
        try expect(ElapsedInput.seconds(from: "1:1") == 3_660, "missing seconds should default to zero")
        try expect(ElapsedInput.seconds(from: "1::5") == 3_605, "omitted minutes should default to zero")
        try expect(ElapsedInput.seconds(from: "") == 0, "all omitted components should default to zero")
        try expect(ElapsedInput.seconds(from: ":1:") == 60, "empty hours and seconds should default to zero")
        try expect(ElapsedInput.seconds(from: "0:0:0") == 0, "zero components should be valid")
        try expect(ElapsedInput.seconds(from: "2:15") == 8_100, "H:MM should mean hours and minutes")
        try expect(ElapsedInput.seconds(from: "2:15:30") == 8_130, "H:MM:SS should include seconds")
        try expect(ElapsedInput.seconds(from: "2:75") == nil, "invalid minutes should fail")
        try expect(ElapsedInput.seconds(from: "1:2:60") == nil, "invalid seconds should fail")
        try expect(ElapsedInput.seconds(from: "-1") == nil, "negative hours should fail")
        try expect(ElapsedInput.seconds(from: "abc") == nil, "non-numeric values should fail")
        try expect(ElapsedInput.seconds(from: "1:2:3:4") == nil, "extra components should fail")
        try expect(ElapsedInput.seconds(from: String(Int.max)) == nil, "unrepresentable durations should fail rather than overflow the display")
    }

    private static func testResetClickRouting() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let clock = SelfTestClock(localDate(year: 2026, month: 9, day: 9, hour: 10))
        let store = makeStore(clock: clock)
        let work = store.tasks[0]
        store.setElapsed(for: work, to: 600)
        store.start(taskID: work.id)
        let timerToResume = store.activeTaskID
        store.finishCurrentSession()
        var commits = 0
        var resets = 0
        let editor = CommitOnBlurTextField(text: .constant("1:23:45"), onCommit: { commits += 1 }, onReset: {
            resets += 1
            store.resetElapsed(for: work)
            if let timerToResume { store.start(taskID: timerToResume) }
        })
        let coordinator = editor.makeCoordinator()
        let view = coordinator.makeEditorView()
        view.frame = NSRect(x: 10, y: 10, width: 180, height: 24)
        window.contentView!.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let reset = coordinator.resetButton!
        let point = reset.convert(NSPoint(x: 20, y: 12), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        try expect(coordinator.handleMouseDown(event) == nil, "Reset should consume its click before the editor disappears")
        reset.performClick(nil)
        RunLoop.current.run(until: Date.now.addingTimeInterval(0.01))
        try expect(commits == 0, "clicking Reset must not commit and dismiss the editor before its action")
        try expect(resets == 1, "Reset must act exactly once even if a later action arrives")
        try expect(store.elapsed(for: work) == 0, "Reset must clear today's stored elapsed time")
        try expect(store.activeTaskID == timerToResume, "Reset must resume the timer paused for editing")

        let outsideCoordinator = editor.makeCoordinator()
        let outsideView = outsideCoordinator.makeEditorView()
        outsideView.frame = view.frame
        window.contentView!.addSubview(outsideView)
        outsideView.layoutSubtreeIfNeeded()
        let outsideEvent = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 230, y: 70), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        _ = outsideCoordinator.handleMouseDown(outsideEvent)
        RunLoop.current.run(until: Date.now.addingTimeInterval(0.01))
        try expect(commits == 1, "an ordinary outside click must still commit")

        let keyboardCoordinator = editor.makeCoordinator()
        let keyboardView = keyboardCoordinator.makeEditorView()
        keyboardCoordinator.resetButton!.performClick(nil)
        try expect(resets == 2, "keyboard/accessibility activation must also reset")
        withExtendedLifetime(keyboardView) {}
    }

    private static func testSelectionStopsTimer() throws {
        let clock = SelfTestClock(localDate(year: 2026, month: 9, day: 9, hour: 10))
        let store = makeStore(clock: clock)
        guard let work = store.tasks.first(where: { $0.name == "work" }),
              let pd = store.tasks.first(where: { $0.name == "pd" }) else { throw Failure(description: "default areas missing") }
        store.start(taskID: work.id)
        clock.now = clock.now.addingTimeInterval(90)
        store.select(taskID: pd.id)
        try expect(store.activeTaskID == nil, "switching must stop the timer")
        try expect(store.currentTaskID == pd.id, "switching must select the destination")
        try expect(abs(store.elapsed(for: work) - 90) < 0.001, "switching must checkpoint elapsed time")
    }

    private static func testOverrideRebasesTimer() throws {
        let clock = SelfTestClock(localDate(year: 2026, month: 9, day: 9, hour: 10))
        let store = makeStore(clock: clock)
        guard let work = store.tasks.first(where: { $0.name == "work" }) else { throw Failure(description: "work area missing") }
        store.start(taskID: work.id)
        clock.now = clock.now.addingTimeInterval(10)
        store.setElapsed(for: work, to: 3_600)
        clock.now = clock.now.addingTimeInterval(5)
        store.pulse()
        try expect(abs(store.elapsed(for: work) - 3_605) < 0.001, "override must rebase a running timer")
    }

    private static func testElapsedEditPauseAndResume() throws {
        let clock = SelfTestClock(localDate(year: 2026, month: 9, day: 9, hour: 10))
        let store = makeStore(clock: clock)
        guard let work = store.tasks.first(where: { $0.name == "work" }),
              let pd = store.tasks.first(where: { $0.name == "pd" }) else { throw Failure(description: "default areas missing") }
        store.start(taskID: work.id)
        clock.now = clock.now.addingTimeInterval(35)
        let timerToResume = store.activeTaskID
        store.finishCurrentSession()
        try expect(store.activeTaskID == nil, "editing today's time must pause the running timer")
        store.setElapsed(for: pd, to: 600)
        if let timerToResume { store.start(taskID: timerToResume) }
        try expect(store.activeTaskID == work.id, "the timer running before an edit must resume")
        clock.now = clock.now.addingTimeInterval(10)
        store.pulse()
        try expect(abs(store.elapsed(for: work) - 45) < 0.001, "the resumed timer must continue from its paused total")
        try expect(abs(store.elapsed(for: pd) - 600) < 0.001, "editing another area must save its new total")
    }

    private static func testSleepRollover() throws {
        let clock = SelfTestClock(localDate(year: 2026, month: 9, day: 9, hour: 5, minute: 50))
        let store = makeStore(clock: clock)
        guard let work = store.tasks.first(where: { $0.name == "work" }) else { throw Failure(description: "work area missing") }
        store.start(taskID: work.id)
        clock.now = localDate(year: 2026, month: 9, day: 9, hour: 5, minute: 55)
        let stoppedTask = store.stopForSystemInterruption()
        try expect(stoppedTask?.id == work.id, "sleep must report the timer it stopped")
        try expect(store.activeTaskID == nil, "sleep must stop the running timer")
        clock.now = localDate(year: 2026, month: 9, day: 10, hour: 9)
        store.refreshDayIfNeeded()
        try expect(store.activeTaskID == nil, "a timer stopped for sleep must stay stopped after wake")
        try expect(abs(store.elapsed(for: work)) < 0.001, "new focus day must begin at zero on wake")
        try expect(store.recentCompletions(for: work).contains(where: { abs($0.elapsedSeconds - 300) < 0.001 }), "wake rollover must preserve the prior focus day's total")
        clock.now = clock.now.addingTimeInterval(10)
        store.pulse()
        try expect(abs(store.elapsed(for: work)) < 0.001, "a stopped timer must not restart or count time after wake")
    }

    private static func testSystemInterruptionNotice() throws {
        var interruption = SystemInterruptionState()
        interruption.sessionResigned()
        interruption.recordStoppedTask("work")
        interruption.beganSleep()
        try expect(interruption.woke() == nil, "wake must wait for unlock before presenting the stopped-timer notice")
        try expect(interruption.sessionBecameActive() == "work", "unlock must release one stopped-timer notice")
        try expect(interruption.sessionBecameActive() == nil, "overlapping wake events must not duplicate the notice")

        var sleepOnly = SystemInterruptionState()
        sleepOnly.beganSleep()
        sleepOnly.recordStoppedTask("pd")
        try expect(sleepOnly.woke() == "pd", "wake without a locked session must release the notice")
    }

    private static func testHabitDayStates() throws {
        let clock = SelfTestClock(localDate(year: 2026, month: 9, day: 9, hour: 10))
        let store = makeStore(clock: clock)
        guard let work = store.tasks.first(where: { $0.name == "work" }) else { throw Failure(description: "work area missing") }
        store.update(work, name: work.name, targetSeconds: 600)
        guard let updatedWork = store.tasks.first(where: { $0.id == work.id }) else { throw Failure(description: "updated area missing") }
        store.setElapsed(for: updatedWork, to: 60)
        try expect(store.recentCompletions(for: updatedWork).count == 10, "the habit strip must show ten focus days")
        try expect(store.recentCompletions(for: updatedWork).last?.status == .some(.none), "exactly one minute must not receive a partial tick")
        store.setElapsed(for: updatedWork, to: 61)
        try expect(store.recentCompletions(for: updatedWork).last?.status == .partial, "more than one minute below target must receive a partial tick")
        store.setElapsed(for: updatedWork, to: 600)
        try expect(store.recentCompletions(for: updatedWork).last?.status == .complete, "meeting the daily target must receive a complete tick")
    }

    private static func testHistoricalDailyTarget() throws {
        let clock = SelfTestClock(localDate(year: 2026, month: 9, day: 9, hour: 10))
        let suiteName = "FocusBarSelfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = FocusStore(defaults: defaults, backups: nil, clock: { clock.now })
        guard let work = store.tasks.first(where: { $0.name == "work" }) else { throw Failure(description: "work area missing") }
        store.update(work, name: work.name, targetSeconds: 120)
        guard let updatedWork = store.tasks.first(where: { $0.id == work.id }) else { throw Failure(description: "updated area missing") }
        store.setElapsed(for: updatedWork, to: 90)
        clock.now = localDate(year: 2026, month: 9, day: 10, hour: 6, minute: 1)
        store.pulse()
        guard let currentWork = store.tasks.first(where: { $0.id == work.id }) else { throw Failure(description: "current area missing") }
        store.update(currentWork, name: currentWork.name, targetSeconds: 60)
        let reloadedStore = FocusStore(defaults: defaults, backups: nil, clock: { clock.now })
        guard let reloadedWork = reloadedStore.tasks.first(where: { $0.id == work.id }),
              let historicalDay = reloadedStore.recentCompletions(for: reloadedWork).first(where: { abs($0.elapsedSeconds - 90) < 0.001 }) else {
            throw Failure(description: "historical day missing")
        }
        try expect(abs(historicalDay.targetSeconds - 120) < 0.001, "rollover must preserve that day's configured target")
        try expect(historicalDay.status == .partial, "later target changes must not recolor a historical day")
    }

    private static func testCompletionEvent() throws {
        let clock = SelfTestClock(localDate(year: 2026, month: 9, day: 9, hour: 10))
        let store = makeStore(clock: clock)
        guard let work = store.tasks.first(where: { $0.name == "work" }) else { throw Failure(description: "work area missing") }
        store.update(work, name: work.name, targetSeconds: 60)
        var events = 0
        store.onTaskCompleted = { _, _ in events += 1 }
        store.start(taskID: work.id)
        clock.now = clock.now.addingTimeInterval(61)
        store.pulse()
        store.pulse()
        try expect(events == 1, "completion should emit exactly once per day")
        try expect(store.completionStreak(for: work) == 1, "completion should create a streak")
        try expect(store.recentCompletions(for: work).last?.isComplete == true, "today should be checked")
    }

    private static func testThirtyMinuteStreak() throws {
        let suiteName = "FocusBarSelfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let clock = SelfTestClock(localDate(year: 2026, month: 9, day: 1, hour: 10))
        let store = FocusStore(defaults: defaults, backups: nil, clock: { clock.now })
        let work = store.tasks[0]
        try expect(store.thirtyMinuteStreak(for: work) == 0, "no recorded days must show a zero 30-minute streak")
        store.update(work, name: work.name, targetSeconds: 60)
        store.setElapsed(for: work, to: 60)
        try expect(store.completionStreak(for: work) == 1 && store.thirtyMinuteStreak(for: work) == 0, "meeting a short daily target must not count as 30 minutes")
        store.update(work, name: work.name, targetSeconds: work.targetSeconds)
        store.setElapsed(for: work, to: 1_799)
        try expect(store.thirtyMinuteStreak(for: work) == 0, "time below 30 minutes must not qualify")
        var completions = 0
        store.onTaskCompleted = { _, _ in completions += 1 }
        store.start(taskID: work.id)
        clock.now = clock.now.addingTimeInterval(1)
        store.pulse()
        try expect(store.thirtyMinuteStreak(for: work) == 1 && store.completionStreak(for: work) == 0, "tracking must count today at exactly 30 minutes independently of the daily target")
        try expect(completions == 0, "the additional streak must not send target-complete notifications")
        store.finishCurrentSession()
        for day in 2...14 {
            clock.now = localDate(year: 2026, month: 9, day: day, hour: 10)
            store.pulse()
            try expect(store.thirtyMinuteStreak(for: work) == day - 1, "today below 30 minutes must retain yesterday's streak")
            store.setElapsed(for: work, to: 1_800)
            try expect(store.thirtyMinuteStreak(for: work) == day, "consecutive qualifying days must extend the streak beyond the ten-day display")
        }
        let reloaded = FocusStore(defaults: defaults, backups: nil, clock: { clock.now })
        try expect(reloaded.thirtyMinuteStreak(for: work) == 14, "relaunch must derive the streak from persisted elapsed history")
        try expect(reloaded.thirtyMinuteStreak(for: reloaded.tasks[1]) == 0, "each area's 30-minute streak must be independent")
        clock.now = localDate(year: 2026, month: 9, day: 15, hour: 5, minute: 59)
        reloaded.pulse()
        try expect(reloaded.thirtyMinuteStreak(for: work) == 14, "time before 6 AM must belong to the same focus day")
        clock.now = localDate(year: 2026, month: 9, day: 15, hour: 6)
        reloaded.pulse()
        try expect(reloaded.thirtyMinuteStreak(for: work) == 14, "6 AM rollover must retain yesterday's streak until today's threshold is reached")
        reloaded.setElapsed(for: work, to: 1_800)
        try expect(reloaded.thirtyMinuteStreak(for: work) == 15, "an elapsed edit to 30 minutes must immediately extend the streak")
        reloaded.setElapsed(for: work, to: 1_799)
        try expect(reloaded.thirtyMinuteStreak(for: work) == 14, "editing below the threshold must immediately remove today from the streak")
        reloaded.resetElapsed(for: work)
        try expect(reloaded.thirtyMinuteStreak(for: work) == 14, "resetting today must retain yesterday's qualifying streak")
        clock.now = localDate(year: 2026, month: 9, day: 16, hour: 6)
        reloaded.pulse()
        try expect(reloaded.thirtyMinuteStreak(for: work) == 0, "a completed day below 30 minutes must break the streak")
        reloaded.setElapsed(for: work, to: 1_800)
        reloaded.update(work, name: work.name, targetSeconds: 60)
        try expect(reloaded.thirtyMinuteStreak(for: work) == 1, "target changes must not change the 30-minute threshold or bridge a missed day")
        clock.now = localDate(year: 2026, month: 9, day: 18, hour: 6)
        reloaded.pulse()
        try expect(reloaded.thirtyMinuteStreak(for: work) == 0, "a day with no recorded history must also break the streak")
        reloaded.remove(work)
        try expect(reloaded.thirtyMinuteStreak(for: work) == 0, "removal must clear the area's 30-minute history too")
    }

    private static func testPillStreakPresentation() throws {
        let full = FocusStreaks(completedDays: 3, thirtyMinuteDays: 8)
        let fallback = FocusStreaks(completedDays: 0, thirtyMinuteDays: 3)
        let zero = FocusStreaks(completedDays: 0, thirtyMinuteDays: 0)
        let idle = PillState(title: "pd", isTracking: false, elapsed: 0, target: 3_600, streaks: full)
        let idleFallback = PillState(title: "pd", isTracking: false, elapsed: 0, target: 3_600, streaks: fallback)
        try expect(idle.title == "pd 3", "the full daily-target streak must take precedence on an incomplete idle pill")
        try expect(idleFallback.title == "pd 3*", "a 30-minute fallback must have an asterisk")
        try expect(PillState(title: "pd", isTracking: false, elapsed: 0, target: 3_600, streaks: zero).title == "pd 0", "zero streaks must show zero without an asterisk")
        try expect(PillState(title: "pd", isTracking: false, elapsed: 3_600, target: 3_600, streaks: full).title == "pd", "a completed idle pill must retain the plain area name")
        let tracking = PillState(title: "pd", isTracking: true, elapsed: 0, target: 3_600, streaks: full)
        try expect(tracking.title == "pd", "tracking must retain the plain area name")
        try expect(tracking == PillState(title: "pd", isTracking: true, elapsed: 1_800, target: 3_600, streaks: fallback), "streak-only hover changes must not invalidate an unchanged tracking image")

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let renderer = PillRenderer(statusItem: item)
        renderer.render(tracking, streaks: full)
        let image = item.button?.image
        try expect(renderer.hoverText == "pd · Tracking\n3-day streak\n8-day (30 min) streak", "pill hover must show both streaks for its area")
        renderer.render(tracking, streaks: fallback)
        try expect(renderer.hoverText == "pd · Tracking\n0-day streak\n3-day (30 min) streak", "hover text must refresh even when visual pill state is unchanged")
        try expect(item.button?.image === image, "updating hover streaks must preserve the rendered image")
        renderer.render(idleFallback, streaks: fallback)
        try expect(item.button?.image?.isTemplate == true, "idle streak labels must retain native template rendering")
        renderer.render(PillState(title: "work", isTracking: false, elapsed: 0, target: 3_600, streaks: zero), streaks: zero)
        try expect(renderer.hoverText == "work · Stopped\n0-day streak\n0-day (30 min) streak", "selection changes must switch both hover streaks to the new area")
        for name in ["pd", "work", "personal development"] {
            for useFallback in [false, true] {
                var previousWidth: CGFloat = 0
                for count in [3, 12, 123, 1_234] {
                    let streaks = FocusStreaks(completedDays: useFallback ? 0 : count, thirtyMinuteDays: count)
                    let state = PillState(title: name, isTracking: false, elapsed: 0, target: 3_600, streaks: streaks)
                    renderer.render(state, streaks: streaks)
                    let suffix = useFallback ? "\(count)*" : "\(count)"
                    try expect(state.title == "\(name) \(suffix)", "multi-digit streaks must preserve all digits and the fallback asterisk without parentheses")
                    guard let image = item.button?.image else { throw Failure(description: "missing multi-digit pill image") }
                    try expect(image.size.width > previousWidth && image.isTemplate, "native idle pill width must grow to fit longer streaks without shrinking its readable font")
                    try expect(item.length == image.size.width, "menu-bar allocation must match the full rendered streak label width")
                    previousWidth = image.size.width
                }
            }
        }
    }

    private static func testPillHoverPresentation() throws {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let renderer = PillRenderer(statusItem: item)
        let streaks = FocusStreaks(completedDays: 12, thirtyMinuteDays: 123)
        renderer.render(PillState(title: "hover test", isTracking: false, elapsed: 0, target: 3_600, streaks: streaks), streaks: streaks)
        guard let button = item.button,
              let area = button.trackingAreas.first(where: {
                  $0.options.contains(.activeAlways) && $0.options.contains(.mouseEnteredAndExited) && $0.owner is NSResponder
              }), let owner = area.owner as? NSResponder else {
            throw Failure(description: "pill has no inactive-app hover event handler; setting tooltip text alone does not present hover details")
        }
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.enterExitEvent(with: type, location: NSPoint(x: button.bounds.midX, y: button.bounds.midY),
                                  modifierFlags: [], timestamp: 0, windowNumber: button.window!.windowNumber,
                                  context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
        }
        func containsDetails(_ view: NSView) -> Bool {
            if let label = view as? NSTextField,
               label.stringValue.contains("12-day streak") && label.stringValue.contains("123-day (30 min) streak") { return true }
            return view.subviews.contains(where: containsDetails)
        }
        func hoverWindows() -> [NSWindow] {
            NSApp.windows.filter { $0.isVisible && $0.contentView.map(containsDetails) == true }
        }
        let wasActive = NSApp.isActive
        let keyWindow = NSApp.keyWindow
        owner.mouseEntered(with: event(.mouseEntered))
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.7))
        try expect(!hoverWindows().isEmpty, "entering an inactive menu-bar pill must actually show a native hover window with both streaks")
        try expect(NSApp.isActive == wasActive && NSApp.keyWindow === keyWindow, "hover details must not activate the app or steal keyboard focus")
        try expect(hoverWindows().allSatisfy { $0.ignoresMouseEvents }, "hover details must not intercept clicks")
        owner.mouseExited(with: event(.mouseExited))
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.02))
        try expect(hoverWindows().isEmpty, "leaving the pill must dismiss its hover details")
        owner.mouseEntered(with: event(.mouseEntered))
        owner.mouseExited(with: event(.mouseExited))
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.4))
        try expect(hoverWindows().isEmpty, "a quick pass over the pill must cancel the delayed hover presentation")
        owner.mouseEntered(with: event(.mouseEntered))
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.4))
        try expect(!hoverWindows().isEmpty, "hover details must work again after leaving and returning")
        renderer.dismissHover()
        try expect(hoverWindows().isEmpty, "a pill action or interruption must be able to dismiss the hover panel immediately")
    }

    private static func testPillHoverElapsedSnapshot() throws {
        let clock = SelfTestClock(localDate(year: 2026, month: 9, day: 9, hour: 10))
        let store = makeStore(clock: clock)
        let work = store.tasks[0]
        store.setElapsed(for: work, to: 3_661)
        store.start(taskID: work.id)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        var captures = 0
        let renderer = PillRenderer(statusItem: item, elapsedSnapshot: {
            captures += 1
            return store.formattedElapsed(for: work)
        })
        defer { renderer.dismissHover() }
        func render() {
            let streaks = store.streaks(for: work)
            renderer.render(PillState(title: work.name, isTracking: store.activeTaskID == work.id,
                                      elapsed: store.elapsed(for: work), target: work.targetSeconds, streaks: streaks), streaks: streaks)
        }
        render()
        let image = item.button?.image
        try expect(captures == 0, "ordinary pill rendering must not compute an elapsed snapshot")
        guard let button = item.button,
              let area = button.trackingAreas.first(where: { $0.owner is PillHover }),
              let owner = area.owner as? NSResponder else { throw Failure(description: "missing hover presenter") }
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.enterExitEvent(with: type, location: NSPoint(x: button.bounds.midX, y: button.bounds.midY),
                                  modifierFlags: [], timestamp: 0, windowNumber: button.window!.windowNumber,
                                  context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
        }
        func contains(_ expected: String, in view: NSView) -> Bool {
            if let field = view as? NSTextField, field.stringValue.contains(expected) { return true }
            return view.subviews.contains { contains(expected, in: $0) }
        }
        func isVisible(_ expected: String) -> Bool {
            NSApp.windows.contains { $0.isVisible && $0.contentView.map { contains(expected, in: $0) } == true }
        }
        clock.now = clock.now.addingTimeInterval(4)
        owner.mouseEntered(with: event(.mouseEntered))
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.5))
        try expect(isVisible("work · Tracking · Today 1:01:05"), "tracking hover must capture elapsed time when the panel opens, rather than when the pill was last rendered")
        try expect(captures == 1, "opening hover must capture elapsed time exactly once")
        clock.now = clock.now.addingTimeInterval(10)
        render()
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.05))
        try expect(isVisible("Today 1:01:05") && captures == 1, "elapsed time must remain a fixed snapshot while hovering, even if a visible display refreshes")
        try expect(item.button?.image === image, "hover elapsed time must not redraw the pill")
        owner.mouseExited(with: event(.mouseExited))
        store.finishCurrentSession()
        render()
        owner.mouseEntered(with: event(.mouseEntered))
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.5))
        try expect(isVisible("work · Stopped · Today 1:01:15") && captures == 2, "a new stopped hover must show a fresh snapshot of the current focus-day total")
    }

    private static func testThirtyMinuteRefreshWithoutPolling() throws {
        let suiteName = "FocusBarSelfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FocusStore(defaults: defaults, backups: nil)
        let work = store.tasks[0]
        store.setElapsed(for: work, to: 1_799.95)
        var observedStreak = 0
        var completions = 0
        store.onTaskCompleted = { _, _ in completions += 1 }
        let scheduler = FocusScheduler(store: store) { observedStreak = store.thirtyMinuteStreak(for: work) }
        defer { scheduler.stop() }
        store.start(taskID: work.id)
        scheduler.refresh()
        try expect(!scheduler.isRefreshingSeconds, "a hidden streak refresh must not use a seconds ticker")
        let timeout = Date.now.addingTimeInterval(2)
        while observedStreak == 0 && Date.now < timeout {
            RunLoop.main.run(until: Date.now.addingTimeInterval(0.02))
        }
        try expect(observedStreak == 1, "the one-shot 30-minute deadline must refresh hover streaks with all seconds displays hidden")
        try expect(completions == 0, "reaching 30 minutes must not emit a daily-target notification for a longer target")
        try expect(scheduler.scheduledDeadline == store.nextDeadline, "after 30 minutes the scheduler must advance to the remaining target or rollover")
    }

    private static func testCompletionNotificationStreaks() throws {
        let clock = SelfTestClock(localDate(year: 2026, month: 9, day: 9, hour: 10))
        let store = makeStore(clock: clock)
        let work = store.tasks[0]
        let pd = store.tasks[1]
        store.setElapsed(for: work, to: 1_800)
        clock.now = localDate(year: 2026, month: 9, day: 10, hour: 10)
        store.pulse()
        store.setElapsed(for: work, to: 1_800)
        store.select(taskID: pd.id)
        var workBody = ""
        var rolloverBody = ""
        store.onTaskCompleted = { task, key in
            let body = store.completionNotificationBody(for: task, dayKey: key)
            if task.id == work.id { workBody = body }
            else if task.id == pd.id { rolloverBody = body }
        }
        store.setElapsed(for: work, to: work.targetSeconds)
        try expect(workBody == "You reached your daily work target.\n1-day streak\n2-day (30 min) streak", "the notification must include both streaks for the completed area even when another area is selected")
        store.update(pd, name: pd.name, targetSeconds: 600)
        clock.now = localDate(year: 2026, month: 9, day: 11, hour: 5, minute: 40)
        store.start(taskID: pd.id)
        clock.now = localDate(year: 2026, month: 9, day: 11, hour: 6, minute: 1)
        store.refreshDayIfNeeded()
        try expect(rolloverBody == "You reached your daily pd target.\n1-day streak\n0-day (30 min) streak", "a rollover notification must use the completed day's archived twenty minutes without double-counting its live session")
    }

    private static func testRemoval() throws {
        let clock = SelfTestClock(localDate(year: 2026, month: 9, day: 9, hour: 10))
        let store = makeStore(clock: clock)
        guard let work = store.tasks.first(where: { $0.name == "work" }) else { throw Failure(description: "work area missing") }
        store.update(work, name: work.name, targetSeconds: 60)
        store.start(taskID: work.id)
        clock.now = clock.now.addingTimeInterval(61)
        store.pulse()
        store.remove(work)
        try expect(store.tasks.contains(where: { $0.id == work.id }) == false, "removed area must leave task list")
        try expect(store.activeTaskID == nil, "removing an active area must stop its timer")
        try expect(store.completionHistory[work.id] == nil, "removing an area must remove its history")
    }

    private static func testPillSpacing() throws {
        try expect(PillLayout.text(title: "work", marker: "") == "work", "markerless content must contain only its visible title")
        try expect(PillLayout.text(title: "pd", marker: "●") == "pd  ●", "tracking content must contain only its visible title and dot")
        try expect(PillLayout.horizontalInset == 12, "the pill must add equal explicit insets around its centered content")
        try expect(PillLayout.idleTemplateImage(title: "work").isTemplate, "the idle pill must use native template rendering")
    }

    private static func testDeadlinePlanning() throws {
        let clock = SelfTestClock(localDate(year: 2026, month: 9, day: 9, hour: 10))
        let store = makeStore(clock: clock)
        let work = store.tasks[0]
        store.update(work, name: work.name, targetSeconds: 60)
        let start = clock.now
        store.start(taskID: work.id)
        let scheduler = FocusScheduler(store: store, onRefresh: {})
        defer { scheduler.stop() }
        scheduler.refresh()
        try expect(scheduler.scheduledDeadline?.date == start.addingTimeInterval(60), "start must schedule completion")
        try expect(!scheduler.isRefreshingSeconds, "hidden displays must not poll")
        clock.now = start.addingTimeInterval(20)
        try expect(store.elapsed(for: work) == 20, "timestamps must advance elapsed time without a pulse")
        store.update(work, name: work.name, targetSeconds: 120)
        scheduler.refresh()
        try expect(scheduler.scheduledDeadline?.date == start.addingTimeInterval(120), "raising the target must reschedule completion")
        store.setElapsed(for: work, to: 100)
        scheduler.refresh()
        try expect(scheduler.scheduledDeadline?.date == clock.now.addingTimeInterval(20), "override must reschedule from the new elapsed total")
        scheduler.setSecondsDisplayVisible(true)
        try expect(scheduler.isRefreshingSeconds, "visible running seconds must refresh")
        store.finishCurrentSession()
        scheduler.refresh()
        try expect(!scheduler.isRefreshingSeconds, "stopped timers must not refresh seconds")
        try expect(scheduler.scheduledDeadline?.date == FocusDay.nextStart(after: clock.now), "stopping must cancel completion but retain rollover")
        store.update(work, name: work.name, targetSeconds: 90)
        store.start(taskID: work.id)
        scheduler.refresh()
        try expect(scheduler.scheduledDeadline?.date == clock.now.addingTimeInterval(1_700), "an already completed short target must still schedule the 30-minute streak refresh")
        scheduler.setSecondsDisplayVisible(false)
        try expect(!scheduler.isRefreshingSeconds, "closing the last seconds display must stop polling")

        let nearRollover = localDate(year: 2026, month: 9, day: 10, hour: 5, minute: 59)
        let deadline = FocusDeadline(now: nearRollover, rollover: FocusDay.nextStart(after: nearRollover), remaining: 120)
        try expect(deadline.date == nearRollover.addingTimeInterval(60), "rollover must precede a completion due in the next focus day")
    }

    private static func testCompletionWithoutPolling() throws {
        let suiteName = "FocusBarSelfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FocusStore(defaults: defaults, backups: nil)
        let work = store.tasks[0]
        store.update(work, name: work.name, targetSeconds: 1)
        store.setElapsed(for: work, to: 0.95)
        var completions = 0
        store.onTaskCompleted = { _, _ in completions += 1 }
        store.start(taskID: work.id)
        let scheduler = FocusScheduler(store: store, onRefresh: {})
        defer { scheduler.stop() }
        scheduler.refresh()
        try expect(!scheduler.isRefreshingSeconds, "completion test must run without a seconds ticker")
        let timeout = Date.now.addingTimeInterval(2)
        while completions == 0 && Date.now < timeout {
            RunLoop.main.run(until: Date.now.addingTimeInterval(0.02))
        }
        try expect(completions == 1, "one-shot deadline must deliver completion without polling")
        try expect(scheduler.scheduledDeadline?.date == store.activeStartedAt?.addingTimeInterval(1_800 - 0.95), "a completed short target must schedule the remaining 30-minute threshold")
    }

    private static func testAutomaticRescheduling() throws {
        // Keep the injected deadlines in the future while draining the real
        // run loop, so this test exercises change delivery rather than expiry.
        let clock = SelfTestClock(localDate(year: 2090, month: 9, day: 9, hour: 10))
        let store = makeStore(clock: clock)
        let work = store.tasks[0]
        store.update(work, name: work.name, targetSeconds: 60)
        let scheduler = FocusScheduler(store: store, onRefresh: {})
        store.onChange = { [weak scheduler] in scheduler?.requestRefresh() }
        defer { store.onChange = nil; scheduler.stop() }
        store.start(taskID: work.id)
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.02))
        try expect(scheduler.scheduledDeadline?.date == clock.now.addingTimeInterval(60), "store changes must schedule completion without a ticker or explicit refresh")
        store.update(work, name: work.name, targetSeconds: 120)
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.02))
        try expect(scheduler.scheduledDeadline?.date == clock.now.addingTimeInterval(120), "target changes must automatically replace the pending deadline")
        store.setElapsed(for: work, to: 120)
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.02))
        try expect(scheduler.scheduledDeadline?.date == clock.now.addingTimeInterval(1_680), "an override meeting the target must automatically replace completion with the 30-minute deadline")
        store.resetElapsed(for: work)
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.02))
        try expect(scheduler.scheduledDeadline?.date == clock.now.addingTimeInterval(120), "resetting a running timer must automatically schedule its new deadline")
    }

    private static func testNotificationPersistence() throws {
        let clock = SelfTestClock(localDate(year: 2026, month: 9, day: 9, hour: 10))
        let suiteName = "FocusBarSelfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FocusStore(defaults: defaults, backups: nil, clock: { clock.now })
        let work = store.tasks[0]
        store.update(work, name: work.name, targetSeconds: 60)
        var notifications = 0
        store.onTaskCompleted = { _, _ in notifications += 1 }
        store.setElapsed(for: work, to: 90)
        store.update(work, name: work.name, targetSeconds: 120)
        try expect(store.recentCompletions(for: store.tasks[0]).last?.isComplete == false, "raising the target must undo today's completion")
        store.update(work, name: work.name, targetSeconds: 60)
        try expect(notifications == 1, "target edits must not repeat completion notifications")
        store.resetElapsed(for: work)
        let reloaded = FocusStore(defaults: defaults, backups: nil, clock: { clock.now })
        reloaded.onTaskCompleted = { _, _ in notifications += 1 }
        reloaded.setElapsed(for: reloaded.tasks[0], to: 90)
        try expect(notifications == 1, "reset and relaunch must preserve notification deduplication")
        clock.now = localDate(year: 2026, month: 9, day: 10, hour: 6)
        reloaded.setElapsed(for: reloaded.tasks[0], to: 90)
        try expect(notifications == 2, "a new focus day must permit one new notification")
    }

    private static func testPillVisualState() throws {
        let initial = PillState(title: "work", isTracking: true, elapsed: 10, target: 60)
        let later = PillState(title: "work", isTracking: true, elapsed: 59, target: 60)
        try expect(initial == later, "elapsed seconds below target must not invalidate the pill")
        let complete = PillState(title: "work", isTracking: true, elapsed: 60, target: 60)
        try expect(complete != initial && complete.isComplete, "reaching target must invalidate the pill")
        try expect(complete == PillState(title: "work", isTracking: true, elapsed: 90, target: 60), "seconds beyond target must not redraw the pill")
        try expect(complete != PillState(title: "work", isTracking: true, elapsed: 60, target: 120), "target changes must update completion styling")
        try expect(complete != PillState(title: "work", isTracking: false, elapsed: 60, target: 60), "stopping must change visual representation")
        try expect(!PillState(title: "focus", isTracking: false, elapsed: 0, target: nil).isComplete, "empty area list must not appear complete")
    }

    private static func testFocusDayBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func date(_ month: Int, _ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        }
        let boundary = date(10, 5, 6)
        try expect(FocusDay.start(containing: boundary, calendar: calendar) == boundary, "exactly 6 AM starts a new day")
        try expect(FocusDay.start(containing: boundary.addingTimeInterval(-0.1), calendar: calendar) == date(10, 4, 6), "fractional second before 6 AM must remain in the prior day")
        for (month, day, hours) in [(3, 7, 23), (10, 31, 25)] {
            let start = date(month, day, 6)
            let next = FocusDay.nextStart(after: start, calendar: calendar)
            try expect(next.timeIntervalSince(start) == TimeInterval(hours * 3600), "rollover must account for daylight-saving changes")
            try expect(calendar.component(.hour, from: next) == 6, "DST rollover must remain at local 6 AM")
        }
    }

    private static func makeStore(clock: SelfTestClock) -> FocusStore {
        let suiteName = "FocusBarSelfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return FocusStore(defaults: defaults, backups: nil, clock: { clock.now })
    }

    private static func testNotificationErrors() throws {
        var authorization: (@MainActor (Result<Bool, Error>) -> Void)?
        var submissions: [UNNotificationRequest] = []
        var failures: [String] = []
        var submissionError: Error?
        let notifications = FocusNotifications(authorize: { authorization = $0 }, submit: { request, completion in
            submissions.append(request)
            completion(submissionError)
        }, onFailure: { failures.append($0) })
        notifications.start()
        notifications.deliver(identifier: "test", title: "Daily target complete", body: "Test target met")
        try expect(submissions.isEmpty, "completion must wait until authorization finishes")
        authorization?(.success(true))
        try expect(submissions.count == 1 && submissions[0].identifier == "test", "authorization must release the queued completion exactly once")
        try expect(submissions[0].trigger == nil && submissions[0].content.sound != nil, "completion must be an immediate native notification with the normal system sound")
        try expect(submissions[0].content.interruptionLevel == .active, "completion must use normal notification priority")
        try expect(failures.isEmpty, "a successful request must not show an error")
        submissionError = NSError(domain: "DeliveryTest", code: 17)
        notifications.deliver(identifier: "rejected", title: "Rejected target", body: "Test")
        try expect(failures.count == 1 && failures[0].contains("DeliveryTest") && failures[0].contains("17"), "delivery errors must preserve their domain and code and reach the error presenter")

        for result: Result<Bool, Error> in [.success(false), .failure(NSError(domain: "AuthorizationTest", code: 1))] {
            failures.removeAll()
            var submitted = false
            let blocked = FocusNotifications(authorize: { $0(result) }, submit: { _, _ in submitted = true }, onFailure: { failures.append($0) })
            blocked.deliver(identifier: "waiting", title: "Waiting target", body: "Test")
            blocked.start()
            try expect(failures.count == 1 && !submitted, "denial and authorization errors must be reported immediately without submitting queued requests")
            if case .failure = result {
                try expect(failures[0].contains("AuthorizationTest"), "authorization errors must retain the underlying failure")
            }
            blocked.deliver(identifier: "later", title: "Later target", body: "Test")
            try expect(failures.count == 2 && !submitted, "later completion attempts must not silently disappear after an authorization failure")
        }
    }

    private static func testPersistenceErrors() throws {
        let suiteName = "FocusBarSelfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let missing = try FocusPersistence.load(defaults: defaults)
        try expect(missing == nil, "a first launch must still create default areas")
        for value: Any in [Data("unreadable snapshot".utf8), "wrong preference type"] {
            defaults.set(value, forKey: FocusPersistence.key)
            var rejected = false
            do { _ = try FocusPersistence.load(defaults: defaults) }
            catch { rejected = true }
            try expect(rejected, "corrupt saved data must throw rather than silently reset the user's history")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let store = FocusStore(defaults: defaults, backups: nil)
        store.setElapsed(for: store.tasks[0], to: 123)
        let original = defaults.data(forKey: FocusPersistence.key)!
        var snapshot = try JSONDecoder().decode(FocusSnapshot.self, from: original)
        snapshot.totals[store.tasks[0].id] = .infinity
        var rejected = false
        do { try FocusPersistence.save(snapshot, defaults: defaults) }
        catch { rejected = true }
        try expect(rejected, "encoding failures must propagate to the fail-fast caller")
        try expect(defaults.data(forKey: FocusPersistence.key) == original, "a failed save must preserve the previous saved snapshot")
    }

    private static func testDailyBackups() throws {
        let suiteName = "FocusBarSelfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            do { try FileManager.default.removeItem(at: directory) }
            catch { preconditionFailure("Could not clean up backup test: \(error)") }
        }
        let clock = SelfTestClock(localDate(year: 2026, month: 9, day: 9, hour: 9, minute: 59))
        let backups = FocusBackups(directory: directory)
        let store = FocusStore(defaults: defaults, backups: backups, clock: { clock.now })
        let work = store.tasks[0]
        store.update(work, name: work.name, targetSeconds: 120)
        for (day, seconds) in [(9, 90.0), (10, 180.0), (11, 270.0)] {
            store.setElapsed(for: work, to: seconds)
            if day == 11 {
                clock.now = localDate(year: 2026, month: 9, day: 12, hour: 5, minute: 59).addingTimeInterval(30)
                store.start(taskID: work.id)
                clock.now = clock.now.addingTimeInterval(30)
            } else {
                clock.now = localDate(year: 2026, month: 9, day: day + 1, hour: 9)
            }
            store.refreshDayIfNeeded()
            store.pulse()
            try expect(store.elapsed(for: work) == 0, "successful backup must permit the daily reset")
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try expect(files.count == 2, "daily rotation must retain exactly two backup files")
        let data = try files.map { try Data(contentsOf: $0) }
        let snapshots = try data.map { try JSONDecoder().decode(FocusSnapshot.self, from: $0) }
        try expect(snapshots.map { $0.totals[work.id] } == [180, 300], "backups must preserve the previous two daily versions, including running time through 6 AM")
        try expect(snapshots.allSatisfy { $0.tasks == store.tasks }, "backup must include every focus area and target")
        try expect(snapshots.last?.dailyElapsedHistory?[work.id]?.values.contains(90) == true, "backup must preserve earlier daily history")
        try expect(snapshots.allSatisfy { $0.activeTaskID == nil }, "restored backups must not restart an old timer")

        defaults.removePersistentDomain(forName: suiteName)
        let dataAfterDeletion = try files.map { try Data(contentsOf: $0) }
        try expect(dataAfterDeletion == data, "deleting primary preferences must leave both backup files intact")
        defaults.set(data.last!, forKey: "focusbar.snapshot.v1")
        let restored = FocusStore(defaults: defaults, backups: nil, clock: { clock.now })
        try expect(restored.tasks == store.tasks, "a backup must be usable as the saved data without conversion")
        try expect(restored.dailyElapsedHistory[work.id]?.values.contains(300) == true, "restoration must recover the final backed-up daily total")
    }

    private static func testBackupFailurePreservesDay() throws {
        let suiteName = "FocusBarSelfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        let directory = root.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("blocks directory creation".utf8).write(to: directory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            do { try FileManager.default.removeItem(at: root) }
            catch { preconditionFailure("Could not clean up backup failure test: \(error)") }
        }
        let clock = SelfTestClock(localDate(year: 2026, month: 9, day: 9, hour: 5, minute: 59))
        let store = FocusStore(defaults: defaults, backups: FocusBackups(directory: directory), clock: { clock.now })
        let work = store.tasks[0]
        store.setElapsed(for: work, to: 120)
        store.start(taskID: work.id)
        var errors = 0
        store.onBackupFailure = { _ in errors += 1 }
        clock.now = localDate(year: 2026, month: 9, day: 9, hour: 6)
        store.refreshDayIfNeeded()
        try expect(store.backupFailure != nil, "backup errors must be surfaced")
        try expect(store.activeTaskID == nil, "a backup failure must stop tracking")
        try expect(store.elapsed(for: work) == 180, "a backup failure must preserve the prior ledger instead of resetting it")
        store.setElapsed(for: work, to: 0)
        store.start(taskID: work.id)
        try expect(store.elapsed(for: work) == 180 && store.activeTaskID == nil, "edits and tracking must wait for a successful backup")
        try expect(errors == 1, "repeated failures must not show duplicate alerts")
        try FileManager.default.removeItem(at: directory)
        store.refreshDayIfNeeded()
        try expect(store.backupFailure == nil && store.elapsed(for: work) == 0, "retrying after repair must finish the reset")
        let file = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first!
        let snapshot = try JSONDecoder().decode(FocusSnapshot.self, from: Data(contentsOf: file))
        try expect(snapshot.totals[work.id] == 180, "the retry must back up the preserved total")
    }

    private static func localDate(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
}
