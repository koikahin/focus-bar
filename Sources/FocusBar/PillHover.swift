import AppKit

/// Explicit hover tracking works while this accessory app is inactive. The
/// separate, nonactivating panel leaves native status-button rendering intact.
@MainActor
final class PillHover: NSResponder {
    private weak var button: NSStatusBarButton?
    private var hoverTimer: Timer?
    private var panel: NSPanel?
    private let headerLabel = NSTextField(wrappingLabelWithString: "")
    private let completionLabel = NSTextField(wrappingLabelWithString: "")
    private let thirtyMinuteLabel = NSTextField(wrappingLabelWithString: "")
    private var title = ""
    private var streaks: FocusStreaks?
    private var isHovered = false
    private let elapsedSnapshot: @MainActor () -> String?
    private var elapsedAtPresentation: String?

    init(button: NSStatusBarButton, elapsedSnapshot: @escaping @MainActor () -> String? = { nil }) {
        self.button = button
        self.elapsedSnapshot = elapsedSnapshot
        super.init()
        for label in [headerLabel, completionLabel, thirtyMinuteLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .labelColor
            label.isSelectable = false
            label.maximumNumberOfLines = 0
            label.preferredMaxLayoutWidth = 320
        }
        button.addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("PillHover does not support decoding") }

    func update(title: String, streaks: FocusStreaks?) {
        guard self.title != title || self.streaks != streaks else { return }
        self.title = title
        self.streaks = streaks
        if panel?.isVisible == true { present() }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        hoverTimer?.invalidate()
        let timer = Timer(timeInterval: 0.35, target: self, selector: #selector(present), userInfo: nil, repeats: false)
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func mouseExited(with event: NSEvent) { dismiss() }

    func dismiss() {
        isHovered = false
        hoverTimer?.invalidate()
        hoverTimer = nil
        panel?.orderOut(nil)
        elapsedAtPresentation = nil
    }

    @objc private func present() {
        hoverTimer = nil
        guard isHovered, !title.isEmpty, let button, let window = button.window, window.isVisible else { return }
        guard let screen = window.screen else { preconditionFailure("Visible status button has no screen") }
        if panel?.isVisible != true { elapsedAtPresentation = elapsedSnapshot() }
        headerLabel.stringValue = elapsedAtPresentation.map { "\(title) · \($0)" } ?? title
        completionLabel.stringValue = streaks?.completionLabel ?? ""
        thirtyMinuteLabel.stringValue = streaks?.thirtyMinuteLabel ?? ""
        completionLabel.isHidden = streaks == nil
        thirtyMinuteLabel.isHidden = streaks == nil
        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            let background = NSVisualEffectView()
            background.material = .toolTip
            background.state = .active
            background.wantsLayer = true
            background.layer?.cornerRadius = 7
            background.layer?.masksToBounds = true
            for label in [headerLabel, completionLabel, thirtyMinuteLabel] { background.addSubview(label) }
            panel.contentView = background
            self.panel = panel
        }
        panel.appearance = button.effectiveAppearance
        let rows = [headerLabel, completionLabel, thirtyMinuteLabel].filter { !$0.isHidden }
        // Ask each actual text field for its size, including native cell
        // padding and wrapping. String bounding boxes omit those insets.
        let sizes = rows.map { label in
            guard let cell = label.cell else { preconditionFailure("Hover label has no native text cell") }
            let width = min(320, ceil(cell.cellSize.width))
            let fitting = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000))
            precondition(width.isFinite && width > 0 && fitting.height.isFinite && fitting.height > 0, "Hover label has no fitting size")
            return NSSize(width: width, height: ceil(fitting.height))
        }
        guard let contentWidth = sizes.map(\.width).max() else { preconditionFailure("Hover has no visible rows") }
        let size = NSSize(width: contentWidth + 24,
                          height: sizes.reduce(0) { $0 + $1.height } + CGFloat(rows.count - 1) * 2 + 20)
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screenFrame = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, screenFrame.minX), screenFrame.maxX - size.width)
        let y = max(screenFrame.minY, anchor.minY - size.height - 6)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
        var top = size.height - 10
        for (label, fitting) in zip(rows, sizes) {
            label.frame = NSRect(x: 12, y: top - fitting.height, width: fitting.width, height: fitting.height)
            top -= fitting.height + 2
        }
        panel.orderFrontRegardless()
    }
}
