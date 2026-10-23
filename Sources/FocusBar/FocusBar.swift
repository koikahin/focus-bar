import AppKit
import Darwin
import Observation
import SwiftUI
import UserNotifications

// Use the property-wrapper type explicitly: newer SDKs also export a State
// macro whose plugin is unavailable in standalone Command Line Tools.
private typealias ViewState<Value> = SwiftUI.State<Value>

@main
@MainActor
struct FocusBarMain {
    // NSApplication's delegate property is weak, so the menu-bar controller
    // must be retained for the entire process lifetime.
    private static let appDelegate = AppDelegate()

    static func main() {
        if CommandLine.arguments.contains("--check-notifications") {
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { settings in
                print("Authorization: \(settings.authorizationStatus.rawValue)")
                print("Alerts: \(settings.alertSetting.rawValue)")
                print("Alert style: \(settings.alertStyle.rawValue)")
                print("Sounds: \(settings.soundSetting.rawValue)")
                exit(settings.authorizationStatus == .authorized && settings.alertSetting == .enabled && settings.alertStyle != .none ? 0 : 1)
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--test-notification") {
            FocusNotificationProbe.run()
            return
        }
        if CommandLine.arguments.contains("--render-test") {
            guard PillRenderTests.run() else { exit(1) }
            return
        }
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

struct SystemInterruptionState {
    private(set) var stoppedTaskName: String?
    private(set) var isSleeping = false
    private(set) var isSessionInactive = false

    mutating func recordStoppedTask(_ name: String) {
        if stoppedTaskName == nil { stoppedTaskName = name }
    }

    mutating func beganSleep() {
        isSleeping = true
    }

    mutating func sessionResigned() {
        isSessionInactive = true
    }

    mutating func woke() -> String? {
        isSleeping = false
        return takeNoticeIfReady()
    }

    mutating func sessionBecameActive() -> String? {
        isSessionInactive = false
        return takeNoticeIfReady()
    }

    private mutating func takeNoticeIfReady() -> String? {
        guard !isSleeping, !isSessionInactive else { return nil }
        defer { stoppedTaskName = nil }
        return stoppedTaskName
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private let store = FocusStore()
    private var statusItem: NSStatusItem!
    private var pillRenderer: PillRenderer!
    private lazy var scheduler = FocusScheduler(store: store) { [weak self] in
        self?.updateStatusItem()
        self?.updateOpenMenu()
    }
    private var openMenuTaskItems: [UUID: NSMenuItem] = [:]
    private var settingsWindow: NSWindow?
    private var isMenuOpen = false
    private var systemInterruption = SystemInterruptionState()
    private let notifications = FocusNotifications(onFailure: FocusFailure.present)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { preconditionFailure("macOS did not create the FocusBar status button") }

        button.target = self
        button.action = #selector(statusItemPressed(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        pillRenderer = PillRenderer(statusItem: statusItem)
        store.onChange = { [weak self] in self?.scheduler.requestRefresh() }
        store.onBackupFailure = { [weak self] message in self?.presentBackupFailure(message) }
        if let message = store.backupFailure { presentBackupFailure(message) }
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(sessionDidResignActive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(sessionDidBecomeActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        let distributedNotifications = DistributedNotificationCenter.default()
        distributedNotifications.addObserver(self, selector: #selector(sessionDidResignActive), name: .init("com.apple.screenIsLocked"), object: nil)
        distributedNotifications.addObserver(self, selector: #selector(sessionDidBecomeActive), name: .init("com.apple.screenIsUnlocked"), object: nil)

        UNUserNotificationCenter.current().delegate = self
        notifications.start()
        store.onTaskCompleted = { [weak self] task, dayKey in
            guard let self else { return }
            self.deliverNotification(
                identifier: "focusbar.\(task.id.uuidString).\(dayKey)",
                title: "Daily target complete",
                body: self.store.completionNotificationBody(for: task, dayKey: dayKey)
            )
        }
        NotificationCenter.default.addObserver(self, selector: #selector(clockDidChange), name: NSNotification.Name.NSSystemClockDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clockDidChange), name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)
        scheduler.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pillRenderer.dismissHover()
        store.onChange = nil
        scheduler.stop()
        store.finishCurrentSession()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func clockDidChange() { scheduler.refresh() }

    private func presentBackupFailure(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.store.backupFailure == message else { return }
            let alert = NSAlert()
            alert.messageText = "Daily reset postponed"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                self.store.refreshDayIfNeeded()
                self.scheduler.refresh()
                if let failure = self.store.backupFailure { self.presentBackupFailure(failure) }
            }
        }
    }

    @objc private func willSleep() {
        systemInterruption.beganSleep()
        stopTimerForSystemInterruption()
    }

    @objc private func didWake() {
        store.refreshDayIfNeeded()
        presentStoppedTimerNotice(for: systemInterruption.woke())
        scheduler.refresh()
    }

    @objc private func sessionDidResignActive() {
        systemInterruption.sessionResigned()
        stopTimerForSystemInterruption()
    }

    @objc private func sessionDidBecomeActive() {
        store.refreshDayIfNeeded()
        presentStoppedTimerNotice(for: systemInterruption.sessionBecameActive())
        scheduler.refresh()
    }

    private func stopTimerForSystemInterruption() {
        pillRenderer.dismissHover()
        if let stoppedTask = store.stopForSystemInterruption() {
            systemInterruption.recordStoppedTask(stoppedTask.name)
        }
        scheduler.refresh()
    }

    private func presentStoppedTimerNotice(for taskName: String?) {
        guard let taskName else { return }
        deliverNotification(
            identifier: "focusbar.timer-stopped.\(UUID().uuidString)",
            title: "Focus timer stopped",
            body: "The \(taskName) timer was stopped while your Mac was locked or asleep."
        )
    }

    private func deliverNotification(identifier: String, title: String, body: String) {
        notifications.deliver(identifier: identifier, title: title, body: body)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        pillRenderer.dismissHover()
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            store.toggleCurrentTask()
            updateStatusItem()
        }
    }

    private func updateStatusItem() {
        let task = store.currentTask
        let streaks = task.map { store.streaks(for: $0) }
        pillRenderer.render(PillState(
            title: task?.name ?? "focus",
            isTracking: store.activeTaskID != nil,
            elapsed: task.map { store.elapsed(for: $0) } ?? 0,
            target: task?.targetSeconds,
            streaks: streaks
        ), streaks: streaks)
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
        isMenuOpen = true
        updateSecondsDisplayVisibility()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
        openMenuTaskItems.removeAll()
        isMenuOpen = false
        updateSecondsDisplayVisibility()
    }

    private func updateOpenMenu() {
        guard !openMenuTaskItems.isEmpty else { return }
        for task in store.tasks {
            guard let item = openMenuTaskItems[task.id] else { continue }
            let elapsed = store.formattedElapsed(for: task)
            let target = store.formatted(targetSeconds: task.targetSeconds)
            let title = "\(task.name)    \(elapsed) / \(target)"
            if item.title != title { item.title = title }
            let state: NSControl.StateValue = store.activeTaskID == task.id ? .on : .off
            if item.state != state { item.state = state }
            let isComplete = store.elapsed(for: task) >= task.targetSeconds
            if isComplete != (item.image != nil) {
                item.image = isComplete
                    ? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Complete")
                    : nil
            }
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
            updateSecondsDisplayVisibility()
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
        updateSecondsDisplayVisibility()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        settingsWindow = nil
        NSApp.setActivationPolicy(.accessory)
        updateSecondsDisplayVisibility()
    }

    func windowDidMiniaturize(_ notification: Notification) { updateSecondsDisplayVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updateSecondsDisplayVisibility() }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateSecondsDisplayVisibility() }

    private func updateSecondsDisplayVisibility() {
        let windowVisible = settingsWindow.map {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        } ?? false
        scheduler.setSecondsDisplayVisible(isMenuOpen || windowVisible)
    }

    @objc private func quit() { NSApp.terminate(nil) }
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
        guard fields.count <= 3 else { return nil }
        let values = fields.map { $0.isEmpty ? 0 : Int($0) }
        guard let hours = values[0], hours >= 0 else { return nil }
        let minutes = values.count > 1 ? values[1] : 0
        let seconds = values.count > 2 ? values[2] : 0
        guard let minutes, let seconds,
              (0..<60).contains(minutes), (0..<60).contains(seconds) else { return nil }
        let total = TimeInterval(hours) * 3_600 + TimeInterval(minutes * 60 + seconds)
        guard total < Double(Int.max) else { return nil }
        return total
    }
}

struct CommitOnBlurTextField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onReset: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSStackView {
        let view = context.coordinator.makeEditorView()
        context.coordinator.activateAfterPresentation()
        return view
    }

    func updateNSView(_ view: NSStackView, context: Context) {
        context.coordinator.parent = self
        if let field = context.coordinator.textField, field.stringValue != text { field.stringValue = text }
    }

    static func dismantleNSView(_ view: NSStackView, coordinator: Coordinator) {
        coordinator.removeOutsideClickMonitor()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommitOnBlurTextField
        weak var textField: NSTextField?
        weak var resetButton: NSButton?
        private var outsideClickMonitor: Any?
        private var acceptsBlurCommit = false
        private var isFinished = false

        init(parent: CommitOnBlurTextField) {
            self.parent = parent
        }

        func makeEditorView() -> NSStackView {
            let field = NSTextField(string: parent.text)
            field.placeholderString = "H[:MM[:SS]]"
            field.alignment = .right
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            field.usesSingleLineMode = true
            field.delegate = self
            textField = field
            let reset = NSButton(title: "Reset", target: self, action: #selector(resetCurrentValue))
            reset.bezelStyle = .rounded
            resetButton = reset
            let view = NSStackView(views: [field, reset])
            view.orientation = .horizontal
            view.spacing = 8
            field.widthAnchor.constraint(equalToConstant: 112).isActive = true
            return view
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard acceptsBlurCommit else { return }
            commitCurrentValue()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:))
                    || commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            parent.text = textView.string
            commitCurrentValue()
            return true
        }

        func activateAfterPresentation() {
            acceptsBlurCommit = false
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isFinished, let field = self.textField, let window = field.window else { return }
                window.makeFirstResponder(field)
                field.selectText(nil)

                // SwiftUI can perform another responder transition after it
                // swaps the time button for this AppKit field. Reassert focus
                // on the following turn, then begin treating blur as user
                // intent. This prevents the opening click from closing the
                // editor immediately.
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isFinished, let field = self.textField, let window = field.window else { return }
                    if window.firstResponder !== field.currentEditor() {
                        window.makeFirstResponder(field)
                        field.selectText(nil)
                    }
                    self.acceptsBlurCommit = true
                    self.installOutsideClickMonitor()
                }
            }
        }

        func installOutsideClickMonitor() {
            guard outsideClickMonitor == nil else { return }
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                return self.handleMouseDown(event)
            }
        }

        func handleMouseDown(_ event: NSEvent) -> NSEvent? {
            guard let field = textField, event.window === field.window else { return event }
            if event.type == .leftMouseDown, let resetButton,
               resetButton.bounds.contains(resetButton.convert(event.locationInWindow, from: nil)) {
                // Reset disappears when editing ends. Handle its mouse-down
                // before a blur/outside commit can remove it before mouse-up.
                resetCurrentValue()
                return nil
            }
            let point = field.convert(event.locationInWindow, from: nil)
            guard !field.bounds.contains(point) else { return event }
            DispatchQueue.main.async { [weak self] in self?.commitCurrentValue() }
            return event
        }

        func removeOutsideClickMonitor() {
            if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
            outsideClickMonitor = nil
            acceptsBlurCommit = false
        }

        private func commitCurrentValue() {
            guard !isFinished, let textField else { return }
            isFinished = true
            removeOutsideClickMonitor()
            parent.text = textField.stringValue
            parent.onCommit()
        }

        @objc private func resetCurrentValue() {
            guard !isFinished else { return }
            isFinished = true
            removeOutsideClickMonitor()
            parent.onReset()
        }
    }
}

struct SettingsView: View {
    @Bindable var store: FocusStore
    var onChange: () -> Void
    var onClose: () -> Void
    @ViewState private var adding = false
    @ViewState private var pendingRemoval: [FocusTask] = []
    @ViewState private var confirmingRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Daily focus areas") {
                    ForEach(store.tasks) { task in
                        TaskEditor(task: task, store: store, onChange: onChange, onRequestRemoval: { requestRemoval([task]) })
                    }
                    .onDelete { offsets in
                        requestRemoval(offsets.map { store.tasks[$0] })
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
        .alert("Remove \(pendingRemoval.map(\.name).joined(separator: ", "))?", isPresented: $confirmingRemoval) {
            Button("Remove Focus Area", role: .destructive) {
                for task in pendingRemoval { store.remove(task) }
                pendingRemoval = []
                onChange()
            }
            Button("Cancel", role: .cancel) { pendingRemoval = [] }
        } message: {
            Text("Its recorded time and completion history will be removed.")
        }
    }

    private func requestRemoval(_ tasks: [FocusTask]) {
        pendingRemoval = tasks
        confirmingRemoval = true
    }
}

private struct TaskEditor: View {
    let task: FocusTask
    @Bindable var store: FocusStore
    var onChange: () -> Void
    var onRequestRemoval: () -> Void
    @ViewState private var name = ""
    @ViewState private var target = ""
    @ViewState private var isEditingElapsed = false
    @ViewState private var elapsedValue = ""
    @ViewState private var timerToResume: UUID?

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
                    onRequestRemoval()
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
                    CommitOnBlurTextField(text: $elapsedValue, onCommit: commitElapsedEditing, onReset: resetElapsed)
                        .frame(width: 180)
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
                Text("Use H, H:MM, or H:MM:SS; omitted parts become 00. An invalid value keeps the previous time.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    let streaks = store.streaks(for: task)
                    Text(streaks.completionLabel)
                        .foregroundStyle(streaks.completedDays > 0 ? Color.green : Color.secondary)
                    Text(streaks.thirtyMinuteLabel)
                        .foregroundStyle(streaks.thirtyMinuteDays > 0 ? Color.green : Color.secondary)
                        .help("Consecutive focus days with at least 30 minutes. Today counts once 30 minutes are reached.")
                }
                .font(.caption.weight(.medium))
            }
            HabitStrip(days: store.recentCompletions(for: task))
        }
        .onDisappear {
            save()
            commitElapsedEditing()
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
        guard isEditingElapsed else { return }
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
    @ViewState private var name = ""
    @ViewState private var target = "1:00"

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
