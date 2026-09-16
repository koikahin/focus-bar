import Foundation

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
            print("FocusBar self-tests passed (11/11)")
            return true
        } catch {
            FileHandle.standardError.write(Data("FocusBar self-test failed: \(error)\n".utf8))
            return false
        }
    }

    private static func testElapsedInput() throws {
        try expect(ElapsedInput.seconds(from: "2:15") == 8_100, "H:MM should mean hours and minutes")
        try expect(ElapsedInput.seconds(from: "2:15:30") == 8_130, "H:MM:SS should include seconds")
        try expect(ElapsedInput.seconds(from: "2:75") == nil, "invalid minutes should fail")
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
        let store = FocusStore(defaults: defaults, clock: { clock.now })
        guard let work = store.tasks.first(where: { $0.name == "work" }) else { throw Failure(description: "work area missing") }
        store.update(work, name: work.name, targetSeconds: 120)
        guard let updatedWork = store.tasks.first(where: { $0.id == work.id }) else { throw Failure(description: "updated area missing") }
        store.setElapsed(for: updatedWork, to: 90)
        clock.now = localDate(year: 2026, month: 9, day: 10, hour: 6, minute: 1)
        store.pulse()
        guard let currentWork = store.tasks.first(where: { $0.id == work.id }) else { throw Failure(description: "current area missing") }
        store.update(currentWork, name: currentWork.name, targetSeconds: 60)
        let reloadedStore = FocusStore(defaults: defaults, clock: { clock.now })
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

    private static func makeStore(clock: SelfTestClock) -> FocusStore {
        let suiteName = "FocusBarSelfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return FocusStore(defaults: defaults, clock: { clock.now })
    }

    private static func localDate(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
}
