import AppKit
import Darwin
import Observation
import SwiftUI
import UserNotifications

@main
@MainActor
struct FocusBarMain {
    // NSApplication's delegate property is weak, so the menu-bar controller
    // must be retained for the entire process lifetime.
    private static let appDelegate = AppDelegate()

    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            guard FocusSelfTests.run() else { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--quit-running") {
            quitRunningCopies()
            return
        }
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static func quitRunningCopies() {
        let bundleID = "com.local.focusbar"
        let currentPID = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            where app.processIdentifier != currentPID {
            app.terminate()
        }

        let deadline = Date.now.addingTimeInterval(3)
        while Date.now < deadline,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .contains(where: { $0.processIdentifier != currentPID }) {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
        }
    }
}

@MainActor
private final class PillContentLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private let store = FocusStore()
    private var statusItem: NSStatusItem!
    private var pillLabel: PillContentLabel!
    private var ticker: Timer?
    private var openMenuTaskItems: [UUID: NSMenuItem] = [:]
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        button.target = self
        button.action = #selector(statusItemPressed(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.isBordered = false
        button.title = ""
        button.image = nil
        button.wantsLayer = true
        button.layer?.cornerRadius = 10
        button.layer?.borderWidth = 0.5
        button.layer?.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor

        let label = PillContentLabel(frame: .zero)
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.usesSingleLineMode = true
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        pillLabel = label

        updateStatusItem()
        let ticker = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        let notifications = UNUserNotificationCenter.current()
        notifications.delegate = self
        notifications.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        store.onTaskCompleted = { task, dayKey in
            let content = UNMutableNotificationContent()
            content.title = "Daily target complete"
            content.body = "You reached your daily \(task.name) target."
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "focusbar.\(task.id.uuidString).\(dayKey)",
                content: content,
                trigger: nil
            )
            notifications.add(request)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.finishCurrentSession()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func tick() {
        store.pulse()
        updateStatusItem()
        updateOpenMenu()
    }

    @objc private func willSleep() {
        store.pauseForSleep()
        updateStatusItem()
    }

    @objc private func didWake() {
        store.resumeAfterSleep()
        updateStatusItem()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            store.toggleCurrentTask()
            updateStatusItem()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let task = store.currentTask
        let title = task?.name ?? "focus"
        let isTracking = store.activeTaskID != nil
        let isComplete = task.map { store.elapsed(for: $0) >= $0.targetSeconds } ?? false

        let completeColor = NSColor.systemGreen
        if isTracking {
            let marker = "●"
            let titleColor = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
            let markerColor: NSColor = isComplete ? completeColor : .systemRed
            let markerAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: markerColor, .font: NSFont.systemFont(ofSize: 10, weight: .bold)]
            let titleAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: titleColor, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
            let pillText = PillLayout.text(title: title, marker: marker)
            let rendered = NSMutableAttributedString(string: pillText, attributes: titleAttributes)
            let markerRange = (pillText as NSString).range(of: marker, options: .backwards)
            rendered.addAttributes(markerAttributes, range: markerRange)

            button.image = nil
            button.imagePosition = .noImage
            button.contentTintColor = nil
            pillLabel.isHidden = false
            pillLabel.attributedStringValue = rendered
            pillLabel.invalidateIntrinsicContentSize()
            button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
            button.layer?.borderWidth = 0.5
            button.layer?.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor
            statusItem.length = PillLayout.width(forContentWidth: rendered.size().width)
        } else {
            let image = PillLayout.idleTemplateImage(title: title)
            pillLabel.isHidden = true
            button.image = image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.contentTintColor = isComplete ? completeColor : nil
            button.layer?.backgroundColor = NSColor.clear.cgColor
            button.layer?.borderWidth = 0
            statusItem.length = image.size.width
        }
        button.needsLayout = true
        button.layoutSubtreeIfNeeded()
        button.toolTip = task.map { "\($0.name): \(store.formattedElapsed(for: $0)) today" } ?? "Choose a focus area"
    }

    private func showMenu() {
        store.pulse()
        openMenuTaskItems.removeAll()
        let menu = NSMenu()
        // No explicit appearance: native NSMenu automatically follows the
        // user's light/dark system setting, including while it is open.
        menu.appearance = nil
        menu.autoenablesItems = false

        let heading = NSMenuItem(title: "Today · resets at 6:00 AM", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())

        for task in store.tasks {
            let elapsed = store.formattedElapsed(for: task)
            let target = store.formatted(targetSeconds: task.targetSeconds)
            let item = NSMenuItem(title: "\(task.name)    \(elapsed) / \(target)", action: #selector(selectTask(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = task.id.uuidString
            item.state = store.activeTaskID == task.id ? .on : .off
            if store.elapsed(for: task) >= task.targetSeconds {
                item.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Complete")
            }
            menu.addItem(item)
            openMenuTaskItems[task.id] = item
        }

        if store.tasks.isEmpty {
            let empty = NSMenuItem(title: "No focus areas yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Focus Areas…", action: #selector(openSettings), keyEquivalent: ",")
        manage.target = self
        menu.addItem(manage)
        let quit = NSMenuItem(title: "Quit FocusBar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
        openMenuTaskItems.removeAll()
    }

    private func updateOpenMenu() {
        guard !openMenuTaskItems.isEmpty else { return }
        for task in store.tasks {
            guard let item = openMenuTaskItems[task.id] else { continue }
            let elapsed = store.formattedElapsed(for: task)
            let target = store.formatted(targetSeconds: task.targetSeconds)
            item.title = "\(task.name)    \(elapsed) / \(target)"
            item.state = store.activeTaskID == task.id ? .on : .off
            item.image = store.elapsed(for: task) >= task.targetSeconds
                ? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Complete")
                : nil
        }
    }

    @objc private func selectTask(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return }
        store.select(taskID: id)
        updateStatusItem()
    }

    @objc private func openSettings() {
        if let window = settingsWindow {
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let view = SettingsView(
            store: store,
            onChange: { [weak self] in self?.updateStatusItem() },
            onClose: { [weak window] in window?.performClose(nil) }
        )
        window.title = "Focus Areas"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 500, height: 500)
        window.center()
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        settingsWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

enum PillLayout {
    static let horizontalInset: CGFloat = 12
    static let height: CGFloat = 20

    static func text(title: String, marker: String) -> String {
        marker.isEmpty ? title : "\(title)  \(marker)"
    }

    static func width(forContentWidth contentWidth: CGFloat) -> CGFloat {
        ceil(contentWidth) + (horizontalInset * 2)
    }

    static func idleTemplateImage(title: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.black,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let size = NSSize(width: width(forContentWidth: text.size().width), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 9.5, yRadius: 9.5)
            outline.lineWidth = 1
            outline.stroke()
            let textSize = text.size()
            text.draw(at: NSPoint(
                x: floor((rect.width - textSize.width) / 2),
                y: floor((rect.height - textSize.height) / 2)
            ))
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct FocusTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var targetSeconds: TimeInterval
}

private struct FocusSnapshot: Codable {
    var tasks: [FocusTask]
    var totals: [UUID: TimeInterval]
    var dayKey: String
    var activeTaskID: UUID?
    var activeStartedAt: Date?
    var currentTaskID: UUID?
    var completionHistory: [UUID: Set<String>]?
    var dailyElapsedHistory: [UUID: [String: TimeInterval]]?
    var dailyTargetHistory: [UUID: [String: TimeInterval]]?
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
    private let defaultsKey = "focusbar.snapshot.v1"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored var onTaskCompleted: ((FocusTask, String) -> Void)?

    var tasks: [FocusTask] = []
    var totals: [UUID: TimeInterval] = [:]
    var completionHistory: [UUID: Set<String>] = [:]
    var dailyElapsedHistory: [UUID: [String: TimeInterval]] = [:]
    var dailyTargetHistory: [UUID: [String: TimeInterval]] = [:]
    var activeTaskID: UUID?
    var activeStartedAt: Date?
    var currentTaskID: UUID?
    var now: Date
    private var dayKey: String
    private var taskToResumeAfterWake: UUID?

    var currentTask: FocusTask? {
        guard let id = activeTaskID ?? currentTaskID else { return tasks.first }
        return tasks.first(where: { $0.id == id })
    }

    init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = { Date.now }) {
        self.defaults = defaults
        self.clock = clock
        let initialNow = clock()
        now = initialNow
        dayKey = Self.focusDayKey(for: initialNow)
        load()
        refreshDayIfNeeded(at: initialNow)
    }

    func pulse() {
        refreshDayIfNeeded(at: clock())
        evaluateCompletions()
    }

    func refreshDayIfNeeded() {
        refreshDayIfNeeded(at: clock())
    }

    private func refreshDayIfNeeded(at timestamp: Date) {
        now = timestamp
        let key = Self.focusDayKey(for: timestamp)
        guard key != dayKey else { return }

        // Close the old daily ledger precisely at 6 AM before starting the new
        // one. This is evaluated on the first pulse after wake, so it does not
        // depend on a timer firing while the Mac is asleep.
        let newFocusDayStart = Self.focusDayStart(for: timestamp)
        if let id = activeTaskID, let started = activeStartedAt {
            totals[id, default: 0] += max(0, newFocusDayStart.timeIntervalSince(started))
        }
        recordDailyHistory(for: dayKey, totals: totals)
        recordCompletions(for: dayKey, totals: totals)
        dayKey = key
        totals = [:]
        activeStartedAt = activeTaskID == nil ? nil : newFocusDayStart
        save()
    }

    func elapsed(for task: FocusTask) -> TimeInterval {
        var value = totals[task.id, default: 0]
        if activeTaskID == task.id, let started = activeStartedAt {
            value += max(0, now.timeIntervalSince(started))
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
        refreshDayIfNeeded(at: timestamp)
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
        refreshDayIfNeeded(at: timestamp)
        finishCurrentSession(at: timestamp)
        currentTaskID = taskID
        save()
    }

    func toggleCurrentTask() {
        refreshDayIfNeeded()
        if activeTaskID != nil {
            finishCurrentSession()
        } else if let task = currentTask ?? tasks.first {
            start(taskID: task.id)
        }
    }

    func finishCurrentSession() {
        let timestamp = clock()
        refreshDayIfNeeded(at: timestamp)
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

    func pauseForSleep() {
        let timestamp = clock()
        refreshDayIfNeeded(at: timestamp)
        taskToResumeAfterWake = activeTaskID
        finishCurrentSession(at: timestamp)
    }

    func resumeAfterSleep() {
        let timestamp = clock()
        refreshDayIfNeeded(at: timestamp)
        defer { taskToResumeAfterWake = nil }
        guard let id = taskToResumeAfterWake, tasks.contains(where: { $0.id == id }) else { return }
        currentTaskID = id
        activeTaskID = id
        activeStartedAt = timestamp
        save()
    }

    func setElapsed(for task: FocusTask, to seconds: TimeInterval) {
        let timestamp = clock()
        refreshDayIfNeeded(at: timestamp)
        guard tasks.contains(where: { $0.id == task.id }) else { return }
        totals[task.id] = max(0, seconds)
        if activeTaskID == task.id { activeStartedAt = timestamp }
        synchronizeTodayCompletion(for: task)
        save()
    }

    func resetElapsed(for task: FocusTask) {
        setElapsed(for: task, to: 0)
    }

    func addTask(name: String, targetSeconds: TimeInterval) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let task = FocusTask(name: cleaned, targetSeconds: max(1, targetSeconds))
        tasks.append(task)
        currentTaskID = currentTaskID ?? task.id
        save()
    }

    func update(_ task: FocusTask, name: String, targetSeconds: TimeInterval) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        tasks[index].name = cleaned
        tasks[index].targetSeconds = max(1, targetSeconds)
        synchronizeTodayCompletion(for: tasks[index])
        save()
    }

    func remove(_ task: FocusTask) {
        if activeTaskID == task.id { finishCurrentSession() }
        tasks.removeAll { $0.id == task.id }
        totals[task.id] = nil
        completionHistory[task.id] = nil
        dailyElapsedHistory[task.id] = nil
        dailyTargetHistory[task.id] = nil
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
        let calendar = Calendar.current
        let history = completionHistory[task.id, default: []]
        var date = Self.focusDayStart(for: now)
        if !history.contains(Self.focusDayKey(for: date)) {
            date = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        }

        var streak = 0
        while history.contains(Self.focusDayKey(for: date)) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
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
        if inserted {
            save()
            onTaskCompleted?(task, completedDayKey)
        }
    }

    private func formatted(seconds: TimeInterval) -> String {
        let rounded = Int(seconds.rounded(.down))
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let seconds = rounded % 60
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(FocusSnapshot.self, from: data) else {
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

    private func save() {
        let snapshot = FocusSnapshot(
            tasks: tasks,
            totals: totals,
            dayKey: dayKey,
            activeTaskID: activeTaskID,
            activeStartedAt: activeStartedAt,
            currentTaskID: currentTaskID,
            completionHistory: completionHistory,
            dailyElapsedHistory: dailyElapsedHistory,
            dailyTargetHistory: dailyTargetHistory
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private static func focusDayKey(for date: Date) -> String {
        ISO8601DateFormatter().string(from: focusDayStart(for: date))
    }

    private static func focusDayStart(for date: Date) -> Date {
        let calendar = Calendar.current
        let shifted = calendar.date(byAdding: .hour, value: -6, to: date) ?? date
        return calendar.date(byAdding: .hour, value: 6, to: calendar.startOfDay(for: shifted)) ?? date
    }
}

enum DurationInput {
    static func display(_ seconds: TimeInterval) -> String {
        let rounded = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", rounded / 3600, (rounded % 3600) / 60)
    }

    /// Daily targets are deliberately simple: hours and minutes only.
    static func seconds(from input: String) -> TimeInterval? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2,
              let hours = Int(fields[0]), let minutes = Int(fields[1]),
              hours >= 0, (0..<60).contains(minutes), hours > 0 || minutes > 0 else { return nil }
        return TimeInterval(hours * 3_600 + minutes * 60)
    }
}

enum ElapsedInput {
    static func seconds(from input: String) -> TimeInterval? {
        let fields = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3,
              let hours = Int(fields[0]), let minutes = Int(fields[1]),
              hours >= 0, (0..<60).contains(minutes) else { return nil }
        let seconds = fields.count == 3 ? Int(fields[2]) : 0
        guard let seconds, (0..<60).contains(seconds) else { return nil }
        return TimeInterval(hours * 3_600 + minutes * 60 + seconds)
    }
}

private struct CommitOnBlurTextField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = "H:MM or H:MM:SS"
        field.alignment = .right
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        field.usesSingleLineMode = true
        field.delegate = context.coordinator
        context.coordinator.textField = field
        context.coordinator.installOutsideClickMonitor()
        DispatchQueue.main.async { [weak field] in
            guard let field else { return }
            field.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.removeOutsideClickMonitor()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommitOnBlurTextField
        weak var textField: NSTextField?
        private var outsideClickMonitor: Any?

        init(parent: CommitOnBlurTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            commitCurrentValue()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:))
                    || commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            parent.text = textView.string
            commitCurrentValue()
            return true
        }

        func installOutsideClickMonitor() {
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let field = self.textField, event.window === field.window else { return event }
                let point = field.convert(event.locationInWindow, from: nil)
                guard !field.bounds.contains(point) else { return event }
                DispatchQueue.main.async { [weak self] in self?.commitCurrentValue() }
                return event
            }
        }

        func removeOutsideClickMonitor() {
            if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
            outsideClickMonitor = nil
        }

        private func commitCurrentValue() {
            guard let textField else { return }
            parent.text = textField.stringValue
            parent.onCommit()
        }
    }
}

struct SettingsView: View {
    @Bindable var store: FocusStore
    var onChange: () -> Void
    var onClose: () -> Void
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Daily focus areas") {
                    ForEach(store.tasks) { task in
                        TaskEditor(task: task, store: store, onChange: onChange)
                    }
                    .onDelete { offsets in
                        for index in offsets { store.remove(store.tasks[index]) }
                        onChange()
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Button { adding = true } label: { Label("Add area", systemImage: "plus") }
                Spacer()
                Text("Totals reset at 6:00 AM local time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .sheet(isPresented: $adding) {
            AddTaskSheet(store: store, onChange: onChange)
        }
        .onExitCommand { onClose() }
    }
}

private struct TaskEditor: View {
    let task: FocusTask
    @Bindable var store: FocusStore
    var onChange: () -> Void
    @State private var name: String = ""
    @State private var target = ""
    @State private var confirmingRemoval = false
    @State private var isEditingElapsed = false
    @State private var elapsedValue = ""
    @State private var timerToResume: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Focus area", text: Binding(get: { name.isEmpty ? task.name : name }, set: { name = $0 }))
                .onSubmit { save() }
                TextField("Daily target", text: targetBinding)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 108)
                    .onSubmit { save() }
                    .onAppear { target = DurationInput.display(task.targetSeconds) }
                Button {
                    confirmingRemoval = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove \(task.name)")
            }
            if !target.isEmpty && DurationInput.seconds(from: target) == nil {
                Text("Use H:MM, for example 1:17")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(isActive ? "Recording" : "Ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(isActive ? "Stop timer" : "Start timer") {
                    toggleTimer()
                }
                .disabled(isEditingElapsed)
                Spacer()
                Text("Today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isEditingElapsed {
                    CommitOnBlurTextField(text: $elapsedValue, onCommit: commitElapsedEditing)
                        .frame(width: 112)
                    Button("Reset") { resetElapsed() }
                } else {
                    Button { beginElapsedEditing() } label: {
                        Text(store.formattedElapsed(for: task))
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Click to edit today's time")
                }
            }
            if isEditingElapsed && ElapsedInput.seconds(from: elapsedValue) == nil {
                Text("Use H:MM or H:MM:SS. An invalid value keeps the previous time.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                let streak = store.completionStreak(for: task)
                Text(streak == 1 ? "1-day streak" : "\(streak)-day streak")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(streak > 0 ? Color.green : Color.secondary)
            }
            HabitStrip(days: store.recentCompletions(for: task))
        }
        .onDisappear {
            save()
            commitElapsedEditing()
        }
        .confirmationDialog("Remove \(task.name)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Focus Area", role: .destructive) {
                store.remove(task)
                onChange()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its recorded time and completion history will be removed.")
        }
    }

    private func save() {
        guard let targetSeconds = DurationInput.seconds(from: target) else { return }
        store.update(task, name: name.isEmpty ? task.name : name, targetSeconds: targetSeconds)
        target = DurationInput.display(targetSeconds)
        onChange()
    }

    private var isActive: Bool { store.activeTaskID == task.id }

    private var statusColor: Color {
        guard isActive else { return .secondary }
        return store.elapsed(for: task) >= task.targetSeconds ? .green : .red
    }

    private func toggleTimer() {
        if isActive {
            store.finishCurrentSession()
        } else {
            store.start(taskID: task.id)
        }
        onChange()
    }

    private func beginElapsedEditing() {
        guard !isEditingElapsed else { return }
        timerToResume = store.activeTaskID
        if timerToResume != nil { store.finishCurrentSession() }
        elapsedValue = store.formattedElapsed(for: task)
        isEditingElapsed = true
        onChange()
    }

    private func commitElapsedEditing() {
        guard isEditingElapsed else { return }
        finishElapsedEditing(newValue: ElapsedInput.seconds(from: elapsedValue))
    }

    private func resetElapsed() {
        finishElapsedEditing(newValue: 0)
    }

    private func finishElapsedEditing(newValue: TimeInterval?) {
        let resumeID = timerToResume
        isEditingElapsed = false
        elapsedValue = ""
        timerToResume = nil
        if let newValue { store.setElapsed(for: task, to: newValue) }
        if let resumeID { store.start(taskID: resumeID) }
        onChange()
    }

    private var targetBinding: Binding<String> {
        Binding(
            get: { target },
            set: { newValue in
                target = newValue
                // Commit as soon as the field is a valid H:MM value. This
                // avoids losing a change when the settings window is closed
                // without pressing Return.
                guard let targetSeconds = DurationInput.seconds(from: newValue) else { return }
                store.update(task, name: name.isEmpty ? task.name : name, targetSeconds: targetSeconds)
                onChange()
            }
        )
    }

}

private struct HabitStrip: View {
    let days: [CompletionDay]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days) { day in
                VStack(spacing: 4) {
                    HStack(spacing: 3) {
                        Text(day.date, format: .dateTime.weekday(.narrow))
                        Text(day.date, format: .dateTime.day())
                    }
                    Image(systemName: day.status == .none ? "circle" : "checkmark.circle.fill")
                        .foregroundStyle(statusColor(for: day))
                    Text(DurationInput.display(day.elapsedSeconds))
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func statusColor(for day: CompletionDay) -> Color {
        switch day.status {
        case .none: .secondary
        case .partial: .yellow
        case .complete: .green
        }
    }
}

private struct AddTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: FocusStore
    var onChange: () -> Void
    @State private var name = ""
    @State private var target = "1:00"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Focus Area").font(.headline)
            TextField("Name", text: $name).frame(width: 260)
            TextField("Target (H:MM, e.g. 1:17)", text: $target)
                .frame(width: 260)
            if !target.isEmpty && DurationInput.seconds(from: target) == nil {
                Text("Use H:MM, for example 1:17")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    guard let targetSeconds = DurationInput.seconds(from: target) else { return }
                    store.addTask(name: name, targetSeconds: targetSeconds)
                    onChange()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || DurationInput.seconds(from: target) == nil)
            }
        }
        .padding(20)
    }
}
