import AppKit

enum PillLayout {
    static let horizontalInset: CGFloat = 12
    static let height: CGFloat = 20

    static func text(title: String, marker: String) -> String {
        marker.isEmpty ? title : "\(title)  \(marker)"
    }

    static func width(forContentWidth contentWidth: CGFloat) -> CGFloat {
        ceil(contentWidth) + (horizontalInset * 2)
    }

    static func idleTemplateImage(title: String, drawsOutline: Bool = true) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.black,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let size = NSSize(width: width(forContentWidth: text.size().width), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            if drawsOutline {
                NSColor.black.setStroke()
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 9.5, yRadius: 9.5)
                outline.lineWidth = 1
                outline.stroke()
            }
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

    static func trackingImage(title: String, isComplete: Bool) -> NSImage {
        let marker = "●"
        let content = text(title: title, marker: marker)
        let text = NSMutableAttributedString(string: content, attributes: [
            .foregroundColor: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1),
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
        ])
        text.addAttributes([
            .foregroundColor: isComplete ? NSColor.systemGreen : NSColor.systemRed,
            .font: NSFont.systemFont(ofSize: 9, weight: .bold)
        ], range: (content as NSString).range(of: marker, options: .backwards))
        let size = NSSize(width: width(forContentWidth: text.size().width), height: height)
        return NSImage(size: size, flipped: false) { rect in
            let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 10, yRadius: 10)
            NSColor.white.withAlphaComponent(0.96).setFill()
            pill.fill()
            NSColor.black.withAlphaComponent(0.10).setStroke()
            pill.lineWidth = 0.5
            pill.stroke()
            let textSize = text.size()
            text.draw(at: NSPoint(x: floor((rect.width - textSize.width) / 2),
                                  y: floor((rect.height - textSize.height) / 2)))
            return true
        }
    }
}
