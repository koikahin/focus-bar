import AppKit

/// Only values that affect the pill's appearance belong here. Elapsed time
/// changes every instant, but only crossing the target changes the appearance.
struct PillState: Equatable {
    let areaTitle: String
    let title: String
    let isTracking: Bool
    let isComplete: Bool

    init(title: String, isTracking: Bool, elapsed: TimeInterval, target: TimeInterval?, streaks: FocusStreaks? = nil) {
        self.areaTitle = title
        self.isTracking = isTracking
        self.isComplete = target.map { elapsed >= $0 } ?? false
        if !isTracking && !isComplete, let streaks {
            self.title = "\(title) \(streaks.idleLabel)"
        } else {
            self.title = title
        }
    }
}

/// A drawing-only outline does not introduce a text control into AppKit's
/// menu-bar snapshots. Idle text stays in the button's native template image.
@MainActor
private final class CompletedOutlineView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.systemGreen.setStroke()
        pill.lineWidth = 1
        pill.stroke()
    }
}

/// Owns AppKit rendering; it neither reads the clock nor mutates tracking data.
@MainActor
final class PillRenderer {
    private let statusItem: NSStatusItem
    private let outline: CompletedOutlineView
    private let hover: PillHover
    private(set) var renderedState: PillState?
    private(set) var hoverText = ""

    init(statusItem: NSStatusItem, elapsedSnapshot: @escaping @MainActor () -> String? = { nil }) {
        self.statusItem = statusItem
        guard let button = statusItem.button else { preconditionFailure("Missing status bar button") }
        button.isBordered = false
        button.title = ""
        hover = PillHover(button: button, elapsedSnapshot: elapsedSnapshot)

        outline = CompletedOutlineView(frame: .zero)
        outline.autoresizingMask = [.width, .height]
    }

    func render(_ state: PillState, streaks: FocusStreaks? = nil) {
        guard let button = statusItem.button else { preconditionFailure("Missing status bar button") }
        var toolTip = state.areaTitle
        if let streaks { toolTip += "\n\(streaks.summary)" }
        if hoverText != toolTip {
            hoverText = toolTip
            button.setAccessibilityHelp(toolTip)
        }
        guard state != renderedState else {
            hover.update(title: state.areaTitle, streaks: streaks)
            return
        }
        renderedState = state

        outline.removeFromSuperview()

        button.contentTintColor = nil
        let image = state.isTracking
            ? PillLayout.trackingImage(title: state.title, isComplete: state.isComplete)
            : PillLayout.idleTemplateImage(title: state.title, drawsOutline: !state.isComplete)
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        statusItem.length = image.size.width
        if !state.isTracking && state.isComplete {
            outline.frame = button.bounds
            button.addSubview(outline)
        }
        hover.update(title: state.areaTitle, streaks: streaks)
    }

    func dismissHover() { hover.dismiss() }
}
