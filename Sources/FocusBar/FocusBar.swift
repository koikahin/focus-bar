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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private let store = FocusStore()
    private var statusItem: NSStatusItem!
    private var ticker: Timer?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        button.target = self
        button.action = #selector(statusItemPressed(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.wantsLayer = true
        button.layer?.cornerRadius = 10
        button.layer?.borderWidth = 0.5
        button.layer?.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor

        updateStatusItem()
        ticker = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
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

        let dot = isTracking ? "●" : "○"
        let completeColor = NSColor(srgbRed: 0.08, green: 0.42, blue: 0.18, alpha: 1)
        let filledText = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        let idleText = NSColor.labelColor
        let standardText = isTracking ? filledText : idleText
        let dotColor: NSColor = isTracking ? .systemRed : (isComplete ? completeColor : standardText.withAlphaComponent(0.55))
        let titleColor: NSColor = isComplete
            ? completeColor
            : standardText
        if isTracking {
            button.layer?.backgroundColor = (isComplete
                ? NSColor(srgbRed: 0.82, green: 0.95, blue: 0.85, alpha: 0.98)
                : NSColor.white.withAlphaComponent(0.96)).cgColor
            button.layer?.borderWidth = 0.5
            button.layer?.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor
        } else {
            button.layer?.backgroundColor = NSColor.clear.cgColor
            button.layer?.borderWidth = 1
            button.layer?.borderColor = (isComplete ? completeColor : idleText.withAlphaComponent(0.45)).cgColor
        }
        let dotAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: dotColor, .font: NSFont.systemFont(ofSize: 10, weight: .bold)]
        let titleAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: titleColor, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
        let rendered = NSMutableAttributedString(string: "  \(title)  ", attributes: titleAttributes)
        rendered.append(NSAttributedString(string: dot, attributes: dotAttributes))
        rendered.append(NSAttributedString(string: "  ", attributes: titleAttributes))
        button.attributedTitle = rendered
        button.toolTip = task.map { "\($0.name): \(store.formattedElapsed(for: $0)) today" } ?? "Choose a focus area"
    }

    private func showMenu() {
        store.pulse()
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
}

struct CompletionDay: Identifiable {
    let id: String
    let date: Date
    let isComplete: Bool
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
        if currentTaskID == task.id { currentTaskID = tasks.first?.id }
        save()
    }

    func recentCompletions(for task: FocusTask, count: Int = 7) -> [CompletionDay] {
        let calendar = Calendar.current
        let currentStart = Self.focusDayStart(for: now)
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: currentStart) else { return nil }
            let key = Self.focusDayKey(for: date)
            return CompletionDay(id: key, date: date, isComplete: completionHistory[task.id]?.contains(key) == true)
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
    }

    private func save() {
        let snapshot = FocusSnapshot(
            tasks: tasks,
            totals: totals,
            dayKey: dayKey,
            activeTaskID: activeTaskID,
            activeStartedAt: activeStartedAt,
            currentTaskID: currentTaskID,
            completionHistory: completionHistory
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

struct SettingsView: View {
    @Bindable var store: FocusStore
    var onChange: () -> Void
    var onClose: () -> Void
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            TimerStatusView(store: store, onChange: onChange)
                .padding(16)
            Divider()
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

private struct TimerStatusView: View {
    @Bindable var store: FocusStore
    var onChange: () -> Void
    @State private var isEditing = false
    @State private var editValue = ""
    @State private var editTaskID: UUID?
    @State private var resumeAfterEditing = false
    @FocusState private var timeFieldFocused: Bool

    var body: some View {
        if let task = store.currentTask {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle()
                        .fill(store.activeTaskID == task.id ? .red : .secondary)
                        .frame(width: 8, height: 8)
                    Text(store.activeTaskID == task.id ? "Recording \(task.name)" : "Ready to track \(task.name)")
                        .font(.headline)
                    Spacer()
                    if isEditing {
                        TextField("H:MM or H:MM:SS", text: $editValue)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .frame(width: 150)
                            .focused($timeFieldFocused)
                            .onSubmit { commitEditing() }
                            .onExitCommand { cancelEditing() }
                    } else {
                        Button { beginEditing(task) } label: {
                            Text(store.formattedElapsed(for: task))
                                .font(.system(.title3, design: .monospaced).weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .help("Click to edit today's time")
                    }
                }
                HStack {
                    Button(store.activeTaskID == task.id ? "Stop timer" : "Start timer") {
                        store.toggleCurrentTask()
                        onChange()
                    }
                    Button("Reset today") {
                        store.resetElapsed(for: task)
                        onChange()
                    }
                    Spacer()
                    Text("Daily target \(store.formatted(targetSeconds: task.targetSeconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isEditing && ElapsedInput.seconds(from: editValue) == nil {
                    Text("Enter H:MM or H:MM:SS · Return saves · Escape cancels")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } else {
            Text("Add a focus area to start tracking.")
                .foregroundStyle(.secondary)
        }
    }

    private func beginEditing(_ task: FocusTask) {
        editTaskID = task.id
        resumeAfterEditing = store.activeTaskID == task.id
        if resumeAfterEditing { store.finishCurrentSession() }
        editValue = store.formattedElapsed(for: task)
        isEditing = true
        onChange()
        Task { @MainActor in timeFieldFocused = true }
    }

    private func commitEditing() {
        guard let id = editTaskID,
              let task = store.tasks.first(where: { $0.id == id }),
              let seconds = ElapsedInput.seconds(from: editValue) else { return }
        store.setElapsed(for: task, to: seconds)
        finishEditing(resume: resumeAfterEditing, taskID: id)
    }

    private func cancelEditing() {
        finishEditing(resume: resumeAfterEditing, taskID: editTaskID)
    }

    private func finishEditing(resume: Bool, taskID: UUID?) {
        isEditing = false
        timeFieldFocused = false
        editValue = ""
        editTaskID = nil
        resumeAfterEditing = false
        if resume, let taskID { store.start(taskID: taskID) }
        onChange()
    }
}

private struct TaskEditor: View {
    let task: FocusTask
    @Bindable var store: FocusStore
    var onChange: () -> Void
    @State private var name: String = ""
    @State private var target = ""
    @State private var confirmingRemoval = false

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
                Text("Today \(store.formattedElapsed(for: task))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                let streak = store.completionStreak(for: task)
                Text(streak == 1 ? "1-day streak" : "\(streak)-day streak")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(streak > 0 ? Color.green : Color.secondary)
            }
            HabitStrip(days: store.recentCompletions(for: task))
        }
        .onDisappear { save() }
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
        HStack(spacing: 14) {
            ForEach(days) { day in
                VStack(spacing: 3) {
                    Text(day.date, format: .dateTime.weekday(.narrow))
                    Image(systemName: day.isComplete ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(day.isComplete ? Color.green : Color.secondary)
                    Text(day.date, format: .dateTime.day())
                }
                .font(.caption2)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
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
