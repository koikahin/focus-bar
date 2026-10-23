import AppKit

/// Explicit hover tracking works while this accessory app is inactive. The
/// separate, nonactivating panel leaves native status-button rendering intact.
@MainActor
final class PillHover: NSResponder {
    private weak var button: NSStatusBarButton?
    private var hoverTimer: Timer?
    private var panel: NSPanel?
    private let label = NSTextField(wrappingLabelWithString: "")
    private var text = ""
    private var isHovered = false

    init(button: NSStatusBarButton) {
        self.button = button
        super.init()
        button.addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("PillHover does not support decoding") }

    func update(text: String) {
        guard self.text != text else { return }
        self.text = text
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
    }

    @objc private func present() {
        hoverTimer = nil
        guard isHovered, !text.isEmpty, let button, let window = button.window, window.isVisible else { return }
        guard let screen = window.screen else { preconditionFailure("Visible status button has no screen") }
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
            background.addSubview(label)
            panel.contentView = background
            self.panel = panel
        }
        panel.appearance = button.effectiveAppearance
        let content = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
        label.attributedStringValue = content
        label.preferredMaxLayoutWidth = 320
        let bounds = content.boundingRect(with: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = NSSize(width: ceil(bounds.width) + 24, height: ceil(bounds.height) + 20)
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screenFrame = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, screenFrame.minX), screenFrame.maxX - size.width)
        let y = max(screenFrame.minY, anchor.minY - size.height - 6)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
        label.frame = NSRect(x: 12, y: 10, width: size.width - 24, height: size.height - 20)
        panel.orderFrontRegardless()
    }
}
