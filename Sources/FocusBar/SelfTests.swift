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
            try testSleepRollover()
            try testCompletionEvent()
            try testRemoval()
            try testPillSpacing()
            print("FocusBar self-tests passed (7/7)")
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

    private static func testSleepRollover() throws {
        let clock = SelfTestClock(localDate(year: 2026, month: 9, day: 9, hour: 5, minute: 50))
        let store = makeStore(clock: clock)
        guard let work = store.tasks.first(where: { $0.name == "work" }) else { throw Failure(description: "work area missing") }
        store.start(taskID: work.id)
        clock.now = localDate(year: 2026, month: 9, day: 9, hour: 5, minute: 55)
        store.pauseForSleep()
        clock.now = localDate(year: 2026, month: 9, day: 10, hour: 9)
        store.resumeAfterSleep()
        try expect(store.activeTaskID == work.id, "sleeping timer should resume on wake")
        try expect(abs(store.elapsed(for: work)) < 0.001, "new focus day must begin at zero on wake")
        clock.now = clock.now.addingTimeInterval(10)
        store.pulse()
        try expect(abs(store.elapsed(for: work) - 10) < 0.001, "sleep time must not be counted")
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
        try expect(PillLayout.text(title: "pd", marker: "✓") == "pd  ✓", "marked content must contain only its visible title and marker")
        try expect(PillLayout.horizontalInset == 12, "the pill must add equal explicit insets around its centered content")
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
