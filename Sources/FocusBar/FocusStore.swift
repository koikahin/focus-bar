import Foundation
import Observation

struct FocusTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var targetSeconds: TimeInterval
}

struct FocusStreaks: Equatable {
    let completedDays: Int
    let thirtyMinuteDays: Int

    var completionLabel: String { "\(completedDays)-day streak" }
    var thirtyMinuteLabel: String { "\(thirtyMinuteDays)-day (30 min) streak" }
    var summary: String { "\(completionLabel)\n\(thirtyMinuteLabel)" }
    var idleLabel: String {
        if completedDays > 0 { return "\(completedDays)" }
        return thirtyMinuteDays > 0 ? "\(thirtyMinuteDays)*" : "0"
    }
}

struct FocusSnapshot: Codable {
    var tasks: [FocusTask]
    var totals: [UUID: TimeInterval]
    var dayKey: String
    var activeTaskID: UUID?
    var activeStartedAt: Date?
    var currentTaskID: UUID?
    var completionHistory: [UUID: Set<String>]?
    var dailyElapsedHistory: [UUID: [String: TimeInterval]]?
    var dailyTargetHistory: [UUID: [String: TimeInterval]]?
    var notifiedCompletionHistory: [UUID: Set<String>]?
}

enum CompletionDayStatus {
    case none
    case partial
    case complete
}

struct CompletionDay: Identifiable {
    let id: String
    let date: Date
    let elapsedSeconds: TimeInterval
    let targetSeconds: TimeInterval
    let recordedAsComplete: Bool

    var status: CompletionDayStatus {
        if recordedAsComplete || elapsedSeconds >= targetSeconds { return .complete }
        if elapsedSeconds > 60 { return .partial }
        return .none
    }

    var isComplete: Bool { status == .complete }
}

@MainActor @Observable
final class FocusStore {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let backups: FocusBackups?
    @ObservationIgnored var onTaskCompleted: ((FocusTask, String) -> Void)?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onBackupFailure: ((String) -> Void)?
    private(set) var backupFailure: String?

    var tasks: [FocusTask] = []
    var totals: [UUID: TimeInterval] = [:]
    var completionHistory: [UUID: Set<String>] = [:]
    var dailyElapsedHistory: [UUID: [String: TimeInterval]] = [:]
    var dailyTargetHistory: [UUID: [String: TimeInterval]] = [:]
    private var notifiedCompletionHistory: [UUID: Set<String>] = [:]
    var activeTaskID: UUID?
    var activeStartedAt: Date?
    var currentTaskID: UUID?
    var now: Date
    private var dayKey: String

    var currentTask: FocusTask? {
        guard let id = activeTaskID ?? currentTaskID else { return tasks.first }
        return tasks.first(where: { $0.id == id })
    }

    var nextDeadline: FocusDeadline {
        let remaining = currentTask.flatMap { task -> TimeInterval? in
            guard activeTaskID == task.id else { return nil }
            let elapsed = elapsed(for: task, at: now)
            return [task.targetSeconds, 30 * 60].map { $0 - elapsed }.filter { $0 > 0 }.min()
        }
        return FocusDeadline(now: now, rollover: FocusDay.nextStart(after: now), remaining: remaining)
    }

    init(defaults: UserDefaults = .standard, backups: FocusBackups? = .live, clock: @escaping () -> Date = { Date.now }) {
        self.defaults = defaults
        self.backups = backups
        self.clock = clock
        let initialNow = clock()
        now = initialNow
        dayKey = Self.focusDayKey(for: initialNow)
        load()
        refreshDayIfNeeded(at: initialNow)
    }

    func pulse() {
        guard refreshDayIfNeeded(at: clock()) else { return }
        evaluateCompletions()
    }

    func refreshDayIfNeeded() {
        refreshDayIfNeeded(at: clock())
    }

    @discardableResult
    private func refreshDayIfNeeded(at timestamp: Date) -> Bool {
        now = timestamp
        let key = Self.focusDayKey(for: timestamp)
        guard key != dayKey else { return true }

        // Close the old daily ledger precisely at 6 AM before starting the new
        // one. This is evaluated on the first pulse after wake, so it does not
        // depend on a timer firing while the Mac is asleep.
        let newFocusDayStart = Self.focusDayStart(for: timestamp)
        var closingSnapshot = snapshot()
        if let id = activeTaskID, let started = activeStartedAt {
            closingSnapshot.totals[id, default: 0] += max(0, newFocusDayStart.timeIntervalSince(started))
        }
        // A backup represents the completed day, with no running session
        // that could accidentally count time again if it is restored.
        closingSnapshot.activeTaskID = nil
        closingSnapshot.activeStartedAt = nil
        do {
            try backups?.save(closingSnapshot)
        } catch {
            // Preserve the original ledger and stop tracking rather than
            // resetting without a backup. A later action/relaunch can retry.
            if let id = activeTaskID, let started = activeStartedAt {
                totals[id, default: 0] += max(0, timestamp.timeIntervalSince(started))
                activeTaskID = nil
                activeStartedAt = nil
                save()
            }
            let message = "The daily backup could not be saved. Tracking has stopped and the daily reset was postponed to preserve your data. Fix access to \(backups?.directory.path ?? "the backup folder") and try again.\n\n\(error.localizedDescription)"
            if backupFailure != message {
                backupFailure = message
                onBackupFailure?(message)
            }
            return false
        }
        backupFailure = nil
        totals = closingSnapshot.totals
        recordDailyHistory(for: dayKey, totals: totals)
        recordCompletions(for: dayKey, totals: totals)
        dayKey = key
        totals = [:]
        activeStartedAt = activeTaskID == nil ? nil : newFocusDayStart
        save()
        return true
    }

    func elapsed(for task: FocusTask) -> TimeInterval {
        // Register visible SwiftUI reads for refreshes without relying on
        // those refreshes to advance the timer itself.
        _ = now
        return elapsed(for: task, at: clock())
    }

    private func elapsed(for task: FocusTask, at timestamp: Date) -> TimeInterval {
        var value = totals[task.id, default: 0]
        if activeTaskID == task.id, let started = activeStartedAt {
            value += max(0, timestamp.timeIntervalSince(started))
        }
        return value
    }

    func formattedElapsed(for task: FocusTask) -> String {
        formatted(seconds: elapsed(for: task))
    }

    func formatted(targetSeconds: TimeInterval) -> String { DurationInput.display(targetSeconds) }

    func start(taskID: UUID) {
        guard tasks.contains(where: { $0.id == taskID }) else { return }
        let timestamp = clock()
        guard refreshDayIfNeeded(at: timestamp) else { return }
        finishCurrentSession(at: timestamp)
        currentTaskID = taskID
        activeTaskID = taskID
        activeStartedAt = timestamp
        save()
    }

    /// Selecting an area is deliberately not a start action. This lets the
    /// user choose their next focus without accidentally recording time.
    func select(taskID: UUID) {
        guard tasks.contains(where: { $0.id == taskID }) else { return }
        let timestamp = clock()
        guard refreshDayIfNeeded(at: timestamp) else { return }
        finishCurrentSession(at: timestamp)
        currentTaskID = taskID
        save()
    }

    func toggleCurrentTask() {
        guard refreshDayIfNeeded(at: clock()) else { return }
        if activeTaskID != nil {
            finishCurrentSession()
        } else if let task = currentTask ?? tasks.first {
            start(taskID: task.id)
        }
    }

    func finishCurrentSession() {
        let timestamp = clock()
        guard refreshDayIfNeeded(at: timestamp) else { return }
        finishCurrentSession(at: timestamp)
    }

    private func finishCurrentSession(at timestamp: Date) {
        guard let id = activeTaskID, let started = activeStartedAt else { return }
        totals[id, default: 0] += max(0, timestamp.timeIntervalSince(started))
        activeTaskID = nil
        activeStartedAt = nil
        evaluateCompletions()
        save()
    }

    func stopForSystemInterruption() -> FocusTask? {
        let timestamp = clock()
        guard refreshDayIfNeeded(at: timestamp) else { return nil }
        guard let id = activeTaskID,
              let task = tasks.first(where: { $0.id == id }) else { return nil }
        finishCurrentSession(at: timestamp)
        return task
    }

    func setElapsed(for task: FocusTask, to seconds: TimeInterval) {
        let timestamp = clock()
        guard refreshDayIfNeeded(at: timestamp) else { return }
        guard let currentTask = tasks.first(where: { $0.id == task.id }) else { return }
        totals[task.id] = max(0, seconds)
        if activeTaskID == task.id { activeStartedAt = timestamp }
        synchronizeTodayCompletion(for: currentTask)
        save()
    }

    func resetElapsed(for task: FocusTask) {
        setElapsed(for: task, to: 0)
    }

    func addTask(name: String, targetSeconds: TimeInterval) {
        guard refreshDayIfNeeded(at: clock()) else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let task = FocusTask(name: cleaned, targetSeconds: max(1, targetSeconds))
        tasks.append(task)
        currentTaskID = currentTaskID ?? task.id
        save()
    }

    func update(_ task: FocusTask, name: String, targetSeconds: TimeInterval) {
        guard refreshDayIfNeeded(at: clock()) else { return }
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        tasks[index].name = cleaned
        tasks[index].targetSeconds = max(1, targetSeconds)
        synchronizeTodayCompletion(for: tasks[index])
        save()
    }

    func remove(_ task: FocusTask) {
        guard refreshDayIfNeeded(at: clock()) else { return }
        if activeTaskID == task.id { finishCurrentSession() }
        tasks.removeAll { $0.id == task.id }
        totals[task.id] = nil
        completionHistory[task.id] = nil
        dailyElapsedHistory[task.id] = nil
        dailyTargetHistory[task.id] = nil
        notifiedCompletionHistory[task.id] = nil
        if currentTaskID == task.id { currentTaskID = tasks.first?.id }
        save()
    }

    func recentCompletions(for task: FocusTask, count: Int = 10) -> [CompletionDay] {
        let calendar = Calendar.current
        let currentStart = Self.focusDayStart(for: now)
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: currentStart) else { return nil }
            let key = Self.focusDayKey(for: date)
            let isCurrentDay = key == dayKey
            let elapsedSeconds = isCurrentDay
                ? elapsed(for: task)
                : dailyElapsedHistory[task.id]?[key, default: 0] ?? 0
            let targetSeconds = isCurrentDay
                ? task.targetSeconds
                : dailyTargetHistory[task.id]?[key] ?? task.targetSeconds
            return CompletionDay(
                id: key,
                date: date,
                elapsedSeconds: elapsedSeconds,
                targetSeconds: targetSeconds,
                recordedAsComplete: completionHistory[task.id]?.contains(key) == true
            )
        }
    }

    func completionStreak(for task: FocusTask) -> Int {
        streaks(for: task).completedDays
    }

    func thirtyMinuteStreak(for task: FocusTask) -> Int {
        streaks(for: task).thirtyMinuteDays
    }

    func streaks(for task: FocusTask, through completedDayKey: String? = nil) -> FocusStreaks {
        let endingAt: Date
        if let completedDayKey {
            guard let date = ISO8601DateFormatter().date(from: completedDayKey) else {
                preconditionFailure("Invalid completion focus-day key: \(completedDayKey)")
            }
            endingAt = date
        } else {
            endingAt = Self.focusDayStart(for: now)
        }
        let history = completionHistory[task.id, default: []]
        let completion = currentStreak(endingAt: endingAt) { history.contains($0) }
        let currentDayKey = Self.focusDayKey(for: now)
        let thirtyMinutes = currentStreak(endingAt: endingAt) { key in
            // During rollover callbacks, the old day is already archived, but
            // its live session has not yet been rebased. Use the saved total.
            let seconds = key == dayKey && key == currentDayKey
                ? elapsed(for: task) : dailyElapsedHistory[task.id]?[key] ?? 0
            return seconds >= 30 * 60
        }
        return FocusStreaks(completedDays: completion, thirtyMinuteDays: thirtyMinutes)
    }

    func completionNotificationBody(for task: FocusTask, dayKey: String) -> String {
        "You reached your daily \(task.name) target.\n\(streaks(for: task, through: dayKey).summary)"
    }

    private func currentStreak(endingAt: Date, qualifies: (String) -> Bool) -> Int {
        let calendar = Calendar.current
        func previousDay(before date: Date) -> Date {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else {
                preconditionFailure("Cannot resolve previous focus day for streak")
            }
            return previous
        }
        var date = endingAt
        if !qualifies(Self.focusDayKey(for: date)) {
            date = previousDay(before: date)
        }

        var streak = 0
        while qualifies(Self.focusDayKey(for: date)) {
            streak += 1
            date = previousDay(before: date)
        }
        return streak
    }

    private func synchronizeTodayCompletion(for task: FocusTask) {
        if elapsed(for: task) >= task.targetSeconds {
            recordCompletion(for: task, dayKey: dayKey)
        } else {
            completionHistory[task.id]?.remove(dayKey)
        }
    }

    private func evaluateCompletions() {
        for task in tasks where elapsed(for: task) >= task.targetSeconds {
            recordCompletion(for: task, dayKey: dayKey)
        }
    }

    private func recordCompletions(for completedDayKey: String, totals: [UUID: TimeInterval]) {
        for task in tasks where totals[task.id, default: 0] >= task.targetSeconds {
            recordCompletion(for: task, dayKey: completedDayKey)
        }
    }

    private func recordDailyHistory(for completedDayKey: String, totals: [UUID: TimeInterval]) {
        for task in tasks {
            dailyElapsedHistory[task.id, default: [:]][completedDayKey] = max(0, totals[task.id, default: 0])
            dailyTargetHistory[task.id, default: [:]][completedDayKey] = task.targetSeconds
        }
    }

    private func recordCompletion(for task: FocusTask, dayKey completedDayKey: String) {
        let inserted = completionHistory[task.id, default: []].insert(completedDayKey).inserted
        let shouldNotify = notifiedCompletionHistory[task.id, default: []].insert(completedDayKey).inserted
        if inserted || shouldNotify { save() }
        if shouldNotify { onTaskCompleted?(task, completedDayKey) }
    }

    private func formatted(seconds: TimeInterval) -> String {
        let rounded = Int(seconds.rounded(.down))
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let seconds = rounded % 60
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }

    private func load() {
        let saved: FocusSnapshot?
        do {
            saved = try FocusPersistence.load(defaults: defaults)
        } catch {
            FocusFailure.stop("The saved focus data could not be read. It has not been replaced or reset.", error: error)
        }
        guard let snapshot = saved else {
            tasks = [
                FocusTask(name: "work", targetSeconds: 4 * 60 * 60),
                FocusTask(name: "pd", targetSeconds: 60 * 60)
            ]
            currentTaskID = tasks.first?.id
            return
        }
        tasks = snapshot.tasks
        totals = snapshot.totals
        dayKey = snapshot.dayKey
        activeTaskID = snapshot.activeTaskID
        activeStartedAt = snapshot.activeStartedAt
        currentTaskID = snapshot.currentTaskID
        completionHistory = snapshot.completionHistory ?? [:]
        dailyElapsedHistory = snapshot.dailyElapsedHistory ?? [:]
        dailyTargetHistory = snapshot.dailyTargetHistory ?? [:]
        notifiedCompletionHistory = snapshot.notifiedCompletionHistory ?? completionHistory

        // Older snapshots only knew whether a day was complete. Preserve
        // those green days by treating the target as the minimum known total;
        // exact elapsed and target history is recorded from this version on.
        for task in tasks {
            for completedDayKey in completionHistory[task.id, default: []] {
                if dailyElapsedHistory[task.id]?[completedDayKey] == nil {
                    dailyElapsedHistory[task.id, default: [:]][completedDayKey] = task.targetSeconds
                }
                if dailyTargetHistory[task.id]?[completedDayKey] == nil {
                    dailyTargetHistory[task.id, default: [:]][completedDayKey] = task.targetSeconds
                }
            }
        }
    }

    private func snapshot() -> FocusSnapshot {
        FocusSnapshot(
            tasks: tasks,
            totals: totals,
            dayKey: dayKey,
            activeTaskID: activeTaskID,
            activeStartedAt: activeStartedAt,
            currentTaskID: currentTaskID,
            completionHistory: completionHistory,
            dailyElapsedHistory: dailyElapsedHistory,
            dailyTargetHistory: dailyTargetHistory,
            notifiedCompletionHistory: notifiedCompletionHistory
        )
    }

    private func save() {
        let snapshot = snapshot()
        do {
            try FocusPersistence.save(snapshot, defaults: defaults)
        } catch {
            FocusFailure.stop("The current focus data could not be encoded for saving. The previously saved data has not been replaced.", error: error)
        }
        onChange?()
    }

    private static func focusDayKey(for date: Date) -> String {
        ISO8601DateFormatter().string(from: focusDayStart(for: date))
    }

    private static func focusDayStart(for date: Date) -> Date {
        FocusDay.start(containing: date)
    }
}
