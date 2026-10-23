import AppKit
import UserNotifications

@MainActor
enum FocusFailure {
    static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.localizedDescription) (\(error.domain), code \(error.code))"
    }

    static func present(_ message: String) {
        NSLog("FocusBar error: %@", message)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "FocusBar could not send notifications"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    static func stop(_ message: String, error: Error) -> Never {
        let detail = "\(message)\n\n\(describe(error))\n\nFocusBar will quit to preserve the saved data."
        NSLog("FocusBar error: %@", detail)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "FocusBar could not access saved data"
        alert.informativeText = detail
        alert.addButton(withTitle: "Quit FocusBar")
        alert.runModal()
        // Do not run termination callbacks that might write over unreadable data.
        exit(1)
    }
}

/// Holds requests until authorization finishes and reports every failed operation.
@MainActor
final class FocusNotifications {
    typealias Authorize = (@escaping @MainActor (Result<Bool, Error>) -> Void) -> Void
    typealias Submit = (UNNotificationRequest, @escaping @MainActor (Error?) -> Void) -> Void

    private enum State { case waiting, ready, failed }
    private var state = State.waiting
    private var started = false
    private var pending: [UNNotificationRequest] = []
    private let authorize: Authorize
    private let submit: Submit
    private let onFailure: @MainActor (String) -> Void

    init(authorize: @escaping Authorize, submit: @escaping Submit, onFailure: @escaping @MainActor (String) -> Void) {
        self.authorize = authorize
        self.submit = submit
        self.onFailure = onFailure
    }

    convenience init(center: UNUserNotificationCenter = .current(), onFailure: @escaping @MainActor (String) -> Void) {
        self.init(authorize: { completion in
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                Task { @MainActor in
                    if let error { completion(.failure(error)) }
                    else { completion(.success(granted)) }
                }
            }
        }, submit: { request, completion in
            center.add(request) { error in
                Task { @MainActor in completion(error) }
            }
        }, onFailure: onFailure)
    }

    func start() {
        precondition(!started, "Notification authorization must only start once")
        started = true
        authorize { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(true):
                self.state = .ready
                let requests = self.pending
                self.pending.removeAll()
                for request in requests { self.send(request) }
            case .success(false):
                self.state = .failed
                self.pending.removeAll()
                self.onFailure("Notification permission was denied. Enable notifications in System Settings → Notifications → FocusBar, then relaunch FocusBar. Target and stopped-timer notifications cannot be shown until permission is enabled.")
            case .failure(let error):
                self.state = .failed
                self.pending.removeAll()
                self.onFailure("macOS could not authorize notifications.\n\n\(FocusFailure.describe(error))\n\nTarget and stopped-timer notifications cannot be sent. Reinstall the signed app and relaunch FocusBar.")
            }
        }
    }

    func deliver(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        switch state {
        case .waiting: pending.append(request)
        case .ready: send(request)
        case .failed:
            onFailure("The notification “\(title)” could not be sent because notification authorization failed. Check System Settings → Notifications → FocusBar, then relaunch FocusBar.")
        }
    }

    private func send(_ request: UNNotificationRequest) {
        submit(request) { [weak self] error in
            if let error {
                self?.onFailure("macOS rejected “\(request.content.title)”.\n\n\(FocusFailure.describe(error))")
            }
        }
    }
}
