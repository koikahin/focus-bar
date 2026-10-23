import Foundation

enum FocusDay {
    static func start(containing date: Date, calendar: Calendar = .current) -> Date {
        guard let today = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: date),
              let previous = calendar.date(byAdding: .day, value: -1, to: today) else {
            preconditionFailure("Cannot resolve local 6 AM focus-day boundary")
        }
        return today <= date ? today : previous
    }

    static func nextStart(after date: Date, calendar: Calendar = .current) -> Date {
        guard let next = calendar.nextDate(after: date,
                                          matching: DateComponents(hour: 6, minute: 0, second: 0),
                                          matchingPolicy: .nextTime) else {
            preconditionFailure("Cannot resolve next local 6 AM focus-day boundary")
        }
        return next
    }
}

/// Computes the next semantic event independently of AppKit and timer delivery.
struct FocusDeadline: Equatable {
    let date: Date

    init(now: Date, rollover: Date, remaining: TimeInterval?) {
        precondition(rollover > now, "Rollover must be in the future")
        if let remaining {
            precondition(remaining.isFinite && remaining > 0, "Remaining time must be positive")
            date = min(rollover, now.addingTimeInterval(remaining))
        } else {
            date = rollover
        }
    }
}

/// One timer for the next completion, 30-minute threshold, or rollover; an optional ticker serves only
/// visible seconds displays. Timer delivery always rechecks the wall clock.
@MainActor
final class FocusScheduler: NSObject {
    private let store: FocusStore
    private let onRefresh: () -> Void
    private var deadlineTimer: Timer?
    private var displayTimer: Timer?
    private var refreshQueued = false
    private var secondsDisplayVisible = false
    private(set) var scheduledDeadline: FocusDeadline?
    var isRefreshingSeconds: Bool { displayTimer != nil }

    init(store: FocusStore, onRefresh: @escaping () -> Void) {
        self.store = store
        self.onRefresh = onRefresh
    }

    // Coalesce compound edits (pause, override, resume) and avoid reentering
    // store mutations from a persistence callback.
    func requestRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }

    func setSecondsDisplayVisible(_ visible: Bool) {
        guard secondsDisplayVisible != visible else { return }
        secondsDisplayVisible = visible
        refresh()
    }

    func refresh() {
        store.pulse()
        onRefresh()
        let deadline = store.nextDeadline
        if deadline != scheduledDeadline || deadlineTimer == nil {
            deadlineTimer?.invalidate()
            scheduledDeadline = deadline
            let timer = Timer(fireAt: deadline.date, interval: 0, target: self,
                              selector: #selector(deadlineReached), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            deadlineTimer = timer
        }
        let needsSeconds = secondsDisplayVisible && store.activeTaskID != nil
        if needsSeconds && displayTimer == nil {
            let timer = Timer(timeInterval: 1, target: self, selector: #selector(refreshDisplay), userInfo: nil, repeats: true)
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            displayTimer = timer
        } else if !needsSeconds {
            displayTimer?.invalidate()
            displayTimer = nil
        }
    }

    func stop() {
        deadlineTimer?.invalidate()
        displayTimer?.invalidate()
        deadlineTimer = nil
        displayTimer = nil
        scheduledDeadline = nil
    }

    @objc private func deadlineReached() {
        deadlineTimer = nil
        refresh()
    }

    @objc private func refreshDisplay() {
        store.pulse()
        onRefresh()
    }
}
